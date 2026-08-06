# Ativação da inteligência de marketing

> **Documento legado.** Use este arquivo apenas para instalar as tabelas de
> qualificação, responsável e metas que o formulário atual ainda consome. Não
> cadastre conexões em `marketing_connections`, não grave tokens em
> `secret_config` e não publique `marketing-conversions`. A integração segura e
> atual está documentada em `MARKETING_ATTRIBUTION_SETUP.md`.

## 1. Banco de dados

Execute `marketing_intelligence_update.sql` no SQL Editor do Supabase depois das migrations já existentes. A migration é aditiva: preserva leads, categorias, opções e acessos atuais.

Ela adiciona:

- etapas, qualificação, perdas, responsável, UTMs e consentimento por lead;
- histórico de eventos do funil;
- investimento diário e metas por cliente;
- fila segura de conversões offline;
- configurações de Meta e Google isoladas por loja;
- proteção da chave de IA, que deixa de ser retornada ao navegador;
- limite e auditoria de uso da IA.

## 2. Funções do Supabase

Faça o deploy das funções:

```bash
supabase functions deploy ai-analysis
supabase functions deploy marketing-conversions
```

As funções usam automaticamente `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` do ambiente do Supabase. A `service role` nunca deve ser colocada no `app.js`.

## 3. Meta Conversions API

Crie uma linha em `marketing_connections` para a loja com `provider = 'meta'` e `status = 'active'`.

- `public_config`: identificadores e rótulos que podem ser exibidos no painel;
- `secret_config`: `access_token`, `pixel_id`, `api_version` e, opcionalmente, `test_event_code`.

O envio usa `event_id`, compra em loja física, valor, moeda e identificadores normalizados/hash SHA-256. Eventos são colocados em `marketing_conversion_queue` quando uma compra é registrada.

## 4. Google Data Manager API

Autorize OAuth com o escopo `https://www.googleapis.com/auth/datamanager` e crie a conexão com `provider = 'google'` e `status = 'active'`.

- `public_config`: `operating_account_id`, `login_account_id` e `conversion_action_id`;
- `secret_config`: `access_token` atualizado pelo fluxo OAuth.

O envio usa `events:ingest`, origem `IN_STORE`, ID da transação, valor, moeda, consentimento, GCLID/GBRAID/WBRAID e telefone/e-mail normalizados com SHA-256.

## 5. Operação

- A agência lança investimento manualmente no painel enquanto as importações automáticas não estiverem conectadas.
- CPL, CAC e ROAS aparecem somente quando existe investimento no mesmo cliente/período.
- O chat da IA recebe apenas resumos, rankings e séries agregadas. Nome, telefone, observações e OS não são enviados.
- A função `marketing-conversions` processa até 50 eventos pendentes por chamada e aplica tentativas progressivas quando um provedor falha.
