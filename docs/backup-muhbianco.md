# Backup da plataforma MuhBianco (Backblaze B2)

Tudo que não volta com um `git push`: os bancos, as mídias e a configuração que os serviços não
reconstroem sozinhos. Cifrado na hel1 antes de sair, enviado para o bucket **`app-muhbianco`**.

O backup das lojas (mucommerce) é irmão deste e mora no outro repo:
`mucommerce/infra/backup/` → bucket **`mu-commerce`**.

## O que entra

| Peça | Conteúdo | Onde vive hoje |
|---|---|---|
| `mariadb` | `api_agents` — contas, carteira, assinaturas, cobranças, agentes, mensagens, convites | MariaDB nativo do host |
| `postgres` | `n8n_queue`, `typebot`, `outline`, `wiki` | serviço `postgres_postgres` |
| `pgvector` | `api_agents_kb` (KB do agente, com embeddings), `chatwoot_production`, `chatwoot` | serviço `pgvector_pgvector` |
| `mongo` | `revolt` (Muchat) e `muchat_study` (bot de estudo) | `stoat-database-1` |
| `ytfamily` | SQLite do portal da família Premium (`yt.muhbianco.com.br`): membros, pagamentos, **livro de créditos**, assinaturas — a cópia diária que o próprio app grava | volume `yt-family_data` (`backups/yt-AAAA-MM-DD.db`) |
| `arquivos` | mídia e config do Muchat (`data/minio`, `Revolt.toml`, `stoat.json`, `Caddyfile`, `livekit.yml`, `brand/public` **sem** `download/`), MinIO da plataforma (`outline`, `typebot`, `schedule-artifacts`), volumes (anexos do Chatwoot, avatares do agente, stacks do Portainer) | `/usr/src/stoat`, volumes do Docker |
| `artefatos` | feed do Muchat desktop (`Muchat-Setup-*.exe`, `*.apk`, `latest.yml`) por `s3 sync` em `artefatos/`, sem cifrar | `/usr/src/stoat/brand/public/download` |

**Fora, de propósito:** `bolsocoberto` (outro produto — ligue com `INCLUIR_BOLSO=1` se quiser
junto), os buckets `gazettes` e `emissao-nf` no MinIO (não são da plataforma) e o Redis (efêmero
por desenho: fila e cache, com o outbox garantindo reentrega).

## Como funciona

Cada peça vira **um arquivo próprio**, `<nome>-<carimbo UTC>.{sql,tar,db}.zst.gpg`, no prefixo
`daily/<peça>/`. Domingo ganha uma cópia em `weekly/` — cópia no servidor, sem subir de novo.
A exceção é `artefatos`: os instaladores do Muchat desktop são ~360 MB que **nunca mudam** depois
de publicados (o updater dos clientes confere o sha512 de cada um), então vão por `s3 sync` num
prefixo próprio, sem cifragem e sem reenvio — o dia seguinte a um release sobe só o arquivo novo.
São os mesmos bytes que qualquer um baixa do site, e assim o resgate não depende da senha.

`ytfamily` não copia o banco vivo. O app grava em WAL, então o `yt.db` do volume sozinho não é o
banco (o que acabou de entrar mora no `yt.db-wal`), e copiar os três arquivos com o app escrevendo
pega um meio-termo. A fonte é a cópia diária que o próprio app faz com a API de backup do SQLite,
logo depois da meia-noite UTC (`backups/yt-AAAA-MM-DD.db`, 14 guardadas no volume): consistente e
sem `docker exec`. O job acha o volume por `docker volume inspect yt-family_data`, pega a mais nova
que não foi mexida no último minuto (a do dia pode estar sendo escrita por um contêiner que acabou
de subir), confere `integrity_check` e as tabelas, cifra e confere decifrando **byte a byte**.
Se a mais nova for de antes de ontem, ela sobe mesmo assim e a peça fecha em erro: é o sinal de que
o laço do app que grava as cópias parou. O preço é o RPO — o B2 fica com o livro da meia-noite UTC;
pagamento que entrou depois se refaz pela importação do histórico do Mercado Pago no admin (ajuste
manual feito depois, não).

As quatro decisões que valem lembrar:

1. **Nunca apaga nada.** A retenção é regra de ciclo de vida no bucket, não do script: assim a
   app key do B2 não precisa de permissão de apagar, e backup que o invasor apaga com a chave que
   achou no servidor não é backup.
2. **Confere decifrando.** Depois de cifrar, o arquivo volta (decifra + descomprime) e a marca de
   fim do dump é checada antes de qualquer upload. É o que pega dump truncado, disco cheio no
   meio e senha errada — as três coisas que passam despercebidas até o dia do restore.
3. **Senha nunca em `argv`.** Entra por descritor de arquivo; as chaves do B2 entram no contêiner
   por nome de variável. `ps` é legível por qualquer processo.
