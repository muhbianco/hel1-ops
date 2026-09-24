#!/usr/bin/env bash
# Backup da plataforma MuhBianco para o Backblaze B2: tudo que não se refaz com um `git push`.
#
#   bash scripts/backup-muhbianco.sh            # o que o timer do systemd chama
#   DRY_RUN=1 bash scripts/backup-muhbianco.sh  # faz tudo menos o upload
#   PECAS="mariadb mongo" bash scripts/backup-muhbianco.sh   # só algumas peças
#
# Credenciais em /root/.muhbianco-backup-b2.env (600), instaladas pelo
# `set-backup-credentials-muhbianco.sh`. Nenhum valor aparece na saída nem na linha de comando.
#
# Mesmo desenho do backup do mu-tower e do mucommerce: nunca apaga nada (retenção é regra de
# ciclo de vida no bucket, e chave que apaga backup não protege contra invasor), confere
# decifrando antes de enviar, senha por descritor de arquivo, chaves do B2 no contêiner por nome.
#
# Duas decisões próprias daqui:
#
# 1. **Uma peça, um arquivo.** São bancos de tecnologias diferentes e diretórios de serviços
#    diferentes; cada um se restaura sozinho. Peça que falha não derruba as outras — todas rodam
#    e o job fecha em erro no fim dizendo quais quebraram. Backup parcial é melhor que nenhum.
# 2. **Os dados do Chatwoot moram no pgvector.** Não é engano de leitura: o container `pgvector`
#    hospeda `api_agents_kb` (a KB do agente, com embeddings) e também o Postgres do Chatwoot.
#
# O que NÃO entra aqui, de propósito:
#   - `bolsocoberto` (WordPress + editor): outro produto, outro bucket. Ligue com INCLUIR_BOLSO=1
#     se quiser junto — hoje ele não tem backup nenhum.
#   - `gazettes` e `emissao-nf` no MinIO: não são da plataforma MuhBianco.
#   - Redis: efêmero por desenho (fila e cache; o outbox garante reentrega).
set -euo pipefail

ENV_BACKUP="${ENV_BACKUP:-/root/.muhbianco-backup-b2.env}"
AWS_IMAGE="${AWS_IMAGE:-amazon/aws-cli:2.37.1}"
ESTADO="${ESTADO:-/var/lib/muhbianco-backup}"
DRY_RUN="${DRY_RUN:-0}"
INCLUIR_BOLSO="${INCLUIR_BOLSO:-0}"
PECAS="${PECAS:-mariadb postgres pgvector mongo arquivos}"

VOLUMES_DIR="${VOLUMES_DIR:-/var/lib/docker/volumes}"
STOAT_DIR="${STOAT_DIR:-/usr/src/stoat}"

# Bancos por servidor. Nome do container resolvido na hora: o Swarm troca o sufixo a cada deploy.
PG_DBS="${PG_DBS:-n8n_queue typebot outline wiki}"
PGVECTOR_DBS="${PGVECTOR_DBS:-api_agents_kb chatwoot_production chatwoot}"
MARIA_SCHEMAS="${MARIA_SCHEMAS:-api_agents}"
MONGO_DBS="${MONGO_DBS:-revolt muchat_study}"

[ -r "$ENV_BACKUP" ] || { echo "credenciais ilegíveis: $ENV_BACKUP" >&2; exit 2; }
set -a
# shellcheck disable=SC1090
. "$ENV_BACKUP"
set +a

for v in MUHBIANCO_BACKUP_ENDPOINT MUHBIANCO_BACKUP_REGION MUHBIANCO_BACKUP_BUCKET \
         MUHBIANCO_BACKUP_KEY_ID MUHBIANCO_BACKUP_APP_KEY MUHBIANCO_BACKUP_PASSPHRASE; do
  [ -n "${!v:-}" ] || { echo "faltou $v em $ENV_BACKUP" >&2; exit 2; }
done

for t in mariadb-dump zstd gpg tar docker; do
  command -v "$t" >/dev/null || { echo "$t não encontrado" >&2; exit 2; }
done

[ "$INCLUIR_BOLSO" = "1" ] && MARIA_SCHEMAS="$MARIA_SCHEMAS bolsocoberto"

CARIMBO="$(date -u +%Y%m%dT%H%M%SZ)"
TMP="$(mktemp -d /var/tmp/muhbianco-backup.XXXXXX)"
chmod 700 "$TMP"
# Os dumps em claro vivem aqui dentro; sair sem apagar deixaria tudo legível em /var/tmp.
trap 'rm -rf "$TMP"' EXIT

export AWS_ACCESS_KEY_ID="$MUHBIANCO_BACKUP_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$MUHBIANCO_BACKUP_APP_KEY"
export AWS_DEFAULT_REGION="$MUHBIANCO_BACKUP_REGION"

FALHAS=()
ENVIADOS=()

