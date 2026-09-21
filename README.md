# hel1-ops

Infra compartilhada da VPS **hel1** (Docker Swarm + Traefik + Portainer): a stack do
**Woodpecker CI** e as ferramentas que os pipelines de todos os repos usam para build e deploy.

| Caminho | O quê |
|---|---|
| `woodpecker/docker-stack.yml` | Stack `woodpecker` (server + 1 agent, máx. 2 pipelines simultâneos), `ci.muhbianco.com.br` |
| `scripts/portainer-stack-update.py` | Cria/atualiza stack no Portainer sem segredo passar por chat/log (só nomes de chave e hashes) |
| `scripts/hel1-build` | `docker build` + tags `:<sha12>` (+ extras) + push, com labels OCI |
| `scripts/hel1-deploy` | `docker service update` por serviço com lock, guarda de ordem, verificação, smoke e rollback |
| `scripts/publish-muchat-desktop.sh` | Publica o instalador do Muchat no feed do updater sem nunca sobrescrever um `.exe` |
| `scripts/prune.sh` | Limpeza diária de imagens/cache (cron do Woodpecker) |
| `deployer/Dockerfile` | Imagem `muhrilobianco/ci-deployer` (docker cli + compose + buildx + git + python + scripts) |
| `.woodpecker/` | Lint dos scripts, build da `ci-deployer`, cron de prune |

## Como o deploy funciona agora

**Deploy = commit/merge na branch de produção do repo.** O Woodpecker recebe o webhook do GitHub e roda
`ci` (testes) → `deploy` (build da imagem `:<sha12>` + push + atualização dos serviços). Não existe mais
`git pull` + `build.sh` na VPS no fluxo normal.

| Repo | Branch prod | Deploy |
|---|---|---|
| app-site | master | `hel1-deploy services` → `app-site_app_site` |
| api-agents | main | `hel1-deploy services` → `api-agents_api_agents`, `_celery_worker`, `_celery_beat` |
| bolsocoberto | main | `hel1-deploy services` → `bolso-editor_bolso_editor[_worker]` (+ `docker cp` do tema WP quando muda) |
| mucommerce | main | migração one-shot + `portainer-stack-update --set-env COMMERCE_TAG=<sha12>` |
| muchatwoot | mb/main | build do fork completo + `portainer-stack-update --set-env CHATWOOT_TAG=mb-<base>-<sha12>` |
| for-web | main | imagem local `muchat-web:<sha12>` + `docker compose -p stoat up -d web` |
| muchat | main | overlay `bootstrap.sh` + `docker compose -p stoat build/up`; backend Rust só com `patches/**`; desktop por tag `desktop-v*` |
| hel1-ops | main | build da `ci-deployer` (a stack `woodpecker` é atualizada à mão, ver abaixo) |

`api-cpf` está **desligada** (`docker service scale api-cpf_api_cpf=0`) e sem pipeline. Religar:
`docker service scale api-cpf_api_cpf=1`.

### Garantias do `hel1-deploy`
- **Lock por app** (`/var/lib/hel1-deploy/<app>.lock`): dois deploys do mesmo app nunca rodam juntos.
- **Guarda de ordem**: se o commit já implantado não é ancestral do atual (ou é mais novo), o pipeline
  atrasado sai com `superseded` e não mexe em nada.
- Confere imagem e `UpdateStatus` de cada serviço; o `failure_action: rollback` do YAML devolve a versão
  anterior sozinho se a task nova não sobe.
- Estado e histórico em `/var/lib/hel1-deploy/<app>.{sha,history}` — `hel1-deploy status`.
- **Nunca** cancela push: `WOODPECKER_DEFAULT_CANCEL_PREVIOUS_PIPELINE_EVENTS=pull_request`.

### Segredos
Nenhum segredo fica no Woodpecker nem nos YAML. Os steps de deploy (repos **Trusted → volumes**) montam
read-only arquivos que já existem no host:

| Arquivo no host | Usado por |
|---|---|
| `/root/.docker/config.json` | push no Docker Hub (login do host) |
| `/root/.portainer-token` | `portainer-stack-update` (commerce, chatwoot) |
| `/root/.mucommerce.env`, `/root/.mucommerce-minio.env` | migração do commerce |
| `/usr/src/stoat/.env` (via `/usr/src/stoat` montado) | `docker compose -p stoat` do muchat |

