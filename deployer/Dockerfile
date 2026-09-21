# ci-deployer — imagem dos steps de build/deploy dos pipelines Woodpecker na hel1.
# Fala com o dockerd do host pelo /var/run/docker.sock montado no step (repo Trusted).
# Não carrega segredo nenhum: login do Docker Hub, token do Portainer e env files vêm
# de arquivos do host montados read-only só nos steps de deploy.
FROM docker:29.8.1-cli

RUN apk add --no-cache bash coreutils curl findutils flock git openssl python3 rsync \
 && git config --system --add safe.directory '*' \
 && docker compose version && docker buildx version

COPY scripts/hel1-deploy scripts/hel1-build scripts/publish-muchat-desktop.sh scripts/prune.sh /usr/local/bin/
COPY scripts/portainer-stack-update.py /usr/local/bin/portainer-stack-update
RUN chmod 755 /usr/local/bin/hel1-deploy /usr/local/bin/hel1-build /usr/local/bin/publish-muchat-desktop.sh \
      /usr/local/bin/prune.sh /usr/local/bin/portainer-stack-update

ENV HEL1_DEPLOY_STATE=/var/lib/hel1-deploy
