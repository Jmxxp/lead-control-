# Jornada e atribuicao: Meta Ads + Google Ads

O modulo separa cada loja, cifra credenciais no banco, captura touchpoints com
consentimento, sincroniza custos/desempenho e envia conversoes offline por uma
fila com lease e idempotencia. O navegador nunca recebe tokens dos provedores.

## 1. Instalar o banco

Execute `marketing_attribution_module.sql` no SQL Editor depois do banco base.
A migration e aditiva e usa nomes `ma_*`, portanto nao depende da antiga
`marketing_intelligence_update.sql`.

## 2. Configurar segredos das Edge Functions

Gere tres valores aleatorios diferentes, com ao menos 32 caracteres:

```bash
openssl rand -hex 32 # MARKETING_CREDENTIALS_KEY
openssl rand -hex 32 # MARKETING_WORKER_SECRET
openssl rand -hex 32 # MARKETING_TRACKING_PEPPER
```

Cadastre-os sem coloca-los no Git:

```bash
supabase secrets set \
  MARKETING_CREDENTIALS_KEY='...' \
  MARKETING_WORKER_SECRET='...' \
  MARKETING_TRACKING_PEPPER='...' \
  MARKETING_ALLOWED_ORIGINS='https://SEU-SITE' \
  MARKETING_APP_ORIGINS='https://SEU-SITE'
```

`MARKETING_CREDENTIALS_KEY` precisa permanecer a mesma; troca-la sem uma rotina
de recriptografia torna as credenciais antigas ilegíveis.

## 3. Publicar as funcoes

```bash
supabase functions deploy marketing-api --no-verify-jwt
supabase functions deploy marketing-worker --no-verify-jwt
```

`verify_jwt=false` e intencional: o projeto usa `x-app-session`, validado por
`app_private.session_user`. O worker ainda exige `x-worker-secret`.

## 4. Agendar o worker

No Vault do Supabase, crie:

- `marketing_project_url`: `https://SEU-PROJETO.supabase.co`
- `marketing_worker_secret`: exatamente o `MARKETING_WORKER_SECRET`

Depois execute `marketing_scheduler.sql`. Ele usa Vault + `pg_cron` + `pg_net`,
sem gravar o segredo no job e roda a cada 2 minutos, evitando invocações e logs
desnecessários. O worker cria automaticamente uma carga inicial
de 90 dias e, depois, resincroniza uma janela de 7 dias a cada 6 horas. Falhas
usam backoff e cooldown para nao pressionar as APIs. Sincronizacoes manuais de
ate 730 dias sao divididas no servidor em lotes de no maximo 400 dias.

## 5. Credenciais Meta

Crie uma conexao com:

- `ad_account_id`;
- `dataset_id` (ou Pixel ID) para CAPI;
- `access_token` de longa duracao/System User com acesso ao ativo;
- `api_version` opcional (padrao `v26.0`);
- `test_event_code` opcional.

Use `test-connection`; somente apos a validacao o status vira `active`. O teste
consulta tanto a conta de anuncios quanto o Dataset/Pixel com o mesmo token.

## 6. Credenciais Google e OAuth

Antes de conectar:

1. habilite Google Ads API e Data Manager API no Google Cloud;
2. configure um OAuth Client do tipo Web;
3. autorize como redirect URI exatamente a `callback_url` devolvida por
   `start-google-oauth`;
4. informe `customer_id`, `login_customer_id` (se MCC), `developer_token`,
   `client_id`, `client_secret` e `conversion_action_id`;
5. abra a `authorization_url` devolvida por `start-google-oauth`.

O teste confirma que `conversion_action_id` existe na conta operacional e e do
tipo `UPLOAD_CLICKS`. O fluxo solicita `adwords` e `datamanager`, guarda refresh
token cifrado e renova access tokens automaticamente. A versao padrao da Google
Ads API e `v25`. Relatorios sao lidos no nivel de campanha, incluindo
Performance Max.

O Data Manager devolve um `requestId`; o job fica `submitted`, nunca
"confirmado" apenas pelo HTTP de aceite. O worker inicia o diagnostico apos 30
minutos, aplica backoff de 1,3x ate 60 minutos e reconcilia por no maximo 24
horas. O resultado final e `sent`, `partial` ou `failed`, com recibo e motivos
preservados. Cada snapshot bem-sucedido tambem remove linhas antigas da mesma
janela que deixaram de existir no provedor, sem apagar o ultimo snapshot quando
uma sincronizacao falha.

## Contrato do `marketing-api`

POST JSON com header `x-app-session`, salvo `capture-touchpoint`:

- `get-dashboard`: `{action,store_id,start_date?,end_date?}`
- `list-connections`: `{action,store_id}`
- `save-connection`: `{action,store_id,provider,...}`; aceita segredos no topo
  ou em `credentials`
- `test-connection`: salva primeiro quando ainda nao houver `connection_id`
- `disconnect-connection`: aceita `connection_id` ou `store_id+provider`
- `sync-now`: `provider` pode ser `meta`, `google`, `all` ou omitido
- `get-tracker-config`, `rotate-tracker-token`
- `list-sync-runs`, `list-journey`
- `record-event`: vincula jornada e registra etapa comercial
- `start-google-oauth`

Sucesso: `{ok:true,data,correlation_id}`. Erro:
`{ok:false,error:{code,message,retryable,details?},correlation_id}`.

## Tracker e consentimento

`capture-touchpoint` e publico e exige uma fonte com dominio autorizado:

```json
{
  "action": "capture-touchpoint",
  "tracking_token": "TOKEN_COPIADO_NA_ROTACAO",
  "payload": {
    "event_name": "page_view",
    "occurred_at": "2026-08-06T12:00:00Z",
    "idempotency_key": "UUID-DO-EVENTO",
    "anonymous_id": "ID-PERSISTENTE-COM-CONSENTIMENTO",
    "session_id": "ID-DA-SESSAO",
    "landing_page_url": "https://site/pagina?utm_source=google",
    "referrer_url": "https://google.com/",
    "utm_source": "google",
    "gclid": "...",
    "marketing_consent": true,
    "consent_at": "2026-08-06T12:00:00Z",
    "consent_version": "v1",
    "consent_source": "banner_site"
  }
}
```

Nunca presuma consentimento. Sem `marketing_consent=true`, o backend salva
somente um evento agregado e descarta IDs, URLs, UTMs, IP/UA e identificadores
anonymous/session. `page_url` e `referrer` sao aliases temporarios aceitos.

Depois de criar o lead, vincule os touchpoints:

```json
{
  "action": "record-event",
  "store_id": "UUID-DA-LOJA",
  "lead_id": "UUID-DO-LEAD",
  "event_type": "lead_created",
  "payload": {
    "anonymous_id": "O-MESMO-ID-DO-TRACKER",
    "idempotency_key": "lead-link:UUID-DO-LEAD"
  }
}
```

Ao registrar `bought='Sim'`, o trigger cria `purchased` e enfileira uma
conversao por conector ativo. Nao chame a Edge antiga
`marketing-conversions` pelo navegador; o `marketing-worker` assume tudo.

## Retencao e isolamento

- touchpoints, eventos, metricas e filas finalizadas: 730 dias;
- logs operacionais: 365 dias;
- OAuth state: uso unico, expira em 10 minutos;
- todas as consultas exigem escopo da loja; lojas nunca sao agregadas juntas;
- PII so e enviada aos provedores com consentimento registrado e e normalizada
  + SHA-256 antes do envio.
