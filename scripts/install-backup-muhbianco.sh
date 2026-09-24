#!/usr/bin/env bash
# Instala (ou atualiza) o timer do backup da plataforma MuhBianco na hel1. Roda como root:
#
#   bash scripts/install-backup-muhbianco.sh
#
# Idempotente: pode rodar de novo a cada deploy que mexer nos units.
#
# Ele **não** instala credencial — isso é o `set-backup-credentials-muhbianco.sh`. E não define
# retenção: ela é regra de ciclo de vida no bucket, de propósito, para a chave do B2 não precisar
# de permissão de apagar (ver o cabeçalho de `backup-muhbianco.sh`).
set -euo pipefail

REPO="${REPO:-/usr/src/hel1-ops}"
ENV_BACKUP="${ENV_BACKUP:-/root/.muhbianco-backup-b2.env}"

[ -r "$ENV_BACKUP" ] || {
  echo "rode set-backup-credentials-muhbianco.sh antes: $ENV_BACKUP ausente" >&2; exit 2; }
chmod +x "$REPO/scripts/backup-muhbianco.sh" "$REPO/scripts/backup-muhbianco-restore-test.sh"

install -m 644 "$REPO/systemd/muhbianco-backup.service" /etc/systemd/system/
install -m 644 "$REPO/systemd/muhbianco-backup.timer"   /etc/systemd/system/
mkdir -p /var/lib/muhbianco-backup

systemctl daemon-reload
systemctl enable --now muhbianco-backup.timer

echo
systemctl list-timers muhbianco-backup.timer --no-pager
echo
echo "primeiro backup à mão:      systemctl start muhbianco-backup.service"
echo "acompanhar:                 journalctl -u muhbianco-backup.service -f"
echo "ensaio sem enviar nada:     DRY_RUN=1 $REPO/scripts/backup-muhbianco.sh"
echo "só uma peça:                PECAS=mongo $REPO/scripts/backup-muhbianco.sh"
echo "restore de prova (mensal):  $REPO/scripts/backup-muhbianco-restore-test.sh"
