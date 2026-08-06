# Módulo WhatsApp Business Cloud API oficial

Implementação completa do módulo oficial do WhatsApp. O módulo usa a sessão própria do Lead Control (`x-app-session`), preserva o isolamento Admin → Agência → Cliente e suporta várias conexões por loja. Conversas, contatos, templates, campanhas, webhooks, fila e logs são domínios separados; nenhum token fica disponível ao navegador.

## Arquivos

- `whatsapp_module.sql`: tabelas, índices, RLS, criptografia de credenciais, fila e RPCs.
- `whatsapp.js` e `whatsapp.css`: interface do módulo, switch, wizard, conversas, contatos, campanhas, templates e observabilidade.
- `supabase/functions/whatsapp-api`: configuração, wizard, mensagens, mídia, templates, contatos e campanhas.
- `supabase/functions/whatsapp-webhook`: desafio da Meta, assinatura HMAC e ingestão idempotente.
- `supabase/functions/whatsapp-worker`: fila concorrente, velocidade, retries e backoff.
- `supabase/functions/_shared/whatsapp`: cliente Graph API, banco, erros, criptografia e parser de webhook compartilhados.

O arquivo `supabase/config.toml` já contém as três funções com `verify_jwt = false`. Isso não as torna públicas: cada entrada possui sua própria autenticação e validação descrita abaixo.

## Instalação

1. Aplique primeiro o `database.sql` atual do projeto.
2. Execute `whatsapp_module.sql` inteiro no SQL Editor do Supabase.
3. Configure os secrets das Edge Functions:

```bash
supabase secrets set \
  WHATSAPP_CREDENTIAL_ENCRYPTION_KEY="$(openssl rand -base64 48)" \
  WHATSAPP_WORKER_SECRET="$(openssl rand -base64 48)" \
  WHATSAPP_ALLOWED_ORIGINS="https://seu-dominio.com"
```

Secrets opcionais:

```bash
supabase secrets set \
  WHATSAPP_PUBLIC_WEBHOOK_URL="https://SEU-PROJETO.supabase.co/functions/v1/whatsapp-webhook" \
  WHATSAPP_WORKER_BATCH_SIZE="25" \
  WHATSAPP_WORKER_MAX_WAIT_MS="12000"
```

`WHATSAPP_CREDENTIAL_ENCRYPTION_KEY` deve permanecer estável. Trocá-la sem recifrar as credenciais torna os registros existentes ilegíveis. Tokens e App Secrets nunca devem ser colocados no JavaScript do navegador.

4. Confirme que o `supabase/config.toml` contém:

```toml
[functions.whatsapp-api]
verify_jwt = false

[functions.whatsapp-webhook]
verify_jwt = false

[functions.whatsapp-worker]
verify_jwt = false
```

A autenticação não fica aberta: `whatsapp-api` exige `x-app-session`, o webhook valida desafio e assinatura Meta, e o worker exige `x-worker-secret`.

5. Faça o deploy:

```bash
supabase functions deploy whatsapp-api
supabase functions deploy whatsapp-webhook
supabase functions deploy whatsapp-worker
```

6. Configure na Meta a URL pública:

```text
https://SEU-PROJETO.supabase.co/functions/v1/whatsapp-webhook
```

O Verify Token é definido individualmente no wizard. O backend localiza a conexão pelo hash do token, sem expor seu valor.

7. Invoque `whatsapp-worker` regularmente por um scheduler seguro, idealmente a cada 10–15 segundos. Envie o header `x-worker-secret` com o mesmo secret configurado na função. Para campanhas volumosas, use workers concorrentes; `FOR UPDATE SKIP LOCKED`, leases e reservas atômicas de throughput impedem processamento duplicado. Cada execução reivindica apenas o horizonte curto que consegue processar, portanto não mantém uma Edge Function dormindo por longos períodos.

## Contrato da Edge Function `whatsapp-api`

Todas as chamadas usam `POST`, `Content-Type: application/json` e `x-app-session`. Formato de retorno:

```json
{
  "ok": true,
  "data": {},
  "correlation_id": "uuid"
}
```

Em falhas:

```json
{
  "ok": false,
  "error": {
    "code": "meta_api_error",
    "message": "Descrição segura e detalhada",
    "retryable": false
  },
  "correlation_id": "uuid"
}
```

Actions disponíveis:

