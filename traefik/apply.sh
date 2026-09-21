#!/usr/bin/env bash
# Deploy da stack `traefik` (borda 80/443 de todos os sites da hel1). Rodar NA hel1, como root,
# a partir do clone /usr/src/hel1-ops depois de `git pull`:
#
#   traefik/apply.sh --check     # valida, mostra o diff, testa o provider e o DNS; não muda nada
#   traefik/apply.sh             # --check + deploy + verificação (o Traefik reinicia: ~5-10 s sem borda)
#   traefik/apply.sh --force     # idem, mesmo com host dinâmico cujo DNS não aponta para a borda
#   traefik/apply.sh --rollback  # volta o serviço para a spec anterior (docker service rollback)
#
# Segredo: INTERNAL_TOKEN_TRAEFIK sai de /root/.mucommerce.env direto para o ambiente do
# `docker stack deploy` e do container de teste do provider. Nada aqui imprime o valor.
# Se um site estático piorar depois do deploy, o script faz rollback sozinho.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STACK="traefik"
SERVICE="traefik_traefik"
FILE="${TRAEFIK_STACK_FILE:-$HERE/docker-stack.yml}"
ENV_FILE="${TRAEFIK_ENV_FILE:-/root/.mucommerce.env}"
# Cópia do último arquivo aplicado (com ${VAR}, sem segredo). Antes desta ferramenta era a fonte.
APPLIED="${TRAEFIK_APPLIED_FILE:-/root/traefik.yaml}"
EDGE_HOST="${EDGE_HOST:-edge.muhbianco.com.br}"
PROVIDER_URL="http://commerce-api:8000/api/v1/internal/edge/traefik"
PROBE_IMAGE="${PROBE_IMAGE:-muhrilobianco/ci-deployer:1}"
STATIC_URLS=(
  https://muhbianco.com.br/
  https://loja.muhbianco.com.br/
  https://api-commerce.muhbianco.com.br/healthz
  https://chatwoot.muhbianco.com.br/
  https://ci.muhbianco.com.br/
)

MODE="apply"
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --rollback) MODE="rollback" ;;
    --force) FORCE=1 ;;
    *) echo "uso: $0 [--check | --force | --rollback]" >&2; exit 2 ;;
  esac
done

die() { echo "ABORT: $*" >&2; exit 1; }
code_of() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" || true; }
a_records() { dig +short A "$1" @1.1.1.1 | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u || true; }

wait_service() {  # waits for the update to settle and a task to be running
  local state i
  for i in $(seq 1 60); do
    state="$(docker service inspect "$SERVICE" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{else}}none{{end}}')"
    if [ "$state" != "updating" ] && [ "$state" != "rollback_started" ] &&
      docker service ps "$SERVICE" --filter desired-state=running --format '{{.CurrentState}}' | grep -q '^Running'; then
      echo "serviço: update=$state, task rodando (${i}x2 s)"
      return 0
    fi
    sleep 2
  done
  echo "serviço: não estabilizou em 120 s (update=$state)"
  return 1
}

declare -A BASELINE=()
snapshot_static() {
  local url
  for url in "${STATIC_URLS[@]}"; do BASELINE[$url]="$(code_of "$url")"; done
}

static_ok() {  # every URL that answered < 400 before still does; retries for up to 60 s
  local url code i bad
  for i in $(seq 1 12); do
    bad=0
    for url in "${STATIC_URLS[@]}"; do
      [ "${BASELINE[$url]:-000}" -lt 400 ] 2>/dev/null && [ "${BASELINE[$url]}" != 000 ] || continue
      code="$(code_of "$url")"
      if [ "$code" = 000 ] || [ "$code" -ge 400 ]; then bad=1; fi
    done
    [ "$bad" = 0 ] && break
    sleep 5
  done
  for url in "${STATIC_URLS[@]}"; do
    printf '  %-48s antes=%s depois=%s\n' "$url" "${BASELINE[$url]:-?}" "$(code_of "$url")"
  done
  return "$bad"
}

[ "$(id -u)" = 0 ] || die "rodar como root na hel1"

if [ "$MODE" = rollback ]; then
  for url in "${STATIC_URLS[@]}"; do BASELINE[$url]=200; done  # the point is to get them all back
  docker service rollback --detach "$SERVICE" >/dev/null
  wait_service || true
  static_ok || die "sites estáticos ainda com erro depois do rollback"
  echo "rollback ok. $APPLIED continua como está; o próximo apply reaplica o arquivo do repo."
  exit 0
