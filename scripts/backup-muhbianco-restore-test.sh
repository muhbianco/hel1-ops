#!/usr/bin/env bash
# Restore de prova da plataforma MuhBianco: baixa o backup mais recente do B2, decifra e restaura num
# banco de teste, comparando as tabelas que contam a história. Roda **na hel1**, como root:
#
#   bash scripts/backup-muhbianco-restore-test.sh
#   ENSAIOS=ytfamily bash scripts/backup-muhbianco-restore-test.sh                          # só um dos ensaios
#   CHAVE=daily/mariadb/arquivo.sql.zst.gpg bash scripts/backup-muhbianco-restore-test.sh   # um backup específico
#   CHAVE_YT=daily/ytfamily/arquivo.db.zst.gpg bash scripts/backup-muhbianco-restore-test.sh
#   MANTER=1 bash scripts/backup-muhbianco-restore-test.sh                                  # não apaga o banco de teste no fim
#
# Dois ensaios:
#   - `mariadb`: `api_agents` restaurado em `api_agents_restore_check`, contagens lado a lado com produção;
#   - `ytfamily`: o SQLite do portal da família Premium aberto num diretório temporário —
#     `integrity_check`, tabelas e contagens lado a lado com a cópia diária mais nova do volume.
#
# Backup que nunca foi restaurado é esperança, não backup. O mês em que isto falhar é o mês em
# que você descobre — e não no dia em que precisar de verdade.
#
# ⚠️ O destino é fixo e termina em `_restore_check`: nunca aponte para produção.
set -euo pipefail

ENV_BACKUP="${ENV_BACKUP:-/root/.muhbianco-backup-b2.env}"
AWS_IMAGE="${AWS_IMAGE:-amazon/aws-cli:2.37.1}"
SCHEMA="${SCHEMA:-api_agents}"
DESTINO="api_agents_restore_check"
MANTER="${MANTER:-0}"
ENSAIOS="${ENSAIOS:-mariadb ytfamily}"
YT_VOLUME="${YT_VOLUME:-yt-family_data}"

case "$DESTINO" in
  *_restore_check) ;;
  *) echo "destino inesperado: $DESTINO" >&2; exit 2 ;;
esac