cifrar() {
  gpg --batch --yes --quiet --pinentry-mode loopback \
      --symmetric --cipher-algo AES256 --digest-algo SHA512 \
      --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 65011712 \
      --compress-algo none \
      --passphrase-fd 3 -o "$1" 3<<<"$MUHBIANCO_BACKUP_PASSPHRASE"
}

decifrar() {
  gpg --batch --quiet --pinentry-mode loopback --decrypt \
      --passphrase-fd 3 "$1" 3<<<"$MUHBIANCO_BACKUP_PASSPHRASE"
}

# Container do Swarm pelo nome do serviço: o sufixo muda a cada deploy.
container() {
  docker ps --filter "name=$1" --format '{{.Names}}' | head -1
}

aws_s3() {
  local arquivo="$1" nome="$2"; shift 2
  docker run --rm \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
    -v "$arquivo:/tmp/$nome:ro" \
    "$AWS_IMAGE" --endpoint-url "$MUHBIANCO_BACKUP_ENDPOINT" "$@"
}

enviar() {
  local arquivo="$1" prefixo="$2"
  local nome tamanho remoto
  nome="$(basename "$arquivo")"
  tamanho="$(stat -c %s "$arquivo")"

  if [ "$DRY_RUN" = "1" ]; then
    echo "      DRY_RUN=1: ${prefixo}/${nome} ($tamanho bytes) não enviado"
    ENVIADOS+=("(dry-run) ${prefixo}/${nome}")
    return 0
  fi

  aws_s3 "$arquivo" "$nome" s3 cp "/tmp/$nome" \
    "s3://${MUHBIANCO_BACKUP_BUCKET}/daily/${prefixo}/${nome}" --only-show-errors
  remoto="$(aws_s3 "$arquivo" "$nome" s3api head-object \
    --bucket "$MUHBIANCO_BACKUP_BUCKET" --key "daily/${prefixo}/${nome}" \
    --query ContentLength --output text | tr -d '\r')"
  [ "$remoto" = "$tamanho" ] || {
    echo "tamanho no bucket ($remoto) difere do local ($tamanho)" >&2; return 1; }
  echo "      daily/${prefixo}/${nome} confere ($tamanho bytes)"

  if [ "$(date -u +%u)" = "7" ]; then
    aws_s3 "$arquivo" "$nome" s3 cp \
      "s3://${MUHBIANCO_BACKUP_BUCKET}/daily/${prefixo}/${nome}" \
      "s3://${MUHBIANCO_BACKUP_BUCKET}/weekly/${prefixo}/${nome}" --only-show-errors
    echo "      weekly/${prefixo}/${nome} (domingo)"
  fi
  ENVIADOS+=("daily/${prefixo}/${nome} ${tamanho}")
}

# Fecha o ciclo de um dump SQL: comprime, cifra, decifra de volta conferindo a marca, envia.
fechar_sql() {
  local bruto="$1" cifrado="$2" marca="$3" prefixo="$4"
  tail -c 300 "$bruto" | grep -q "$marca" || {
    echo "dump sem marca de conclusão ($marca)" >&2; return 1; }
  echo "      $(stat -c %s "$bruto") bytes"
  nice -n 19 zstd -9 -q -c "$bruto" | cifrar "$cifrado"
  decifrar "$cifrado" | zstd -d -q -c | tail -c 300 | grep -q "$marca" || {
    echo "o dump cifrado não volta íntegro; nada foi enviado" >&2; return 1; }
  rm -f "$bruto"
  enviar "$cifrado" "$prefixo"
}

# ------------------------------------------------------------------ MariaDB (api_agents)
peca_mariadb() {
  local schema bruto cifrado erro=0
  for schema in $MARIA_SCHEMAS; do
    echo "[mariadb] $schema"
    bruto="$TMP/${schema}.sql"
    cifrado="$TMP/${schema}-${CARIMBO}.sql.zst.gpg"
    nice -n 19 ionice -c3 mariadb-dump \
      --single-transaction --hex-blob --routines --events --triggers \
      --default-character-set=utf8mb4 "$schema" >"$bruto" || { erro=1; continue; }
    fechar_sql "$bruto" "$cifrado" 'Dump completed' "mariadb" || erro=1
  done
  return "$erro"
}

# ------------------------------------------------------------------ Postgres (n8n, typebot…)
dump_postgres() {
  local alvo="$1" prefixo="$2" dbs="$3"
  local nome db bruto cifrado erro=0
  nome="$(container "$alvo")"
  [ -n "$nome" ] || { echo "container de $alvo não está de pé" >&2; return 1; }
  for db in $dbs; do
    echo "[$prefixo] $db"
    bruto="$TMP/${prefixo}-${db}.sql"
    cifrado="$TMP/${prefixo}-${db}-${CARIMBO}.sql.zst.gpg"
    # `--no-owner`: restaurar noutro cluster não pode depender dos papéis daqui.
    docker exec "$nome" pg_dump -U postgres --no-owner --clean --if-exists "$db" >"$bruto" || {
      echo "pg_dump de $db falhou" >&2; erro=1; continue; }
    fechar_sql "$bruto" "$cifrado" 'PostgreSQL database dump complete' "$prefixo" || erro=1
  done
  return "$erro"
}