fi

# ------------------------------------------------------------------ check
[ -f "$FILE" ] || die "arquivo da stack não encontrado: $FILE"
[ -f "$ENV_FILE" ] || die "env file não encontrado: $ENV_FILE"
INTERNAL_TOKEN_TRAEFIK="$(sed -n 's/^INTERNAL_TOKEN_TRAEFIK=//p' "$ENV_FILE" | head -n 1)"
[ -n "$INTERNAL_TOKEN_TRAEFIK" ] || die "INTERNAL_TOKEN_TRAEFIK ausente em $ENV_FILE"
export INTERNAL_TOKEN_TRAEFIK

docker stack config -c "$FILE" >/dev/null || die "docker stack config recusou $FILE"
echo "arquivo: $FILE sha256=$(sha256sum "$FILE" | cut -c1-16) (válido)"

echo "--- diff contra o último aplicado ($APPLIED)"
diff -u "$APPLIED" "$FILE" || true
echo "---"

edge_json="$(
  docker run --rm --network chatbot-net -e INTERNAL_TOKEN_TRAEFIK --entrypoint sh "$PROBE_IMAGE" -c \
    'code=$(curl -sS --max-time 10 -o /tmp/edge.json -w "%{http_code}" -H "X-Internal-Token: $INTERNAL_TOKEN_TRAEFIK" "$0") || true
     [ "$code" = 200 ] || { echo "provider http=$code" >&2; exit 1; }
     cat /tmp/edge.json' "$PROVIDER_URL"
)" || die "o endpoint do provider não respondeu 200 com o token de $ENV_FILE"

hosts_txt="$(printf '%s' "$edge_json" | python3 -c '
import json, re, sys
routers = json.load(sys.stdin)["http"]["routers"]
for host in sorted({h for r in routers.values() for h in re.findall(r"Host\(`([^`]+)`\)", r["rule"])}):
    print(host)
')" || die "resposta do provider não é a config esperada"
HOSTS=()
[ -z "$hosts_txt" ] || mapfile -t HOSTS <<<"$hosts_txt"
echo "provider: 200, ${#HOSTS[@]} host(s) dinâmico(s)"

edge_ips="$(a_records "$EDGE_HOST")"
[ -n "$edge_ips" ] || die "$EDGE_HOST não resolve"
dns_bad=0
for host in "${HOSTS[@]}"; do
  [ -n "$host" ] || continue
  got="$(a_records "$host")"
  if [ "$got" = "$edge_ips" ]; then
    printf '  ok   %s\n' "$host"
  else
    printf '  DNS  %s → %s (borda: %s)\n' "$host" "${got:-nada}" "$(echo "$edge_ips" | paste -sd, -)"
    dns_bad=1
  fi
done
if [ "$dns_bad" = 1 ] && [ "$FORCE" = 0 ]; then
  msg="host dinâmico sem DNS para a borda: o ACME falharia para ele (limite de 5 falhas/h por host)."
  [ "$MODE" = check ] && { echo "AVISO: $msg"; exit 0; }
  die "$msg Corrija o DNS ou use --force."
fi
[ "$MODE" = check ] && { echo "check ok: nada foi alterado"; exit 0; }

# ------------------------------------------------------------------ apply
snapshot_static
start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker stack deploy -c "$FILE" "$STACK"
if ! wait_service || ! static_ok; then
  echo "sites estáticos pioraram: rollback automático"
  docker service rollback --detach "$SERVICE" >/dev/null
  wait_service || true
  static_ok || true
  die "deploy revertido"
fi

echo "--- log do provider http / ACME desde $start (sem headers)"
docker service logs --since "$start" "$SERVICE" 2>&1 |
  grep -E 'providerName=http|acme' | grep -viE 'token|header' | cut -c1-300 | tail -n 20 || true
echo "---"

for host in "${HOSTS[@]}"; do
  [ -n "$host" ] || continue
  code=000
  for _ in $(seq 1 24); do  # até 2 min: o certificado HTTP-01 sai no primeiro minuto
    code="$(code_of "https://$host/")"
    [ "$code" != 000 ] && break
    sleep 5
  done
  printf '  %-40s https=%s%s\n' "$host" "$code" "$([ "$code" = 000 ] && echo ' (TLS/conexão falhou)')"
done

cp -p "$APPLIED" "$APPLIED.$(date +%Y%m%d%H%M%S).bak"
cp "$FILE" "$APPLIED"
echo "apply ok. $APPLIED atualizado (backup ao lado)."