| Action | Uso principal |
| --- | --- |
| `bootstrap` | Identidade, permissões, conexões e contadores da loja |
| `save-connection` | Grava campos públicos e cifra os três segredos |
| `update-token` | Valida o token candidato em memória e só então faz a rotação atômica |
| `validate` / `test` | Valida credenciais candidatas sem sobrescrever a conexão operacional |
| `register-webhook` | Revalida os dados persistidos, registra callback do App e inscrição do WABA |
| `test-send` | Enfileira um template de teste para um contato com consentimento válido e preserva o rastreamento |
| `reconnect` / `disconnect` | Gerencia o estado operacional |
| `send-message` | Coloca mensagem comum ou template na fila |
| `sync-templates` | Sincroniza todos os templates com paginação Meta |
| `create-template` | Cria ou edita template; aceite `template_id` ou `provider_template_id` para editar |
| `upload-media` | Upload oficial multipart, nunca base64 |
| `media-url` / `download-media` | Faz proxy autenticado do binário sem revelar a URL efêmera da Meta |
| `import-contacts` | Importação idempotente de até 5.000 contatos por lote |
| `create-campaign` | Cria/edita campanha e resolve a audiência no servidor |
| `action-campaign` | `start`, `pause`, `resume` ou `cancel` |
| `campaign-report` | Resumo e destinatários paginados |
| `reprocess-webhook` | Reexecuta um evento preservado no histórico |

### Upload de mídia

Envie `multipart/form-data` com `action=upload-media`, `connection_id` e `file`. Limites aplicados:

- imagem: 5 MB;
- áudio: 16 MB;
- vídeo: 16 MB;
- documento: 100 MB.

O limite de requisição do plano/provedor da Edge Function também se aplica. Em ambientes cujo gateway aceite menos de 100 MB, documentos grandes devem seguir o ponto de extensão de Storage privado já representado por `whatsapp_attachments.storage_bucket/storage_path`.

Downloads não persistem nem retornam a URL temporária da Meta. O backend busca o arquivo com a credencial protegida, aplica CORS pela allowlist, `nosniff`, CSP sandbox e `Content-Disposition` seguro, e transmite o corpo diretamente ao usuário autorizado.

## Validação e wizard

`validate` consulta `debug_token`, confirma o App ID, os escopos `whatsapp_business_management` e `whatsapp_business_messaging`, a WABA, a propriedade do Phone Number ID, o número exibido e o status `CONNECTED`. Também coleta qualidade, throughput, limite atual de mensagens e expiração do token.

Quando uma conexão existente é editada, Phone Number ID, WABA, App ID, versão, número, Access Token e App Secret candidatos são mesclados somente em memória. Falha ou sucesso dessa candidata não degrada nem promove a conexão salva. `reconnect` valida exclusivamente a versão persistida. No registro do webhook, os dados recém-salvos são revalidados para eliminar a janela entre “validar” e “salvar”. Todas as chamadas Graph autenticadas incluem `appsecret_proof` HMAC-SHA256.

## RPCs do frontend

Todos recebem `p_session_token` como primeiro argumento e nunca retornam Access Token, App Secret ou Verify Token:

- `wa_get_bootstrap`
- `wa_list_connections`
- `wa_list_conversations`
- `wa_get_messages`
- `wa_list_contacts`
- `wa_upsert_contact`
- `wa_delete_contact`
- `wa_update_conversation`
- `wa_list_campaigns`
- `wa_upsert_campaign`
- `wa_campaign_action`
- `wa_get_campaign_report`
- `wa_list_templates`
- `wa_list_webhook_events`
- `wa_get_webhook_event`
- `wa_reprocess_webhook`
- `wa_list_logs`
- `wa_get_log`
- `wa_disconnect_connection`

As funções `wa_service_*` são revogadas de `anon` e `authenticated` e concedidas exclusivamente a `service_role`.

## Consentimento e campanhas

Contatos possuem prova estruturada de opt-in (`marketing_opt_in`, origem, data explícita, finalidade, categorias, versão do texto e evidência verificável), além de opt-out/revogação. O backend não inventa data nem prova de consentimento na criação manual ou importação. Campanhas recusam contatos sem consentimento ativo em quatro pontos:

1. ao montar a audiência;
2. ao enfileirar a campanha;
3. ao reivindicar o item da fila;
4. imediatamente antes do envio à Meta.

Uma revogação posterior cancela destinatário, mensagem e item de fila ainda não enviado. O sistema não interpreta uma mensagem recebida como autorização automática para marketing.