quer() { case " $ENSAIOS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

[ -r "$ENV_BACKUP" ] || { echo "credenciais ilegíveis: $ENV_BACKUP" >&2; exit 2; }
set -a
# shellcheck disable=SC1090
. "$ENV_BACKUP"
set +a

FERRAMENTAS="zstd gpg docker"
quer mariadb && FERRAMENTAS="$FERRAMENTAS mariadb mariadb-dump"
quer ytfamily && FERRAMENTAS="$FERRAMENTAS python3"
for t in $FERRAMENTAS; do
  command -v "$t" >/dev/null || { echo "$t não encontrado" >&2; exit 2; }
done

export AWS_ACCESS_KEY_ID="$MUHBIANCO_BACKUP_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$MUHBIANCO_BACKUP_APP_KEY"
export AWS_DEFAULT_REGION="$MUHBIANCO_BACKUP_REGION"

TMP="$(mktemp -d /var/tmp/muhbianco-restore.XXXXXX)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

aws_s3() {
  docker run --rm \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
    -v "$TMP:/work" \
    "$AWS_IMAGE" --endpoint-url "$MUHBIANCO_BACKUP_ENDPOINT" "$@"
}

# Chave mais recente de um prefixo. Os nomes carregam carimbo ISO em UTC, então ordem alfabética é
# ordem cronológica.
mais_recente() {
  local chave
  chave="$(aws_s3 s3api list-objects-v2 \
    --bucket "$MUHBIANCO_BACKUP_BUCKET" --prefix "$1" \
    --query 'sort_by(Contents,&Key)[-1].Key' --output text | tr -d '\r')"
  [ -n "$chave" ] && [ "$chave" != "None" ] || { echo "nenhum backup em $1" >&2; return 1; }
  echo "$chave"
}

# Baixa uma chave para $TMP e decifra para o arquivo pedido (`zstd -d` incluso).
baixar_decifrar() {
  local chave="$1" saida="$2" nome
  nome="$(basename "$chave")"
  aws_s3 s3 cp "s3://$MUHBIANCO_BACKUP_BUCKET/${chave}" "/work/${nome}" --only-show-errors
  [ -s "$TMP/$nome" ] || { echo "download vazio" >&2; return 1; }
  echo "      $(stat -c %s "$TMP/$nome") bytes"
  gpg --batch --quiet --pinentry-mode loopback --decrypt \
      --passphrase-fd 3 "$TMP/$nome" 3<<<"$MUHBIANCO_BACKUP_PASSPHRASE" \
    | zstd -d -q -c >"$saida"
  rm -f "$TMP/$nome"
}

FALHAS=0

# ------------------------------------------------------------------ MariaDB (api_agents)
if quer mariadb; then
  echo "== mariadb: $SCHEMA"
  if [ -z "${CHAVE:-}" ]; then
    echo "[1/4] procurando o backup mais recente de daily/mariadb/api_agents"
    CHAVE="$(mais_recente "daily/mariadb/api_agents")"
  fi
  echo "      $CHAVE"

  echo "[2/4] baixando e decifrando"
  baixar_decifrar "$CHAVE" "$TMP/dump.sql"
  tail -c 300 "$TMP/dump.sql" | grep -q 'Dump completed' || {
    echo "dump incompleto depois de decifrar" >&2; exit 1; }

  echo "[3/4] restaurando em $DESTINO"
  mariadb -e "DROP DATABASE IF EXISTS \`$DESTINO\`; CREATE DATABASE \`$DESTINO\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
  mariadb "$DESTINO" <"$TMP/dump.sql"
  rm -f "$TMP/dump.sql"

  echo "[4/4] conferindo"
  TABELAS="$(mariadb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DESTINO'")"
  [ "$TABELAS" -gt 0 ] || { echo "restaurou sem tabela nenhuma" >&2; exit 1; }
  echo "      $TABELAS tabelas"

  # Tabela que sumiu do restore é falha; tabela que existe vazia passaria numa checagem só de schema,
  # por isso a contagem lado a lado das que contam a história.
  for t in users wallets user_services service_charges agent_messages; do
    ORIG="$(mariadb -N -e "SELECT COUNT(*) FROM \`$SCHEMA\`.\`$t\`" 2>/dev/null || echo "?")"
    REST="$(mariadb -N -e "SELECT COUNT(*) FROM \`$DESTINO\`.\`$t\`" 2>/dev/null || echo "?")"
    # O backup é de antes; produção pode ter crescido desde então. O que não pode é o restore ter mais.
    if [ "$REST" = "?" ]; then
      printf '      %-26s AUSENTE no restore\n' "$t"; FALHAS=$((FALHAS + 1))
    elif [ "$ORIG" != "?" ] && [ "$REST" -gt "$ORIG" ]; then
      printf '      %-26s restore=%s > producao=%s (?)\n' "$t" "$REST" "$ORIG"
    else
      printf '      %-26s restore=%-8s producao=%s\n' "$t" "$REST" "$ORIG"
    fi
  done

  if [ "$MANTER" != "1" ]; then
    mariadb -e "DROP DATABASE \`$DESTINO\`"
    echo "      banco de teste apagado (MANTER=1 para inspecionar)"
  fi
fi

# ------------------------------------------------------------------ SQLite do yt-family
# Não restaura em lugar nenhum: o SQLite é o próprio arquivo, então o ensaio é abri-lo. A referência
# é a cópia diária mais nova do volume (a mesma fonte do backup), aberta com `immutable=1` — sem
# trava e sem criar arquivo ao lado, porque o volume é do app. O banco vivo (`yt.db` + `-wal`)
# não é tocado.
if quer ytfamily; then
  if quer mariadb; then echo; fi
  echo "== ytfamily: SQLite do portal da família Premium"
  if [ -z "${CHAVE_YT:-}" ]; then
    echo "[1/3] procurando o backup mais recente de daily/ytfamily"
    CHAVE_YT="$(mais_recente "daily/ytfamily/yt-family-")"
  fi
  echo "      $CHAVE_YT"

  echo "[2/3] baixando e decifrando"
  baixar_decifrar "$CHAVE_YT" "$TMP/yt.db"
  [ -s "$TMP/yt.db" ] || { echo "o SQLite volta vazio" >&2; exit 1; }

  echo "[3/3] conferindo"
  BASE_YT="$(docker volume inspect "$YT_VOLUME" --format '{{.Mountpoint}}' 2>/dev/null || true)"
  REF_YT=""
  if [ -n "$BASE_YT" ] && [ -d "$BASE_YT/backups" ]; then
    REF_YT="$(find "$BASE_YT/backups" -maxdepth 1 -type f -name 'yt-????-??-??.db' | sort | tail -1)"
  fi
  python3 -I - "$TMP/yt.db" "$REF_YT" <<'PY' || FALHAS=$((FALHAS + 1))
import sqlite3
import sys
from pathlib import Path
from urllib.parse import quote

TABLES = ("members", "payments", "credits", "subscriptions")


def read(path: str) -> tuple[list[str], int, dict[str, int]]:
    con = sqlite3.connect(f"file:{quote(path)}?mode=ro&immutable=1", uri=True)
    try:
        check = [row[0] for row in con.execute("PRAGMA integrity_check")]
        names = {row[0] for row in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        counts = {
            t: con.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0] for t in TABLES if t in names
        }
        version = con.execute("PRAGMA user_version").fetchone()[0]
    finally:
        con.close()
    return check, version, counts


restored, reference = sys.argv[1], sys.argv[2]
try:
    check, version, counts = read(restored)
except sqlite3.Error as exc:
    print(f"      o SQLite restaurado não abre: {exc}", file=sys.stderr)
    sys.exit(1)

ref_counts: dict[str, int] = {}
ref_label = "local"
if reference:
    ref_label = Path(reference).name
    try:
        _, _, ref_counts = read(reference)
    except sqlite3.Error as exc:
        print(f"      a cópia local {ref_label} não abre ({exc}); sem comparação")
else:
    print("      sem cópia local no volume para comparar")

failed = check != ["ok"]
print(f"      {'integrity_check':<26} {'; '.join(check[:5])}")
print(f"      {'esquema':<26} v{version}")
for t in TABLES:
    rest = counts.get(t)
    ref = ref_counts.get(t, "?")
    if rest is None:
        print(f"      {t:<26} AUSENTE no restore")
        failed = True
    elif isinstance(ref, int) and rest > ref:
        print(f"      {t:<26} restore={rest} > {ref_label}={ref} (?)")
    else:
        print(f"      {t:<26} restore={rest:<8} {ref_label}={ref}")
sys.exit(1 if failed else 0)
PY
fi

# Postgres, Mongo e os tars não entram neste ensaio automático: restaurar Chatwoot ou n8n exige
# derrubar o serviço. O procedimento manual está no runbook.

[ "$FALHAS" -eq 0 ] || { echo "restore incompleto: $FALHAS conferência(s) falharam" >&2; exit 1; }
echo "pronto: o backup volta."
