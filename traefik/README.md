# Traefik (borda da hel1)

`docker-stack.yml` é a stack `traefik` (v3.7.10): providers Swarm (labels), file
(`/root/dynamic_conf.yaml`) e **HTTP**, que puxa da `api-commerce` os domínios de tenant ativos
([ADR 0003 da mucommerce](https://github.com/muhbianco/mucommerce/blob/main/docs/adr/0003-traefik-http-provider.md)).
Certificados: ACME HTTP-01 por host (`letsencryptresolver`), sem wildcard.

A stack não é do Portainer nem do Woodpecker: muda raramente e derruba a borda de todos os sites
por alguns segundos, então o deploy é manual, na hel1, com `apply.sh`.

## Aplicar

```bash
cd /usr/src/hel1-ops && git pull
traefik/apply.sh --check   # não muda nada
traefik/apply.sh
```

`--check` valida o arquivo (`docker stack config`), mostra o diff contra `/root/traefik.yaml`
(último aplicado), chama o endpoint do provider de dentro da `chatbot-net` com o token e confere se
cada host dinâmico resolve para `edge.muhbianco.com.br`. Host sem DNS aborta o apply (o ACME
falharia para ele; o Let's Encrypt aceita só 5 falhas por hora por host), a não ser com `--force`.

O apply anota o status dos sites estáticos, faz `docker stack deploy`, espera o serviço
estabilizar e confere os sites de novo. Se algum piorou, faz `docker service rollback` sozinho.
Depois mostra o log do provider/ACME e o HTTPS de cada host dinâmico (o certificado sai no
primeiro minuto). No fim, copia o arquivo para `/root/traefik.yaml` (backup datado ao lado).

Rollback manual: `traefik/apply.sh --rollback` (volta à spec anterior do serviço).

## Segredo

`INTERNAL_TOKEN_TRAEFIK` (o mesmo da stack `commerce`) vem de `/root/.mucommerce.env` direto para
o `docker stack deploy`. Ele fica nos args do serviço. Por isso:

- não despejar `docker service inspect traefik_traefik` sem filtro;
- não subir `--log.level` para DEBUG (o Traefik loga a config estática, com o header).

Trocar o token: atualizar `/root/.mucommerce.env` e o Env da stack `commerce`, fazer o deploy da
`commerce` e rodar `apply.sh`. Entre um passo e outro, o provider recebe 401 e o Traefik segue com
a última config boa.

## Access log

O access log vai para o stdout do serviço (`docker service logs traefik_traefik`, também visível no
Portainer), em formato common, com rotação do `json-file` do Docker (10 MB × 3, cerca de 4 dias de
tráfego). Ele grava o caminho, **sem query string**
(`--accesslog.fields.queryParameters.defaultMode=drop`). Antes da flag gravava. Na medição de
13/11/2026, os 4 dias guardados tinham na query: token de sessão do Stoat (`/ws?token=`, 35 linhas), JWT do LiveKit
(`/livekit/rtc/v1?access_token=`, 14), `access_token` do webhook do Woodpecker (`/api/hook`, 9) e
`code`/`state` do OAuth do yt-family (3).

Referer e User-Agent saem `"-"`: os headers ficam em drop por padrão (`accesslog.fields.headers`),
e o Referer pode levar a query da página. A flag foi conferida no código da v3.7.10
(`pkg/middlewares/accesslog/logger.go` monta o `RequestPath` sem `RawQuery`) e num Traefik local
com a mesma linha de comando. Ao trocar a versão do Traefik, repetir esse teste.

Regras, cobradas por `traefik/test_docker_stack.py` no CI:

- com access log ligado, a query fica em `drop`;
- nenhum header em `keep`;
- `--log.level` nunca DEBUG/TRACE.

O apply conta (só conta) as linhas da task nova com query no caminho e avisa se houver alguma.
Conferir à mão:

```bash
docker service logs --since 10m --no-task-ids traefik_traefik 2>&1 |
  awk -F'"' '$2 ~ / HTTP\// {n++; if ($2 ~ /\?/) q++} END {printf "linhas=%d com_query=%d\n", n, q}'
```

Nunca imprimir as linhas que casam, só contar: são justamente as que têm credencial.

## Falhas

- API fora do ar ou 401: o Traefik loga o erro e mantém a última config em memória; hosts de labels
  não dependem do provider. Traefik reiniciado com a API fora: só os hosts dinâmicos ficam fora.
- `docker stack deploy` à mão sem a variável: header vazio → 401 → mesmo caso acima.