`create-campaign` aceita audiência explícita (`audience_mode: "selected"`, `contact_ids`) ou resolução escalável no banco (`audience_mode: "all_opted_in"` ou `resolve_audience: true`). Filtros suportados: `search`, `favorites_only`, `tag_ids`, `exclude_tag_ids` e `exclude_contact_ids`. A inserção é set-based e sempre restrita à loja, a contatos ativos, não bloqueados e com consentimento válido.

Mensagens livres só podem ser enviadas dentro da janela de atendimento de 24 horas aberta por mensagem recebida. Fora dela, somente template aprovado e com consentimento válido. O teste do wizard segue as mesmas regras, é persistido antes do envio e pode ser reconciliado pelos webhooks de status.

## Operação e observabilidade

- Cada chamada recebe `correlation_id`.
- Webhooks validam `X-Hub-Signature-256`, usam SHA-256 do corpo para idempotência e respondem rapidamente após persistir o evento.
- O processamento do webhook é assíncrono, com claim, lease de 10 minutos, retry e reprocessamento manual; o JSON original permanece auditável.
- Mensagens usam `idempotency_key` independente do ID da Meta.
- Locks abandonados retornam à fila após 10 minutos; campanhas pausadas/canceladas e consentimentos revogados são rechecados imediatamente antes do envio.
- Campanhas são materializadas em lotes de 100 destinatários e só recebem novo lote abaixo do limite de 500 itens ativos, evitando transações gigantes e crescimento descontrolado da fila.
- Slots de throughput são reservados atomicamente no banco por conexão e por destinatário, inclusive entre vários workers.
- O mesmo par conexão+destinatário respeita intervalo mínimo de seis segundos e nunca possui dois envios simultâneos; a ordem por destinatário é preservada.
- Erros transitórios (429, 5xx e códigos de limitação da Meta) usam backoff exponencial com jitter.
- O worker atualiza automaticamente conexões com token expirando em sete dias ou expirado.
- Logs não gravam tokens, App Secret, Verify Token ou cabeçalho Authorization.
- O histórico de status é append-only para conexões, conversas, mensagens, campanhas, destinatários, fila e webhooks.
- Mensagens de mídia recebidas persistem somente o ID do provedor e metadados; a URL efêmera nunca entra no banco.
- Se a Meta aceitar o POST e a confirmação local falhar, o item entra em `sent_unconfirmed` após tentativas curtas de gravação; ele não é reenviado automaticamente e o webhook faz a reconciliação.
- Um envelope de webhook com vários números é particionado por WABA e `phone_number_id` antes da persistência. Nenhum subpayload de outro número segue para o tenant processado.
- Listagens de webhooks e logs retornam apenas metadados leves; o JSON completo é carregado sob demanda, com nova verificação de escopo.

## Verificação local

```bash
deno check \
  supabase/functions/whatsapp-api/index.ts \
  supabase/functions/whatsapp-webhook/index.ts \
  supabase/functions/whatsapp-worker/index.ts

deno test --allow-env supabase/functions/_shared/whatsapp/*_test.ts
```

O SQL termina com `notify pgrst, 'reload schema'` e inclui uma consulta de verificação rápida ao final.

## Checklist obrigatório antes de produção

- concluir a verificação da empresa, revisão do App e permissões necessárias no painel da Meta;
- definir `WHATSAPP_ALLOWED_ORIGINS` somente com os domínios reais do sistema; a função recusa origem web não autorizada;
- manter `WHATSAPP_CREDENTIAL_ENCRYPTION_KEY` e `WHATSAPP_WORKER_SECRET` em cofre de secrets, com política de rotação e acesso restrito;
- agendar o worker com monitoramento de falha, profundidade da fila, idade do item mais antigo, erros Meta e tokens próximos do vencimento;
- configurar backup, retenção, restauração testada e política de descarte compatível com os contratos do SaaS;
- atualizar Termos de Uso, Política de Privacidade e, quando aplicável, DPA para identificar Meta/WhatsApp e Supabase como fornecedores/suboperadores, explicar finalidade, compartilhamento operacional, transferências internacionais, papéis de controlador/operador e canais de opt-out;
- publicar e guardar o texto/versionamento do consentimento usado por cada campanha; não marcar opt-in sem prova verificável;
- validar em ambiente de teste o número, template aprovado, recebimento do webhook, status de entrega e opt-out antes de liberar cada loja.

O relatório de campanhas é paginado e pode ser exportado integralmente pela interface. Para volumes de milhões de destinatários, o contrato paginado é o ponto de extensão para geração assíncrona em Storage privado, sem alterar as tabelas ou o fluxo de campanha.