4. **Peça que falha não derruba as outras.** Todas rodam, o job fecha em erro no fim dizendo
   quais quebraram. Backup parcial é melhor do que nenhum.

## Instalar (na hel1, como root)

```bash
cd /usr/src/hel1-ops && git pull --ff-only
bash scripts/set-backup-credentials-muhbianco.sh   # digita endpoint, bucket, chaves e senha
bash scripts/install-backup-muhbianco.sh           # instala o timer (03:45 UTC, diário)
DRY_RUN=1 scripts/backup-muhbianco.sh              # ensaio: faz tudo menos o upload
systemctl start muhbianco-backup.service           # primeiro backup de verdade
journalctl -u muhbianco-backup.service -f
```

Antes disso, no painel do Backblaze:

- **app key restrita ao bucket `app-muhbianco`** (a Master Application Key não funciona na API S3).
  Chave que enxerga a conta inteira transforma um vazamento num problema maior do que precisa ser.
- **regras de ciclo de vida** no bucket, que é onde a retenção mora:
  `daily/` → manter 8 dias; `weekly/` → manter 35 dias.
  ⚠️ O bucket está hoje em *Keep all versions*: sem essas regras ele **cresce para sempre**.
  Se o Object Lock estiver com retenção padrão, a regra só apaga depois que o lock expira.

⚠️ **A senha de cifragem precisa existir fora da hel1.** Ela fica no servidor para o job cifrar
sozinho; se o servidor morrer — o cenário do backup — e a senha só existir nele, os arquivos viram
lixo cifrado. Guarde uma cópia no gerenciador de senhas.

## Restore

**Ensaio automático (mensal):** `bash scripts/backup-muhbianco-restore-test.sh` roda dois ensaios
(`ENSAIOS=mariadb` ou `ENSAIOS=ytfamily` para um só):

- `mariadb`: baixa o dump mais recente de `api_agents`, decifra e restaura em
  `api_agents_restore_check`, comparando as contagens de `users`, `wallets`, `user_services`,
  `service_charges` e `agent_messages`. O destino é fixo e termina em `_restore_check`; o script
  recusa qualquer outro.
- `ytfamily`: baixa o SQLite mais recente, decifra num diretório temporário e o abre: exige
  `PRAGMA integrity_check` = `ok` e as tabelas `members`, `payments`, `credits` e `subscriptions`,
  com as contagens lado a lado com a cópia diária mais nova do volume (aberta com `immutable=1`,
  sem trava nem arquivo novo no volume; o banco vivo não é tocado).

**Na mão, por peça** (baixe o arquivo do bucket, decifre e restaure):

```bash
gpg --batch --pinentry-mode loopback --passphrase-fd 3 --decrypt ARQUIVO.gpg 3<<<"$SENHA" \
  | zstd -d -q -c >restaurado
```

| Peça | Restaurar com |
|---|---|
| `mariadb` | `mariadb <schema> < restaurado` |
| `postgres` / `pgvector` | `docker exec -i <container> psql -U postgres -d <db> < restaurado` |
| `mongo` | `tar -xf restaurado` e, para cada arquivo, `docker exec -i stoat-database-1 mongorestore --archive < <db>.archive` |
| `ytfamily` | `docker service scale yt-family_app=0`; no volume (`docker volume inspect yt-family_data`), guardar o `yt.db` atual à parte, **apagar `yt.db-wal` e `yt.db-shm`** (um `-wal` velho seria reaplicado sobre o banco restaurado), `install -o 1001 -g 1001 -m 644 restaurado <volume>/yt.db`; `docker service scale yt-family_app=1` |
| `arquivos` | `tar -xf restaurado -C <destino>` com o serviço parado |
| `artefatos` | `aws s3 sync s3://app-muhbianco/artefatos/muchat-download/ /usr/src/stoat/brand/public/download/` (sem decifrar) |

Restaurar Chatwoot, n8n ou Typebot exige derrubar o serviço antes — por isso o ensaio automático
cobre só o MariaDB, que restaura num banco lateral sem tocar em produção, e o SQLite do yt-family,
que se confere abrindo o arquivo.

## Ensaios feitos

| Data | Arquivo | Resultado |
|---|---|---|
| 24/09/2026 | `daily/mariadb/api_agents-20260924T155059Z.sql.zst.gpg` (288 KB) | ok — 38 tabelas; `users` 19, `wallets` 13, `user_services` 15, `service_charges` 86, `agent_messages` 1179, iguais à produção |

Primeira execução completa em 24/09/2026: MariaDB, os dois Postgres, o Mongo e os três tars, mais
o sync de 16 arquivos do feed do desktop. O tar do Muchat passou de 412 MB para 41 MB quando o
feed saiu dele.
