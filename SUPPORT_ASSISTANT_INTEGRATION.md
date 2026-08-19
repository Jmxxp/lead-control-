# Assistente de Suporte IA — contrato de integração

## Objetivo e escopo

O Assistente de Suporte é aberto pelo botão `?`, visível no topo de todos os módulos após a autenticação. Ele orienta as superfícies operacionais do cliente:

- navegação entre Leads, Prospecções e Atendimentos;
- cadastro, visualização, edição, filtros e exportação de Leads;
- categorias, opções e sequência dos campos de Leads;
- operação, análise e bonificações de Prospecções, quando disponíveis;
- cadastro, resumo, lista e filtros de Atendimentos, quando disponíveis;
- alternância de tema e saída da sessão.

O assistente não responde sobre contas administrativas, agências, planos, licenças, termos, backups, integrações removidas, arquitetura, código, banco de dados, APIs, credenciais ou temas externos ao sistema.

## Arquivos

- `support-assistant.js`: widget, histórico efêmero, Markdown seguro e ações allowlisted.
- `support-assistant.css`: apresentação desktop/mobile e estados claro/escuro.
- `supabase/functions/ai-analysis/index.ts`: rota `action: "support"`, política determinística e chamada server-side do provedor já configurado.
- `supabase/functions/ai-analysis/support_policy_test.ts`: testes do escopo, continuações, PII e formato do histórico.
- `supabase/migrations/20260818182307_support_assistant_authorization.sql`: RPC privada, wrapper restrito, reserva atômica e conclusão do uso.
- `supabase/migrations/20260818193000_redact_ai_settings_key.sql`: garantia rastreável de que a RPC acessível ao navegador não devolva a chave da IA.
- `database.sql`, etapa 9: estado consolidado para uma instalação limpa.

## Contrato HTTP

Requisição para `POST /functions/v1/ai-analysis`:

```json
{
  "action": "support",
  "store_id": "uuid-da-loja-ativa-ou-null",
  "messages": [
    { "role": "user", "content": "Como cadastrar um lead?" }
  ]
}
```

Regras:

- o header `x-app-session` leva a sessão própria da aplicação;
- somente as chaves `action`, `store_id` e `messages` são aceitas;
- são aceitas no máximo seis mensagens, apenas com `role` e `content` textuais;
- nenhum objeto de loja, lead, prospecção, atendimento, métrica ou configuração é aceito;
- o navegador nunca recebe a chave do provedor de IA.

Resposta:

```json
{
  "answer_markdown": "Abra **Leads** e preencha os campos...",
  "actions": [
    { "id": "open_leads", "label": "Abrir Leads", "icon": "fa-user-group" }
  ],
  "scope": "client_flows_only"
}
```

O frontend ignora rótulos, ícones, seletores e URLs recebidos. Somente o `id` é considerado e remapeado para um catálogo local fixo.

## Eventos de integração com `app.js`

### Contexto de sessão e capacidades

O widget dispara, de forma síncrona:

```js
window.dispatchEvent(new CustomEvent("lead-control:support-context-request", {
  detail: { provide(context) {} },
}));
```

O integrador responde chamando `event.detail.provide` uma única vez:

```js
event.detail.provide({
  supabaseUrl: SUPABASE_URL,
  anonKey: SUPABASE_ANON_KEY,
  sessionToken: currentProfile?.sessionToken || "",
  storeId: activeStoreContext?.id || currentProfile?.storeId || "",
  availableActions: ["open_leads", "open_lead_configuration"],
});
```

`availableActions` deve representar o estado visual atual, não apenas a licença geral. Uma ação indisponível é ocultada do chat.

### Navegação

Ao pressionar uma ação, o widget dispara:

```js
const event = new CustomEvent("lead-control:support-navigate", {
  cancelable: true,
  detail: { actionId: "open_leads", source: "support-assistant" },
});
window.dispatchEvent(event);
```

O integrador deve validar novamente o ID, chamar `event.preventDefault()` imediatamente quando assumir a navegação e então usar o fluxo normal da aplicação, inclusive a proteção de alterações não salvas. Sem um listener, existe fallback somente para IDs e elementos fixos conhecidos.

IDs aceitos:

| ID | Destino |
| --- | --- |
| `open_leads` | módulo Leads |
| `open_prospections` | módulo Prospecções |
| `open_attendances` | módulo Atendimentos |
| `open_lead_configuration` | Leads e editor de categorias |

Após alterar sessão, cliente ativo ou permissão, o integrador pode chamar:

```js
window.SupportAssistant?.refreshCapabilities?.();
```

## Controles de segurança

- a sessão é revalidada por `app_private.session_user` no banco;
- a RPC que retorna a chave da IA tem `EXECUTE` revogado de `PUBLIC`, `anon` e `authenticated`, com acesso apenas para `service_role`;
- quando existe uma loja aberta, o frontend envia somente seu `store_id` e o runtime revalida o vínculo antes de calcular capacidades; a licença de outra loja nunca libera uma resposta ou ação no contexto atual;
- o rate limit usa `ai_usage` por usuário e janela de uma hora, com índice parcial dedicado;
- contagem e reserva são atômicas sob advisory lock por usuário; chamadas paralelas não excedem 40/h e uma falha posterior continua consumindo a reserva;
- a Edge conclui a linha reservada pelo `usage_id` via RPC exclusiva de `service_role`, sem criar uma segunda cobrança;
- pedidos proibidos ou fora de escopo são bloqueados antes da chamada ao provedor;
- um tópico sem capacidade ativa também é recusado deterministicamente antes da chamada ao provedor;
- continuações curtas recebem somente um tópico operacional derivado no servidor; o histórico bruto não é enviado ao modelo;
- e-mail, CPF, CNPJ, telefone e UUID detectáveis bloqueiam a pergunta; a UI também orienta a não inserir dados pessoais;
- o modelo recebe apenas manual estático, capacidades booleanas, IDs allowlisted e a pergunta aprovada;
- a resposta passa por validação de escopo e tamanho antes de voltar ao navegador;
- o Markdown é construído com nós DOM e `textContent`; HTML, links e comandos não são executados;
- o histórico é somente em memória e é apagado, inclusive visualmente, ao sair ou trocar de sessão.

## Implantação

Estado verificado em 18 de agosto de 2026: as migrations foram aplicadas, `ai-analysis` versão 2 foi implantada e o endpoint respondeu corretamente a CORS e sessões ausente/inválida. Para novas implantações, preserve esta ordem:

1. revisar e aplicar `20260818182307_support_assistant_authorization.sql`;
2. aplicar `20260818193000_redact_ai_settings_key.sql`;
3. implantar a Edge Function `ai-analysis`;
4. publicar `index.html`, `support-assistant.js` e `support-assistant.css`;
5. testar uma sessão de cliente com e sem Prospecções e uma sessão administrativa dentro e fora de um cliente.

`supabase/config.toml` mantém `verify_jwt = false` para `ai-analysis` porque a aplicação usa sessão própria. A função continua exigindo `x-app-session` e valida essa sessão no banco antes de qualquer acesso à configuração de IA.
