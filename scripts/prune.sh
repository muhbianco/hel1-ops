#!/usr/bin/env bash
# prune.sh — limpeza diária do Docker na hel1 (cron do Woodpecker, repo hel1-ops).
# Substitui o `docker system prune -af` que rodava a cada deploy: com 2 pipelines em paralelo,
# aquilo apagava cache e imagens do outro pipeline no meio do build.
#
#   - imagens sem uso há mais de 7 dias, exceto as locais (label br.com.muhbianco.local=1);
#   - das imagens locais (muchat-web etc.), guarda as KEEP_LOCAL tags mais novas por repositório
#     (rollback) e nunca remove uma imagem em uso. O filtro é awk, não grep: sob `pipefail`, um
#     grep sem nenhuma linha casada devolve 1 e derruba o script — foi o que aconteceu quando
#     sobrou só `muchat-web:latest`, e a limpeza de cache abaixo deixou de rodar por dias;
#   - cache do BuildKit limitado a BUILD_CACHE_MAX (os mais antigos saem primeiro).
set -euo pipefail

KEEP_LOCAL="${KEEP_LOCAL:-5}"
BUILD_CACHE_MAX="${BUILD_CACHE_MAX:-20GB}"

echo "== antes"; docker system df

docker image prune -af --filter "until=168h" --filter "label!=br.com.muhbianco.local=1"

in_use=$(docker ps -a --format '{{.Image}}' | sort -u)
docker image ls --filter "label=br.com.muhbianco.local=1" --format '{{.Repository}}' | sort -u |
  while read -r repo; do
    docker image ls "$repo" --format '{{.CreatedAt}}|{{.Repository}}:{{.Tag}}' |
      awk -F'[|]' '$2 !~ /:(<none>|latest)$/' |
      sort -r | tail -n +"$((KEEP_LOCAL + 1))" | cut -d'|' -f2 |
      while read -r ref; do
        if printf '%s\n' "$in_use" | grep -qxF "$ref"; then continue; fi
        docker image rm "$ref" >/dev/null && echo "removida $ref" || true
      done
  done

docker buildx prune -f --max-used-space "$BUILD_CACHE_MAX"

echo "== depois"; docker system df