peca_postgres() { dump_postgres postgres_postgres postgres "$PG_DBS"; }
peca_pgvector() { dump_postgres pgvector_pgvector pgvector "$PGVECTOR_DBS"; }

# ------------------------------------------------------------------ MongoDB (muchat e study bot)
peca_mongo() {
  local nome cifrado db
  nome="$(container stoat-database)"
  [ -n "$nome" ] || { echo "mongo do muchat não está de pé" >&2; return 1; }
  echo "[mongo] ${MONGO_DBS}"
  local dir="$TMP/mongo" bruto="$TMP/muchat.tar"
  cifrado="$TMP/muchat-${CARIMBO}.tar.zst.gpg"
  mkdir -p "$dir"
  # Um arquivo por banco: o restore de um deles não obriga a mexer no outro
  # (`mongorestore --archive=<arquivo>`).
  for db in $MONGO_DBS; do
    docker exec "$nome" mongodump --quiet --db "$db" --archive >"$dir/${db}.archive" || {
      echo "mongodump de $db falhou" >&2; return 1; }
    [ -s "$dir/${db}.archive" ] || { echo "mongodump de $db veio vazio" >&2; return 1; }
  done

  tar -C "$dir" -cf "$bruto" .
  nice -n 19 zstd -9 -q -c "$bruto" | cifrar "$cifrado"
  local itens
  itens="$(decifrar "$cifrado" | zstd -d -q -c | tar -tf - | wc -l)"
  [ "$itens" -gt 0 ] || { echo "o arquivo do mongo volta vazio" >&2; return 1; }
  echo "      $itens arquivos conferidos"
  rm -rf "$bruto" "$dir"
  enviar "$cifrado" "mongo"
}

# ------------------------------------------------------------------ arquivos e volumes
# Um tar por grupo, com os caminhos que o serviço precisa para voltar a existir.
tar_grupo() {
  local nome="$1" base="$2"; shift 2
  local cifrado="$TMP/${nome}-${CARIMBO}.tar.zst.gpg"
  local existentes=() alvo
  for alvo in "$@"; do
    [ -e "$base/$alvo" ] && existentes+=("$alvo")
  done
  [ ${#existentes[@]} -gt 0 ] || { echo "nada a empacotar em $base para $nome" >&2; return 1; }

  echo "[arquivos] $nome: ${existentes[*]}"
  nice -n 19 ionice -c3 tar -C "$base" -cf - "${existentes[@]}" \
    | nice -n 19 zstd -9 -q -c | cifrar "$cifrado"
  local itens
  itens="$(decifrar "$cifrado" | zstd -d -q -c | tar -tf - | wc -l)"
  [ "$itens" -gt 0 ] || { echo "o tar de $nome volta vazio" >&2; return 1; }
  echo "      $itens itens conferidos"
  enviar "$cifrado" "arquivos"
}

peca_arquivos() {
  local erro=0
  # Muchat: mídia do MinIO próprio e a configuração que o Stoat não reconstrói sozinho.
  tar_grupo muchat "$STOAT_DIR" \
    data/minio Revolt.toml stoat.json Caddyfile livekit.yml brand/public || erro=1
  # MinIO da plataforma: anexos do Outline, do Typebot e os artefatos de agendamento do agente.
  tar_grupo minio-plataforma "$VOLUMES_DIR/minio_data/_data" \
    outline typebot schedule-artifacts || erro=1
  # Volumes: anexos do Chatwoot, avatares do agente e as stacks do Portainer (que guardam a
  # forma de cada serviço — sem elas o resgate vira arqueologia).
  tar_grupo volumes "$VOLUMES_DIR" \
    chatwoot_chatwoot_storage/_data api-agents_api_agents_avatars/_data \
    portainer_data/_data || erro=1
  return "$erro"
}

for peca in $PECAS; do
  # Peça que quebra não leva as outras junto: o erro é somado e reportado no fim.
  "peca_${peca}" || FALHAS+=("$peca")
done

echo
if [ ${#ENVIADOS[@]} -gt 0 ]; then
  printf 'enviado: %s\n' "${ENVIADOS[@]}"
fi

if [ ${#FALHAS[@]} -gt 0 ]; then
  echo "FALHOU: ${FALHAS[*]}" >&2
  exit 1
fi

mkdir -p "$ESTADO"
printf '%s %s\n' "$CARIMBO" "${ENVIADOS[*]}" >"$ESTADO/last-success"
echo "pronto."
