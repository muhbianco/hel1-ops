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
| `arquivos` | mídia e config do Muchat (`data/minio`, `Revolt.toml`, `stoat.json`, `Caddyfile`, `livekit.yml`, `brand/public`), MinIO da plataforma (`outline`, `typebot`, `schedule-artifacts`), volumes (anexos do Chatwoot, avatares do agente, stacks do Portainer) | `/usr/src/stoat`, volumes do Docker |

**Fora, de propósito:** `bolsocoberto` (outro produto — ligue com `INCLUIR_BOLSO=1` se quiser
junto), os buckets `gazettes` e `emissao-nf` no MinIO (não são da plataforma) e o Redis (efêmero
por desenho: fila e cache, com o outbox garantindo reentrega).

## Como funciona

Cada peça vira **um arquivo próprio**, `<nome>-<carimbo UTC>.{sql,tar,archive}.zst.gpg`, no
prefixo `daily/<peça>/`. Domingo ganha uma cópia em `weekly/` — cópia no servidor, sem subir de
novo. As quatro decisões que valem lembrar:

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

**Ensaio automático (mensal):** `bash scripts/backup-muhbianco-restore-test.sh` baixa o dump mais
recente de `api_agents`, decifra e restaura em `api_agents_restore_check`, comparando as contagens
de `users`, `wallets`, `user_services`, `service_charges` e `agent_messages`. O destino é fixo e
termina em `_restore_check`; o script recusa qualquer outro.

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
| `arquivos` | `tar -xf restaurado -C <destino>` com o serviço parado |

Restaurar Chatwoot, n8n ou Typebot exige derrubar o serviço antes — por isso o ensaio automático
cobre só o MariaDB, que restaura num banco lateral sem tocar em produção.

## Ensaios feitos

| Data | Arquivo | Resultado |
|---|---|---|
| _(preencher no primeiro ensaio)_ | | |
