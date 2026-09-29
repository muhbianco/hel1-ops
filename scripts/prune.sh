#!/usr/bin/env bash
# prune.sh — limpeza diária do Docker na hel1 (cron do Woodpecker, repo hel1-ops).
# Substitui o `docker system prune -af` que rodava a cada deploy: com 2 pipelines em paralelo,
# aquilo apagava cache e imagens do outro pipeline no meio do build.
#
# **Retenção por contagem, não por idade.** A versão anterior guardava tudo que tivesse menos de
# 7 dias, e isso não segura um repositório que sobe dez vezes por dia: o commerce sozinho
# acumulava ~140 imagens antes da primeira ficar velha o bastante para sair. Foram 60 GB
# descobertos na marra em 29/09/2026. Agora cada repositório nosso guarda as N mais novas e o
# resto sai no mesmo dia; a idade continua valendo só para imagem de terceiro (postgres, redis),
# que muda pouco e cujo download é caro.
#
#   - imagens nossas (Docker Hub): as KEEP_PUSHED mais novas por repositório. Rollback não
#     depende disto — `docker service update` puxa do registry se faltar aqui;
#   - imagens locais (label br.com.muhbianco.local=1, sem registry): KEEP_LOCAL, que é a única
#     cópia que existe;
#   - imagem em uso nunca sai, venha de onde vier;
#   - imagens de terceiros sem uso há mais de UNUSED_HOURS;
#   - contêineres parados há mais de STOPPED_HOURS (levam junto o log e a camada de escrita);
#   - cache do BuildKit limitado a BUILD_CACHE_MAX (os mais antigos saem primeiro).
set -euo pipefail

KEEP_LOCAL="${KEEP_LOCAL:-5}"
KEEP_PUSHED="${KEEP_PUSHED:-3}"
UNUSED_HOURS="${UNUSED_HOURS:-168}"
STOPPED_HOURS="${STOPPED_HOURS:-48}"
BUILD_CACHE_MAX="${BUILD_CACHE_MAX:-10GB}"

echo "== antes"; docker system df

in_use=$(docker ps -a --format '{{.Image}}' | sort -u)

# Guarda as `keep` tags mais novas de um repositório e remove o resto.
#
# O filtro é awk, não grep: sob `pipefail`, um grep sem nenhuma linha casada devolve 1 e derruba
# o script — foi o que aconteceu quando sobrou só `muchat-web:latest`, e a limpeza de cache
# abaixo deixou de rodar por dias. `:latest` e `:<none>` ficam de fora da contagem porque são
# ponteiros: apagar a tag não libera a imagem, que continua referenciada pela tag de sha.
trim_repo() {
  local repo="$1" keep="$2" ref
  docker image ls "$repo" --format '{{.CreatedAt}}|{{.Repository}}:{{.Tag}}' |
    awk -F'[|]' '$2 !~ /:(<none>|latest)$/' |
    sort -r | tail -n +"$((keep + 1))" | cut -d'|' -f2 |
    while read -r ref; do
      if printf '%s\n' "$in_use" | grep -qxF "$ref"; then continue; fi
      docker image rm "$ref" >/dev/null 2>&1 && echo "removida $ref" || true
    done
}

# Nossas, que também vivem no Docker Hub.
docker image ls --format '{{.Repository}}' |
  awk '/^muhrilobianco\//' | sort -u |
  while read -r repo; do trim_repo "$repo" "$KEEP_PUSHED"; done

# Construídas aqui e sem cópia em registry nenhum.
docker image ls --filter "label=br.com.muhbianco.local=1" --format '{{.Repository}}' | sort -u |
  while read -r repo; do trim_repo "$repo" "$KEEP_LOCAL"; done

# De terceiros: por idade, porque baixar de novo custa e elas mudam pouco.
docker image prune -af \
  --filter "until=${UNUSED_HOURS}h" \
  --filter "label!=br.com.muhbianco.local=1"

# Contêiner parado ainda ocupa o log e a camada de escrita dele.
docker container prune -f --filter "until=${STOPPED_HOURS}h"

docker buildx prune -f --max-used-space "$BUILD_CACHE_MAX"

echo "== depois"; docker system df
