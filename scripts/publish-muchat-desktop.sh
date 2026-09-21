#!/usr/bin/env bash
# publish-muchat-desktop.sh — publica o instalador do Muchat desktop no feed do electron-updater.
#
#   publish-muchat-desktop.sh --dist desktop/dist --version 1.0.26 \
#       --dest /usr/src/stoat/brand/public/download [--canary <sufixo>]
#
# Regras (a URL do Partner Center/Store e os .exe antigos nunca mudam):
#   - nunca sobrescreve arquivo existente: aborta se Muchat-Setup-<v>.exe já está no destino;
#   - .exe e .blockmap entram via arquivo temporário + mv sem clobber (mesmo filesystem);
#   - latest.yml é trocado por ÚLTIMO (mv atômico): o updater nunca vê um exe ausente;
#   - sha512 do latest.yml é conferido contra o .exe antes e o feed público depois.
#   --canary <sufixo>: publica só em <dest>/canary/Muchat-Setup-<v>-<sufixo>.exe, sem latest.yml
#                      (fora do feed de update), para testar o instalador no Windows.
set -euo pipefail

DIST="" VERSION="" DEST="" CANARY=""
FEED_URL="${MUCHAT_FEED_URL:-https://chat.muhbianco.com.br/download/latest.yml}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dist) DIST=$2; shift 2 ;;
    --version) VERSION=$2; shift 2 ;;
    --dest) DEST=$2; shift 2 ;;
    --canary) CANARY=$2; shift 2 ;;
    *) echo "opção desconhecida: $1" >&2; exit 2 ;;
  esac
done
[ -n "$DIST" ] && [ -n "$VERSION" ] && [ -n "$DEST" ] || { sed -n '2,14p' "$0"; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "versão inválida: $VERSION" >&2; exit 2; }
[ -d "$DEST" ] || { echo "destino não existe: $DEST" >&2; exit 2; }

EXE="Muchat-Setup-$VERSION.exe"
YML="$DIST/latest.yml"
for f in "$DIST/$EXE" "$DIST/$EXE.blockmap" "$YML"; do
  [ -s "$f" ] || { echo "faltando no build: $f" >&2; exit 1; }
done

yml_field() { sed -n "s/^$1: *//p" "$YML" | head -n 1 | tr -d "'\""; }
[ "$(yml_field version)" = "$VERSION" ] || { echo "latest.yml version != $VERSION" >&2; exit 1; }
[ "$(yml_field path)" = "$EXE" ] || { echo "latest.yml path != $EXE" >&2; exit 1; }
want=$(yml_field sha512)
got=$(openssl dgst -sha512 -binary "$DIST/$EXE" | base64 | tr -d '\n')
[ "$want" = "$got" ] || { echo "sha512 do latest.yml não bate com $EXE" >&2; exit 1; }
echo "build ok: $EXE ($(stat -c %s "$DIST/$EXE") bytes)"

# cp para temporário no mesmo diretório + mv -n: o nome final aparece inteiro ou não aparece.
place() {
  local src=$1 dir=$2 name=$3 tmp
  [ -e "$dir/$name" ] && { echo "RECUSADO: $dir/$name já existe (nunca sobrescrever)" >&2; return 1; }
  tmp="$dir/.$name.$$.tmp"
  cp "$src" "$tmp" && chmod 644 "$tmp"
  mv -n "$tmp" "$dir/$name"
  if [ -e "$tmp" ]; then rm -f "$tmp"; echo "RECUSADO: $dir/$name apareceu durante a cópia" >&2; return 1; fi
  cmp -s "$src" "$dir/$name" || { echo "conteúdo divergente em $dir/$name" >&2; return 1; }
  echo "publicado: $dir/$name"
}

if [ -n "$CANARY" ]; then
  [[ "$CANARY" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "sufixo canary inválido" >&2; exit 2; }
  mkdir -p "$DEST/canary"
  place "$DIST/$EXE" "$DEST/canary" "Muchat-Setup-$VERSION-$CANARY.exe"
  echo "canary fora do feed: /download/canary/Muchat-Setup-$VERSION-$CANARY.exe"
  exit 0
fi

place "$DIST/$EXE" "$DEST" "$EXE"
place "$DIST/$EXE.blockmap" "$DEST" "$EXE.blockmap"

tmp="$DEST/.latest.yml.$$.tmp"
cp "$YML" "$tmp" && chmod 644 "$tmp"
mv -f "$tmp" "$DEST/latest.yml"
echo "feed trocado: latest.yml -> $VERSION"

served=$(curl -fsS --max-time 10 --retry 5 --retry-delay 3 --retry-all-errors "$FEED_URL")
printf '%s\n' "$served" | grep -q "^version: $VERSION\$" || { echo "feed público não mostra $VERSION" >&2; exit 1; }
printf '%s\n' "$served" | grep -qF "$want" || { echo "sha512 do feed público diverge" >&2; exit 1; }
echo "feed público ok: $FEED_URL -> $VERSION"