Se o push para o Docker Hub falhar por credencial (credential helper no host), criar os secrets
`docker_username` / `docker_password` no Woodpecker (só evento `push`) e trocar o step para `docker login`.

## Subir a stack `woodpecker` (uma vez)

Pré-requisitos: DNS `A ci.muhbianco.com.br → hel1`; GitHub **OAuth App** (não GitHub App) com homepage
`https://ci.muhbianco.com.br` e callback `https://ci.muhbianco.com.br/authorize`.

```bash
# na hel1, como root
git clone https://github.com/muhbianco/hel1-ops.git /usr/src/hel1-ops
# /root/.woodpecker.env (chmod 600): WOODPECKER_GITHUB_CLIENT=..., WOODPECKER_GITHUB_SECRET=...
# o agent secret é gerado direto no arquivo, sem aparecer na tela:
for k in WOODPECKER_AGENT_SECRET WOODPECKER_GRPC_SECRET; do
  grep -q "^$k=" /root/.woodpecker.env 2>/dev/null || \
    (umask 077; printf '%s=%s\n' "$k" "$(openssl rand -hex 32)" >> /root/.woodpecker.env)
done
cd /usr/src/hel1-ops
python3 scripts/portainer-stack-update.py --create --stack woodpecker \
  --yaml woodpecker/docker-stack.yml --env-file /root/.woodpecker.env --dry-run
python3 scripts/portainer-stack-update.py --create --stack woodpecker \
  --yaml woodpecker/docker-stack.yml --env-file /root/.woodpecker.env
```

Primeira imagem `ci-deployer` (depois ela se builda sozinha pelo pipeline):

```bash
cd /usr/src/hel1-ops && T=$(git rev-parse --short=12 HEAD)
docker build --pull -f deployer/Dockerfile -t muhrilobianco/ci-deployer:$T . \
  && docker tag muhrilobianco/ci-deployer:$T muhrilobianco/ci-deployer:1 \
  && docker push muhrilobianco/ci-deployer:$T && docker push muhrilobianco/ci-deployer:1
```

### Configurar no Woodpecker (UI, conta admin `muhbianco`)
1. Login com GitHub → **Add repository** para: `app-site`, `api-agents`, `mucommerce`, `muchatwoot`,
   `bolsocoberto`, `for-web`, `muchat`, `hel1-ops`.
2. Em cada repo → Settings → Project: **Trusted → Volumes** ligado (steps de deploy montam `docker.sock`
   e arquivos do host). Timeout: 60 min (padrão); **120 min** em `muchat` e `muchatwoot`.
3. `muchat`: Settings → Project → permitir o evento **Tag** (release do desktop).
4. `hel1-ops`: Settings → Crons → `prune-daily`, `0 4 * * *`, branch `main`.

### Atualizar a stack `woodpecker`
Editar `woodpecker/docker-stack.yml`, commit/push, e na hel1:

```bash
cd /usr/src/hel1-ops && git pull --ff-only
python3 scripts/portainer-stack-update.py --stack woodpecker --yaml woodpecker/docker-stack.yml --dry-run
python3 scripts/portainer-stack-update.py --stack woodpecker --yaml woodpecker/docker-stack.yml
```

## Rollback
1. Preferido: `git revert <commit>` + push na branch de produção (produção continua = branch).
2. Rápido (serviços): na hel1, `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock
   -v /var/lib/hel1-deploy:/var/lib/hel1-deploy muhrilobianco/ci-deployer:1 hel1-deploy rollback --app <app>`.
3. commerce / chatwoot: `portainer-stack-update.py --stack <stack> --yaml <yaml do repo> --set-env
   COMMERCE_TAG=<sha12 anterior>` (ou `CHATWOOT_TAG`). Migração do commerce é expand-first.

## Break-glass (Woodpecker fora do ar)
O fluxo antigo continua possível: `git pull --ff-only` em `/usr/src/<repo>`, `docker build`/`push`
com tag `:<sha12>` e `hel1-deploy`/`portainer-stack-update` à mão. Ver a skill `deploy` do workspace.
