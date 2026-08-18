# Controle de Leads — documentação completa do projeto

> Retrato técnico e funcional verificado em **18 de agosto de 2026**.
>
> Este documento descreve o estado consolidado do código e do projeto Supabase `menlvmsgkhgqxiydphbn`. Em 18 de agosto de 2026, a retirada de anúncios/atribuição, as três migrations desta entrega e a Edge Function `ai-analysis` versão 2 foram aplicadas e verificadas no remoto. O frontend continua tendo ciclo independente pelo GitHub Pages.

## 1. Resumo executivo

O Controle de Leads é um SaaS B2B para óticas. Ele possui uma interface web única, três módulos operacionais e três níveis de conta:

- **Admin:** proprietário global do ambiente e de todos os dados do tenant.
- **Agência:** perfil gravado no banco como `technician`; administra a própria carteira de clientes.
- **Cliente/loja:** opera somente os dados da sua loja.

Os módulos atuais são:

1. **Leads:** cadastro, acompanhamento, agenda, funil, inteligência comercial nativa, relatórios e exportações.
2. **Prospecções:** carteira de prospecção, profissionais, metas, bonificação, resultados e análises.
3. **Atendimentos:** registro de atendimentos feitos na loja, vínculo automático por telefone e atualização controlada de resultados.

O módulo **Leads** está disponível para todas as lojas. **Prospecções e Atendimentos formam uma única licença adicional**: `stores.prospection_enabled`. Atendimentos não possui uma licença separada.

Não existe ferramenta, conector, rastreador ou estrutura de dados para WhatsApp, Meta Ads ou Google Ads. Foram retirados frontend, tabelas, campos de atribuição, credenciais, filas, workers, webhooks, Edge Functions e agendamentos dessas integrações. `channel` e `campaign` continuam sendo campos comerciais comuns, preenchidos pela loja; valores históricos que mencionem uma plataforma são apenas texto, não conexão ou rastreamento externo. O provedor Google Gemini continua disponível exclusivamente para IA e não tem relação com Google Ads.

Admin e Agência acessam uma **Central de análise única**. Depois de selecionar uma loja, um switch alterna entre Leads, Prospecções e Atendimentos sem trocar a loja nem combinar bases. As duas últimas abas respeitam a licença conjunta `prospection_enabled`.

Todos os perfis autenticados possuem um **Assistente de Suporte IA** no botão `?`. Ele ensina exclusivamente os fluxos operacionais que um cliente usa, sem receber registros comerciais ou liberar áreas administrativas. Seus atalhos são limitados por uma lista fixa e pelo contexto visual/licença atual; a conversa existe somente em memória e desaparece ao recarregar ou encerrar a sessão.

## 2. Arquitetura geral

O frontend é uma aplicação estática em HTML, CSS e JavaScript puro. Não há framework, bundler, `package.json` ou etapa de compilação. A persistência e as regras críticas ficam no Supabase/PostgreSQL; integrações sensíveis ficam em Edge Functions.

```mermaid
flowchart LR
    U[Usuário no navegador] --> UI[Frontend estático<br/>HTML + CSS + JavaScript]
    UI -->|RPC + token da aplicação| RPC[Funções PostgreSQL públicas]
    RPC --> PRIV[app_private<br/>validação de sessão e regras]
    PRIV --> DB[(PostgreSQL<br/>public + app_private)]
    UI -->|x-app-session| EDGE[Edge Function ai-analysis]
    EDGE -->|service role| RPC
    EDGE --> AI[Gemini ou DeepSeek]
    CRON[pg_cron] --> RET[Retenção de Atendimentos]
    RET --> DB
    GH[GitHub Actions] --> PAGES[GitHub Pages]
    PAGES --> UI
```

### 2.1 Tecnologias e dependências

| Camada | Tecnologia | Uso |
|---|---|---|
| Interface | HTML5 | Estrutura de todas as telas e modais. |
| Interface | CSS3 | Tema claro/escuro, componentes, módulos e responsividade. |
| Interface | JavaScript ES | Estado, renderização, validações, gráficos próprios, XLSX e chamadas ao backend. |
| Ícones | Font Awesome 6.5.2 via CDN | Ícones visuais da interface. |
| Cliente de dados | `@supabase/supabase-js@2` via CDN | Chamadas RPC ao Supabase. |
| Banco | Supabase PostgreSQL | Dados, permissões, regras, auditoria e retenção. |
| Funções | Supabase Edge Functions/Deno | Proxy autenticado da IA: streaming para análise e resposta JSON para suporte. |
| Criptografia SQL | `pgcrypto` | Senhas, tokens, hashes e evidências. |
| Agendamento | `pg_cron` | Retenção diária de Atendimentos. |
| Hospedagem web | GitHub Pages | Publicação do site estático. |
| PWA | Web App Manifest | Instalação em tela inicial e identidade visual. |
| Persistência local | `localStorage` e IndexedDB | Sessão, tema, módulo, chats da IA analítica e autorizações de backup; o chat de suporte não é persistido. |
| IA externa | Gemini ou DeepSeek | Análises comerciais agregadas e orientações de suporte dentro de política restrita. |

### 2.2 Características importantes

- É uma **SPA sem roteador por URL**: as telas são seções alternadas por JavaScript.
- Admin e Agência usam uma única Central de análise; o estado compartilhado mantém uma loja por vez e o switch apenas troca o tipo de leitura.
- O switch operacional do topo só aparece dentro do contexto de uma loja: sempre para o perfil Loja e, para Admin/Agência, somente depois de entrar em um cliente. Ele fica oculto nos painéis gerais de contas.
- O último módulo Prospecções/Atendimentos é restaurado automaticamente somente para o perfil Loja. Admin e Agência iniciam no painel geral de Leads e usam o botão **Entrar** de um cliente antes de trocar o módulo.
- O Supabase Auth **não é usado para login do produto**. Existe autenticação própria em `app_users` e `app_sessions`.
- A chave `anon` do Supabase está no navegador, como esperado para cliente público. A segurança depende de RLS, revogação de acesso direto e validação de sessão dentro das RPCs.
- Não há Service Worker. O app é instalável pelo manifesto, mas **não tem cache offline completo**.
- O fuso operacional padrão é `America/Sao_Paulo`; datas visuais usam `pt-BR`.

## 3. Hierarquia de contas, dados e licenças

```mermaid
flowchart TD
    ADMIN[Admin global<br/>1 por tenant] --> A1[Agência A<br/>role = technician]
    ADMIN --> A2[Agência B<br/>role = technician]
    ADMIN --> SD[Loja sem agência]
    A1 --> L1[Loja 1]
    A1 --> L2[Loja 2]
    A2 --> L3[Loja 3]
    L1 --> BASE[Leads<br/>sempre disponível]
    L1 -->|se prospection_enabled = true| EXTRA[Prospecções + Atendimentos]
```

### 3.1 Regras de propriedade

- `admin_user_id` identifica o tenant e aparece em praticamente todas as tabelas de negócio.
- `store_id` impede a mistura de informações entre clientes.
- `stores.technician_user_id` vincula uma loja à agência responsável.
- Uma conta `store` também aponta para a loja em `app_users.store_id`.
- O Admin pode acessar qualquer loja do próprio tenant.
- A Agência pode acessar somente lojas em que `technician_user_id` é o seu usuário.
- A Loja pode acessar somente `app_users.store_id`.
- Análises e IA analítica trabalham com **uma loja selecionada por vez**; dados de lojas diferentes não são combinados. O Assistente de Suporte é separado e não recebe dados comerciais da loja.

### 3.2 Limites de plano

| Campo | Significado |
|---|---|
| `app_users.store_limit` | Quantidade máxima de clientes que uma agência pode cadastrar. |
| `app_users.prospection_store_limit` | Quantidade máxima de clientes da agência que podem ter Prospecções + Atendimentos. |
| `stores.prospection_enabled` | Liga ou desliga o pacote Prospecções + Atendimentos para a loja. |

Ao reduzir um limite abaixo do uso atual, o sistema preserva as lojas que já estavam ativas. Novas ativações ficam bloqueadas até a agência voltar ao limite; a escolha de quais clientes desativar é administrativa e não automática.

### 3.3 Matriz de permissões

| Recurso | Admin | Agência | Loja |
|---|:---:|:---:|:---:|
| Entrar e alterar tema | Sim | Sim | Sim |
| Ver todos os clientes do tenant | Sim | Não | Não |
| Ver clientes da própria carteira | Sim | Sim | Própria loja |
| Criar/editar/excluir agência | Sim | Não | Não |
| Criar/editar/excluir loja | Sim | Própria carteira | Não |
| Definir limites e licenças | Sim | Não | Não |
| Operar Leads | Sim | Sim | Sim |
| Editar categorias da loja | Sim | Sim | Sim, própria loja |
| Operar Prospecções | Sim | Sim | Sim, se licenciada |
| Operar Atendimentos | Sim | Sim | Sim, se licenciada |
| Ver análises | Sim | Sim, própria carteira | Própria loja |
| Exportar dados | Sim | Sim, própria carteira | Própria loja |
| Configurar backup em HD | Sim | Sim | Não |
| Configurar IA central | Sim | Não | Não |
| Usar IA de análise | Sim | Sim | Não |
| Usar Assistente de Suporte | Sim | Sim | Sim |
| Administrar termos legais | Sim | Não | Não |
| Acessar a central de termos assinados | Sim | Não | Não |
| Assinar termos obrigatórios | Sim | Sim | Sim |

O uso do Assistente de Suporte exige uma configuração central de IA ativa, mas não concede ao perfil acesso à chave nem a qualquer tela administrativa.

## 4. Hierarquia de arquivos

```text
lead-control-/
├── index.html                         # Estrutura da SPA e todos os mounts/modais
├── app.js                             # Núcleo: sessão, Leads, contas, análises, IA, backup
├── styles.css                         # Design system e telas do núcleo
├── mobile.css                         # Responsividade compartilhada
├── prospections.js / prospections.css # Módulo de Prospecções
├── prospec-original.css               # Camada visual original ativada só na operação
├── attendances.js / attendances.css   # Módulo de Atendimentos
├── support-assistant.js / .css        # Assistente de Suporte, UI segura e responsiva
├── SUPPORT_ASSISTANT_INTEGRATION.md   # Contrato técnico da integração do suporte
├── manifest.webmanifest               # Manifesto instalável/PWA
├── favicon.ico e logo__.png           # Identidade na raiz
├── assets/                            # Ícones, logo e preview social
│   ├── logo-source.png
│   ├── link-preview.png
│   ├── app-icon-192.png
│   ├── app-icon-512.png
│   ├── maskable-icon-512.png
│   ├── apple-touch-icon.png
│   ├── favicon-16.png
│   ├── favicon-32.png
│   └── site-icon.png
├── database.sql                       # Base consolidada + histórico incremental
├── attendance_module.sql              # Schema e RPCs de Atendimentos
├── lead_intelligence_update.sql       # Inteligência comercial nativa, sem atribuição externa
├── *_update.sql                       # Migrações incrementais históricas
├── *_qa.sql                           # QA SQL transacional
├── remove_whatsapp_module.sql         # Retirada destrutiva do módulo descontinuado
├── supabase/
│   ├── config.toml                    # Configuração local das Edge Functions
│   ├── migrations/
│   │   ├── 20260818171504_remove_marketing_attribution.sql
│   │   ├── 20260818182307_support_assistant_authorization.sql
│   │   ├── 20260818190526_attendance_list_v2_filters.sql
│   │   └── 20260818193000_redact_ai_settings_key.sql
│   └── functions/
│       └── ai-analysis/
│           ├── index.ts                # Única Edge Function do produto
│           └── support_policy_test.ts  # Testes determinísticos da política de suporte
└── .github/workflows/pages.yml         # Deploy do frontend no GitHub Pages
```

### 4.1 Diretório local legado `prospec/`

`prospec/` é um repositório local aninhado e ignorado pelo Git principal. Ele guarda a versão original independente do sistema de prospecção e SQLs antigos, servindo apenas como referência. O produto publicado usa `prospections.js`, `prospections.css`, `prospec-original.css` e as RPCs atuais do projeto principal.

Arquivos `prospec-backup*.json` também são ignorados e podem conter dados pessoais. Não devem ser commitados.

### 4.2 Ordem de carregamento do navegador

1. `styles.css`
2. `prospections.css`
3. `attendances.css`
4. `prospec-original.css` inicialmente desabilitado
5. `mobile.css`
6. `support-assistant.css`
7. Font Awesome
8. Supabase JS v2
9. `app.js`
10. `prospections.js`
11. `attendances.js`
12. `support-assistant.js`

Os módulos expõem pontes globais:

- `window.ProspectionsModule`
- `window.AttendancesModule`
- `window.SupportAssistant`

`app.js` fornece a sessão, lojas, dados e navegação; cada módulo monta sua própria interface no contêiner correspondente. O script do suporte é carregado por último para consumir os elementos e as pontes já registrados, sem depender de bundler.

## 5. Mapa de telas e interface

```text
Aplicação
├── Login
│   ├── Nick
│   ├── Senha
│   └── Aceite legal obrigatório, quando pendente
├── Barra superior
│   ├── Identidade, avatar e perfil
│   ├── Seletor: Leads | Prospecções | Atendimentos, somente dentro de um cliente
│   ├── Data
│   ├── Alertas de agendamento
│   ├── Assistente de Suporte (`?`)
│   ├── Administração/configurações, conforme perfil
│   ├── Tema
│   └── Sair
├── Área Admin/Agência
│   ├── Clientes
│   ├── Agências, somente Admin
│   ├── Central de análise: Leads | Prospecções | Atendimentos
│   ├── Backups
│   ├── Central jurídica, somente Admin
│   └── Configuração de IA, somente Admin
├── Área da loja — Leads
│   ├── Resumo e indicadores
│   ├── Monitor de agendamentos atrasados
│   ├── Formulário de lead
│   ├── Pesquisa e filtros
│   ├── Lista/cartões de leads
│   ├── Categorias e opções
│   └── Exportação
├── Prospecções
│   ├── Operação
│   ├── Atendimentos para prospectar
│   ├── Gestão
│   ├── Análise
│   ├── Bonificação
│   ├── Configurações
│   └── Importação/exportação
├── Atendimentos
│   ├── Formulário
│   ├── Indicadores
│   ├── Filtros
│   └── Histórico
├── Assistente de Suporte
│   ├── Perguntas rápidas
│   ├── Respostas em Markdown seguro
│   └── Atalhos permitidos para fluxos do cliente
└── Modais
    ├── Detalhe/edição de lead
    ├── Conta, loja e agência
    ├── Confirmação e alterações não salvas
    ├── Agendamento
    ├── Inspetor de analytics
    ├── Chat, histórico e configuração de IA
    ├── Aceite de termos
    └── Documento jurídico
```

### 5.1 Design system e responsividade

- Paleta base: fundo `#e8e8e8`, superfície `#ffffff`, texto `#171717`, verde `#16855f`, azul `#2563a5`, âmbar `#b46d12` e rosa `#b02f4c`.
- Identidade por módulo: Leads usa superfícies neutras mais escuras; Prospecções usa acentos e fundos azulados; Atendimentos usa acentos e fundos esverdeados. A Central de análise mantém essa identidade no switch e no painel ativo.
- Raios visuais permanecem contidos: `8px` nos componentes legados e aproximadamente `10–12px` nos cards e campos padronizados de Prospecções e Atendimentos, sem formato excessivamente arredondado.
- Fonte: pilha de sistema/Inter, sem download obrigatório de uma fonte externa.
- Tema escuro: classes `body.is-dark` e `body.is-dark-mode` atendem partes antigas e novas.
- Breakpoints compartilhados principais: `900px` e `720px`, com ajustes específicos em cada módulo.
- No celular, a intenção atual é preservar a mesma interface e todos os recursos, apenas em uma composição mais densa.
- Para Agência, a navegação superior possui somente Clientes, Análise e Backups; `has-three-sections` centraliza os três itens porque a central de termos assinados é exclusiva do Admin.
- Campos de preenchimento de Prospecções e Atendimentos usam fundo branco, texto, placeholders e ícones escuros inclusive no tema escuro; o foco mantém o acento azul ou verde do respectivo módulo e a combinação foi definida para contraste AA.
- Controles de formulário usam ao menos `16px` no mobile para evitar zoom automático do iOS.
- `safe-area-inset-*`, `min-width: 0`, quebra de texto e contenção de mídia evitam cortes e rolagem horizontal acidental.

## 6. Sessão, autenticação e termos legais

### 6.1 Fluxo de entrada

```mermaid
sequenceDiagram
    participant B as Navegador
    participant L as lc_login
    participant DB as PostgreSQL
    participant P as lc_current_profile
    B->>L: nick + senha
    L->>DB: normaliza nick e valida bcrypt
    DB-->>L: usuário/loja ativos
    L->>DB: salva SHA-256 do token com expiração de 30 dias
    L-->>B: token bruto + perfil
    B->>B: localStorage lead-control-session
    B->>P: token
    P->>DB: sessão válida + gate jurídico
    alt termos pendentes
        P-->>B: perfil mínimo e termos exigidos
        B->>DB: lc_accept_legal_terms + assinatura
    else termos válidos
        P-->>B: perfil e permissões completos
    end
```

### 6.2 Detalhes de segurança da sessão

- O nick é normalizado em minúsculas, com espaços convertidos em hífen.
- Senhas são armazenadas com bcrypt por `crypt(..., gen_salt('bf'))`.
- O token bruto aleatório é entregue somente ao navegador.
- `app_sessions.token_hash` guarda SHA-256, não o token bruto.
- A sessão expira em 30 dias e pode ser revogada no logout.
- `app_private.session_user` valida token, expiração, revogação, usuário ativo, loja ativa e atualiza `last_seen_at`.
- A sessão local fica em `localStorage` sob `lead-control-session`.
- Toda RPC de negócio revalida a sessão; esconder um botão não é considerado autorização.

### 6.3 Gate jurídico

Quando há termos ativos não aceitos, apenas o carregamento mínimo do perfil e as operações jurídicas continuam disponíveis. O restante das RPCs é bloqueado até o aceite.

O aceite registra:

- versão, título, conteúdo e hash do documento;
- conta, tenant e snapshots de agência/loja;
- nome e cargo do signatário;
- CPF em hash e somente os quatro últimos dígitos visíveis;
- assinatura em PNG/data URL e hash próprio;
- confirmações explícitas;
- IP, User-Agent, timezone e horário do cliente;
- `evidence_hash`, vinculando documento, pessoa, assinatura e contexto.

O Admin pode consultar pendências, aceites válidos/desatualizados e baixar um comprovante HTML imprimível.

## 7. Fluxos ponta a ponta

### 7.1 Criação da estrutura B2B

1. O Admin global é provisionado diretamente no banco; não existe RPC pública para criar outro Admin.
2. O Admin cria uma Agência, informando nome, nick, senha, limite de clientes e limite de licenças Prospecções.
3. Admin ou Agência cria uma loja dentro do escopo permitido.
4. A loja recebe conta de login e sempre tem Leads.
5. O Admin pode ativar `prospection_enabled`, respeitando a franquia da Agência.
6. Quando a licença é ativada, Prospecções e Atendimentos tornam-se acessíveis juntos.
7. No cartão do cliente, **Entrar** abre o contexto isolado dessa loja; é nesse momento que o switch operacional do topo fica disponível para Admin/Agência.

### 7.2 Lead até atendimento e compra

```mermaid
flowchart LR
    CAD[Cadastro do lead] --> FUNIL[Qualificação e funil]
    FUNIL --> AGENDA{Agendou?}
    AGENDA -->|Sim| MON[Monitor de agendamento]
    AGENDA -->|Não| CONT[Continuar contato]
    MON --> VIS{Compareceu?}
    VIS -->|Sim| COMP{Comprou?}
    VIS -->|Não| REAG[Reagendar ou registrar falta]
    COMP -->|Sim| VENDA[Valor + OS + evento purchased]
    COMP -->|Não| FOLLOW[Retorno/prospecção]
    AT[Atendimento registrado] --> MATCH[Normalização do telefone]
    MATCH --> LINKS[Vínculo com Lead e/ou Prospecção]
    LINKS --> SAFE{Correspondência inequívoca?}
    SAFE -->|Sim| APPLY[Servidor aplica visita/compra/bonificação]
    SAFE -->|Não| KEEP[Preserva atendimento sem resultado incerto]
```

### 7.3 Central única de análise

```mermaid
flowchart LR
    USER[Admin ou Agência] --> STORE[Seleciona uma loja permitida]
    STORE --> SWITCH{Switch da Central}
    STORE --> LICENSE{prospection_enabled?}
    SWITCH --> LEADS[Análise de Leads]
    SWITCH --> PROS[Análise de Prospecções]
    SWITCH --> ATT[Análise de Atendimentos]
    STORE --> SCOPE[store_id único e compartilhado]
    SCOPE --> LEADS
    SCOPE --> PROS
    SCOPE --> ATT
    LICENSE -->|Não| LOCK[Bloqueia Prospecções e Atendimentos]
    LICENSE -->|Sim| PROS
    LICENSE -->|Sim| ATT
```

Ao trocar a loja, o sistema invalida a renderização anterior. Os módulos embutidos desmontam eventos e DOM quando saem de foco; uma geração de requisição impede que uma resposta antiga reapareça no cliente novo.

### 7.4 Assistente de Suporte

```mermaid
sequenceDiagram
    participant U as Usuário autenticado
    participant W as support-assistant.js
    participant E as ai-analysis
    participant R as lc_support_assistant_runtime
    participant P as Provedor de IA
    U->>W: Pergunta sobre fluxo do cliente
    W->>E: action=support + loja ativa opcional + até 6 mensagens + x-app-session
    E->>R: valida sessão, perfil, capacidades e rate limit
    R-->>E: configuração e IDs de ação permitidos
    E->>E: bloqueia escopo proibido e identificadores pessoais
    E->>P: manual estático + capacidades booleanas + pergunta aprovada
    P-->>E: JSON com resposta e IDs sugeridos
    E->>E: valida texto, tamanho e allowlist
    E-->>W: answer_markdown + actions + scope
    W->>W: monta Markdown com nós DOM e revalida ações visíveis
```

O assistente não envia Lead, Prospecção, Atendimento, métrica ou configuração da loja ao provedor. O histórico bruto também não é repassado: uma continuação curta recebe somente o tópico operacional derivado de mensagens anteriores do próprio usuário. Ao acionar um atalho, `app.js` revalida contexto, licença e alterações não salvas antes de usar a navegação normal.

## 8. Módulo Leads

### 8.1 Cadastro e edição

Campos principais:

- nome e telefone;
- data do contato;
- canal, campanha, início da conversa e conclusão;
- situação do ciclo de vida: `new`, `contacted`, `qualified`, `scheduled`, `visited`, `won` ou `lost`;
- responsável e qualificação;
- agendou, data e horário;
- visitou;
- comprou, valor da compra e ordem de serviço;
- observações;
- categorias personalizadas da loja;
- inteligência: ciclo de vida, qualificação, responsável, e-mail, motivo de perda, timestamps do funil e cliente recorrente.

Regras principais:

- Agendamento “Sim” exige data; o horário é opcional.
- Visita “Sim” exige uma resposta de compra.
- Compra “Sim” exige valor maior que zero e ordem de serviço.
- O salvamento preferencial usa `lc_upsert_lead_with_intelligence`, mantendo lead, valores personalizados e inteligência na mesma operação.
- Existe fallback compatível com `lc_upsert_lead` seguido de `lc_save_lead_intelligence`.

### 8.2 Categorias e opções

Grupos padrão por loja:

- Canal: Instagram, Facebook e Ligação.
- Campanha: Orgânico, Anúncio e Indicação.
- Início da conversa: preço, consulta, armação e lente.
- Conclusão: Aguardando, Retornar e Finalizado.
- Visitou, Comprou e Agendou: opções fixas Sim/Não.

É possível renomear rótulos dos grupos, criar categorias personalizadas, adicionar/editar/excluir opções e mudar a ordem. Opções fixas de Sim/Não não podem ser adulteradas.

Não existe opção funcional ou ferramenta de WhatsApp. Valores históricos já salvos em campos textuais não são interpretados, conectados ou rastreados pelo sistema.

### 8.3 Agenda

O monitor considera pendentes os leads com:

- `scheduled = 'Sim'`;
- data anterior ao dia atual;
- `visited != 'Sim'`.

As ações permitem ligar pelo discador do aparelho, marcar comparecimento, registrar que não veio/reagendar ou abrir a edição completa.

### 8.4 Análise de Leads

Esta análise aparece na Central única, na aba Leads. O contexto é `selectedAnalyticsStoreId`, e os cálculos usam somente `getAnalyticsBaseLeads()`/`getAnalyticsLeads()` da loja escolhida. Filtros disponíveis incluem período, canal, campanha, conclusão, ciclo de vida, qualificação, visita, agendamento, compra e categorias personalizadas.

Indicadores e visualizações incluem:

- volume de leads, qualificados, agendados, visitas e vendas;
- conversões entre etapas;
- receita, ticket médio e taxa de comparecimento;
- rankings por canal/campanha/opção;
- gráficos de pizza, barras e linha;
- comparação com período anterior;
- inspetor de registros por fatia;
- qualidade e consistência dos dados.

Não há custo de mídia, atribuição, CPL, CAC, ROAS ou dados importados de plataformas de anúncio. Canal e campanha são dimensões internas dos próprios Leads.

### 8.5 Exportação

O projeto contém um gerador XLSX próprio, sem biblioteca externa. A exportação cria as planilhas **Leads** e **Resumo**. Células iniciadas por `=`, `+`, `-` ou `@` recebem proteção contra injeção de fórmula.

- Loja: exporta seus dados por período/filtro.
- Agência/Admin: escolhe cliente e escopo permitido.
- A exportação manual é `.xlsx` real.

## 9. Backups em HD

Disponível para Admin e Agência, principalmente em Chrome/Edge desktop por depender de `showDirectoryPicker` e IndexedDB.

### 9.1 Fluxo

1. Usuário escolhe uma pasta/HD e concede leitura/escrita.
2. O identificador da pasta e manifestos são guardados no IndexedDB `lead-control-backup`.
3. O sistema verifica a cada minuto.
4. Depois das 20h, com o app aberto e permissão válida, atualiza os dados remotos.
5. Por loja, calcula um fingerprint do snapshot: SHA-256 quando disponível, FNV como fallback.
6. O primeiro arquivo é completo; os seguintes carregam apenas registros novos ou alterados.

Estrutura de diretórios:

```text
Controle de Leads/
└── <Admin ou Agência>/
    └── <Loja (@login)>/
        └── <ano>/
            └── <MM - mês>/
                └── Semana NN/
                    ├── backup-completo-....xls
                    └── backup-incremental-....xls
```

Os backups automáticos `.xls` são workbooks HTML compatíveis com Excel; não são o mesmo formato da exportação manual `.xlsx`.

Limitações:

- o navegador e o sistema precisam estar abertos após 20h;
- o HD precisa estar conectado e com permissão;
- Safari, Firefox e celulares normalmente não oferecem a API necessária;
- remoções de registros não geram um “tombstone” explícito no incremental; o próximo manifesto apenas deixa de conter o ID.

## 10. Módulo Prospecções

### 10.1 Acesso

- Admin: escolhe agência/cliente e acompanha a carteira completa.
- Agência: acessa apenas clientes da própria carteira.
- Loja licenciada: opera sua própria prospecção.
- Loja sem licença: recebe tela de upgrade/leitura e pode exportar o arquivo antes de uma desativação.

### 10.2 Operação

Uma prospecção possui nome, telefone, CPF, observação, profissional, etiquetas e probabilidade:

- vermelho: Improvável;
- amarelo: Pouco provável;
- azul: Provável;
- verde: Muito provável.

A busca percorre nome, telefone, CPF e observação. Os estados principais são aberto, retornou e comprou. Ações: ligar, editar, marcar retorno, registrar/remover compra e excluir.

Uma compra registra valor e OS. O histórico mantém snapshots do profissional para que mudanças futuras de nome/arquivamento não alterem o passado.

### 10.3 Atendimentos para prospectar

O módulo consulta atendimentos por loja, tipo, período e texto. Ao selecionar um atendimento:

- se houver prospecção inequívoca, abre o cadastro existente;
- se não houver, preenche uma nova prospecção;
- se houver ambiguidade, evita escolher silenciosamente a pessoa errada.

### 10.4 Gestão, análise e bonificação

- Indicadores: total, retornos/visitas, compras, conversão, bônus e meta diária.
- Períodos rápidos: hoje, semana, mês, ano e todo o período.
- Gestão: cartões, rankings e tendências.
- A análise aberta pela própria loja e a aba Prospecções da Central usam a mesma fonte visual e funcional, `analysisExperienceMarkup(context)`. Isso mantém identidade da loja, resumo de Hoje/Semana/Mês/Ano, períodos rápidos, comparação de resultados, desempenho por profissional e campanha/etiqueta, gráfico de evolução, calendário e refinamento por datas e responsável.
- A taxa de conversão usa uma única **coorte**: Prospecções criadas no período formam o denominador, e retorno/compra são contados somente nesses mesmos registros. As séries de evolução continuam exibindo eventos pela data em que ocorreram, mas não são usadas como denominador da conversão; isso impede percentuais acima de 100% por mistura de períodos.
- Em cada responsável, **Listar** abre o mesmo detalhamento na análise da loja e na Central. São sete controles combináveis: busca; período; responsável; etiqueta; status/probabilidade; retorno; compra. A busca cobre nome, telefone, CPF, OS, anotação, responsável e etiquetas. A lista ordena os mais recentes e exibe até 200 resultados, informando quando houver mais.
- A listagem operacional principal continua com busca, período e situação; os filtros ampliados pertencem ao detalhamento acionado por **Listar**.
- Bônus: agrupa atividade, retorno, compras, receita e prêmio por profissional, com rastreabilidade pela OS.

Configuração inicial:

- meta diária: `15`;
- compra mínima para bônus: `300`;
- valor do bônus: `20`;
- cor de destaque: `#16855f`;
- fundo do logo: branco.

A configuração completa é salva atomicamente e possui controle de revisão para impedir que duas telas sobrescrevam alterações concorrentes. Profissionais podem ser inativados ou arquivados; o histórico permanece.

Para integrações internas aprovadas, o módulo expõe `window.ProspectionsModule.openClientConfiguration(storeId?)`. A API é estreita: só abre o fluxo existente de configuração quando módulo, perfil, loja e licença são válidos; ela não aceita ação ou seletor arbitrário. O catálogo atual do Assistente de Suporte não aciona essa API.

### 10.5 Importação e retenção

- Importa backup JSON de até 10 MB.
- Primeiro executa somente validação/preview.
- Exige confirmação explícita da loja de destino.
- Usa hash do payload e lote idempotente para impedir duplicação em replay.
- Importa prospecções, resultados, profissionais, etiquetas e configurações sem trocar identidade, login, logo, permissões ou dados já existentes da loja.
- Os registros operacionais têm retenção móvel de dois anos; listagem, exportação e gatilhos aplicam a janela mesmo sem cron dedicado.

## 11. Módulo Atendimentos

### 11.1 Formulário

Obrigatórios:

- profissional cadastrado;
- nome do cliente;
- telefone brasileiro com DDD;
- descrição;
- tipo: orçamento, compra ou outro.

O valor de atendimento é opcional. Em uma compra, valor da compra e OS são obrigatórios.

### 11.2 Vínculo automático e segurança

O servidor normaliza o telefone e procura, dentro da mesma loja, Leads e Prospecções correspondentes. Ele pode vincular os dois cadastros.

- Correspondência única: pode aplicar visita, compra e crédito de bônus.
- Mais de uma correspondência: preserva o atendimento, registra candidatos/ambiguidade e não altera resultados financeiros incertos.
- Sem correspondência: o atendimento continua válido e independente.

O servidor, não o frontend, decide elegibilidade, valor e profissional creditado. Os valores de configuração e os nomes são salvos como snapshots.

`idempotency_key` e `request_fingerprint` impedem que duplo clique, retry ou reconexão criem o mesmo atendimento duas vezes.

### 11.3 Painel

Filtros operacionais: busca por nome, telefone, descrição ou OS; tipo; profissional; vínculo; e período (hoje, 7 dias, 30 dias ou todo o período). Cada item do painel de filtros possui ícone próprio. Vínculo distingue Lead/Prospecção, atendimento avulso e registro que precisa de revisão.

A lista operacional consulta `lc_list_attendances_v2` em páginas de 30, com busca atrasada em 260 ms para evitar uma chamada por tecla. Tipo, profissional, período e vínculo são combinados no servidor antes do total e da paginação. `matched` representa vínculo com Lead ou Prospecção, `standalone` representa atendimento sem vínculo e sem ambiguidade, e `review` representa correspondência ambígua. Profissionais atuais são filtrados por UUID; nomes preservados apenas em registros históricos usam o snapshot exato. Há estados de carregamento, erro/tentativa novamente, “Carregar mais 30” e conclusão, com deduplicação por ID. Enquanto a primeira página completa carrega, o snapshot recente do workspace pode ser mostrado como transição.

Os cards exibem cliente, telefone, tipo, descrição, profissional, data, OS, origem em Lead/Prospecção, crédito/bonificação, valores e ações de ligar/copiar. Os indicadores cobrem total, orçamentos, compras, conversão, faturamento informado e valores de atendimento.

Na Central única, a aba Atendimentos exige `p_store_id`, valida a loja no payload e pagina `lc_list_attendances_v2` de 200 em 200 até o limite protegido de 2.000 registros. O painel oferece períodos Hoje/7 dias/30 dias/Todo o período, KPIs, funil por tipo, financeiro, top 6 profissionais, qualidade de vínculos/clientes únicos e busca com filtros de tipo, profissional e vínculo. O detalhamento visual mostra os 20 registros mais recentes do recorte; quando a base excede 2.000, a tela identifica explicitamente que os cálculos usam uma amostra protegida.

Toda a superfície usa paleta verde própria — floresta, esmeralda, menta, lima e sálvia — em tema claro e escuro. Inputs permanecem brancos com texto/ícones escuros, e os cards novos usam raios contidos de aproximadamente 10–12 px.

Retenção: dois anos. O cron remoto `lc_attendance_retention_daily` executa diariamente às **03:17**; o upsert também possui fallback de limpeza.

## 12. Central única de análise

### 12.1 Estrutura e navegação

A Central é uma seção única da área administrativa (`companyWorkspaceSection = "analytics"`). Ela possui:

1. seletor de cliente, restrito à carteira do perfil;
2. um único `storeId` compartilhado;
3. switch acessível `Leads | Prospecções | Atendimentos`;
4. um painel visível por vez;
5. mensagem de seleção vazia, loading, erro recuperável e bloqueio de licença.

Leads é sempre permitido. Prospecções e Atendimentos ficam desabilitados quando a loja não tem `prospection_enabled`. Trocar a aba não muda o cliente selecionado.

### 12.2 Contratos dos painéis

| Aba | Fonte e contrato | Conteúdo principal |
|---|---|---|
| Leads | Estado e cálculos do `app.js`: `selectedAnalyticsStoreId`, `renderAdminAnalytics`, `getAnalyticsBaseLeads` e `getAnalyticsLeads` | Funil, períodos, categorias internas, comparações, registros, exportação e IA agregada. |
| Prospecções | `window.ProspectionsModule.renderEmbeddedAnalysis({ root, bridge, storeId })`; lê `lc_list_prospections` e `lc_get_prospection_configuration`; compartilha `analysisExperienceMarkup(context)` com `openAnalysis` | Resumos por período, coorte de conversão, profissionais, campanhas, evolução, calendário, filtros personalizados e modal **Listar** com sete controles combináveis. |
| Atendimentos | `window.AttendancesModule.renderEmbeddedAnalysis({ root, bridge, storeId })`; lê `lc_get_attendance_workspace` e `lc_list_attendances_v2` paginado | KPIs, funil, financeiro, top profissionais, qualidade de vínculos, busca/filtros e detalhe de até 20 sobre uma base protegida de até 2.000. |

Os dois módulos embutidos expõem também `destroyEmbeddedAnalysis(root)`. A desmontagem remove listeners e DOM; o controle de geração ignora respostas obsoletas. Toda consulta continua sujeita às validações de papel, tenant, carteira, loja e licença do servidor.

### 12.3 Paleta e responsividade

- Leads: base neutra e mais escura.
- Prospecções: base azulada.
- Atendimentos: base esverdeada.
- Em telas menores, as três opções continuam lado a lado no switch, com texto e ícones compactados; os painéis reorganizam grades sem remover recursos.
- `min-width: 0`, quebra controlada e estados vazios evitam texto fora dos cards e cortes horizontais.

## 13. Inteligência artificial

### 13.1 Configuração central

Somente o Admin altera a configuração central do tenant. Agência pode usar a IA analítica, mas não visualizar a chave. Loja não usa a análise comercial por chat, porém todos os três perfis podem usar o Assistente de Suporte restrito.

Provedores suportados:

- DeepSeek, modelo `deepseek-chat`;
- Gemini, com modelos oferecidos pela interface, como `gemini-3.5-flash`, `gemini-3.1-flash-lite` e `gemini-3.1-pro-preview`.

`lc_get_ai_settings` devolve `api_key` vazio e apenas `has_api_key`. A chave real é lida pela Edge Function via RPC restrita a `service_role`.

### 13.2 IA de análise comercial

- Cada conversa recebe o recorte de uma única loja.
- O contexto enviado é agregado/anonimizado: não inclui nome, telefone, observações nem OS.
- Até 24 mensagens por requisição.
- Até 6.000 caracteres por mensagem.
- Até 42.000 caracteres no histórico enviado.
- Até 90.000 caracteres de contexto JSON.
- Temperatura `0.25`.
- Amostras menores que 30 registros devem ser sinalizadas como pequenas.
- Rate limit atual: 120 análises por hora por tenant/Admin.
- Uso registra provedor, modelo, tipo, tokens estimados, latência e status.

O streaming é repassado como SSE. A interface permite parar, editar, copiar e excluir mensagens. O histórico fica apenas no navegador em `lead-control-ai-chats`, separado por conta e loja, com até 40 conversas.

### 13.3 Assistente de Suporte IA

O botão `?` abre o suporte para Admin, Agência e Loja após a autenticação. A resposta depende de o Admin ter configurado um provedor e uma chave válidos; na ausência disso, o runtime retorna indisponibilidade sem expor segredo. Apesar de estar disponível para todos os papéis, seu conhecimento é deliberadamente limitado aos fluxos do cliente:

- Leads: cadastro, acompanhamento, filtros, exportação e agenda;
- categorias, opções e sequência dos campos de Leads;
- Prospecções: operação, análise e bonificação, quando disponível;
- Atendimentos: cadastro, resumo, lista e filtros, quando disponível;
- tema e saída da sessão.

As perguntas rápidas atuais são **Cadastrar lead**, **Filtrar prospecções** e **Novo atendimento**.

Contas, agências, planos/licenças, termos, backups, integrações, arquitetura, código, banco, APIs, credenciais e assuntos externos são bloqueados antes da chamada ao provedor. E-mail, CPF, CNPJ, telefone e UUID detectáveis também bloqueiam a pergunta. Nenhum objeto de negócio é aceito no payload: somente `action: "support"`, o UUID opcional da loja ativa em `store_id` e até seis mensagens textuais de no máximo 1.800 caracteres cada, com limite total de 7.200 no servidor. A UI mantém no máximo cerca de 6.800 caracteres e cancela a tentativa após 30 segundos.

A resposta é JSON não-streaming com `answer_markdown`, `actions` e `scope: "client_flows_only"`, limitada a 2.600 caracteres no servidor. O navegador monta apenas parágrafos, listas e `**negrito**` usando nós DOM e `textContent`; não executa HTML, links, URLs, código ou comandos. O negrito das respostas do assistente usa o verde da identidade visual.

Atalhos aceitos:

| ID fixo | Fluxo |
|---|---|
| `open_leads` | Abre Leads no cliente atual. |
| `open_prospections` | Abre Prospecções se o contexto e a licença permitirem. |
| `open_attendances` | Abre Atendimentos se o contexto e a licença permitirem. |
| `open_lead_configuration` | Abre Leads e o editor de categorias/opções. |

O servidor devolve no máximo duas ações dentre as autorizadas pela RPC; o frontend ignora rótulos, ícones, seletores ou URLs recebidos, usa seu próprio catálogo e confere novamente a disponibilidade visual. Admin/Agência fora de um cliente não recebem atalhos de módulo. `app.js` ainda passa toda navegação pela proteção de alterações não salvas.

O chat de suporte é efêmero: fica somente em `state.messages`, não usa `localStorage` nem tabela de transcrição e é apagado ao recarregar, sair ou trocar a sessão. O log em `ai_usage` guarda metadados operacionais — provedor, modelo, tipo, estimativa de tokens, latência e status — sem conteúdo da conversa. O limite é de 40 solicitações de suporte por usuário em uma janela móvel de uma hora. A autorização adquire um advisory lock por usuário e cria a reserva de uso na mesma transação da contagem; requisições paralelas não conseguem ultrapassar a cota. A Edge conclui essa mesma reserva por `usage_id`; se a conclusão falhar, a reserva continua contando para proteger o custo.

## 14. Persistência local do navegador

| Chave/banco | Conteúdo |
|---|---|
| `lead-control-session` | Token bruto e perfil restaurável. |
| `lead-control-theme` | Tema claro ou escuro. |
| `lead-control-module:<profile id>` | Último módulo aberto pelo perfil. |
| `lead-control-ai-chats` | Chats locais da IA de análise, por conta e loja. Não contém o Assistente de Suporte. |
| IndexedDB `lead-control-backup` | Handles de pasta e manifestos de backup. |

Limpar dados do site encerra a restauração local, remove chats analíticos e exige escolher novamente o HD. A sessão ainda pode permanecer válida no servidor até expirar/revogar, mas o navegador perde o token. O suporte já desaparece em qualquer reload/logout porque sua conversa vive somente em memória.

## 15. Banco de dados — visão estrutural

### 15.1 Schemas

- `public`: tabelas de domínio e wrappers RPC chamados pelo browser/Edge Functions.
- `app_private`: validação de sessão, segredos e helpers internos.
- `extensions`: extensões Postgres usadas com `search_path` explícito.

No modelo consolidado pós-migrações existem **22 tabelas públicas de domínio e nenhuma tabela privada de negócio**. O schema `app_private` permanece para funções, validação e helpers. `!` significa `NOT NULL`; `?` significa anulável.

### 15.2 Tabelas de identidade, contas e jurídico

| Tabela | Colunas atuais |
|---|---|
| `app_users` | `id uuid!`, `nick text!`, `nick_key text!`, `password_hash text!`, `full_name text!`, `role app_user_role!`, `admin_user_id uuid?`, `store_id uuid?`, `is_active bool!`, `last_login_at timestamptz?`, `created_at!`, `updated_at!`, `store_limit int!`, `avatar_url text?`, `prospection_store_limit int!` |
| `app_sessions` | `id uuid!`, `user_id uuid!`, `token_hash text!`, `expires_at!`, `revoked_at?`, `last_seen_at?`, `created_at!` |
| `stores` | `id uuid!`, `admin_user_id uuid!`, `name text!`, `nick text!`, `nick_key text!`, `is_active bool!`, `created_at!`, `updated_at!`, `technician_user_id uuid?`, `avatar_url text?`, `prospection_enabled bool!` |
| `system_legal_terms` | `id uuid!`, `version text!`, `title text!`, `content text!`, `content_hash text!`, `effective_at!`, `is_active bool!`, `created_at!` |
| `legal_term_acceptances` | `id uuid!`, `terms_id uuid!`, `terms_version!`, `terms_title!`, `terms_snapshot!`, `terms_hash!`, `admin_user_id uuid!`, `accepting_user_id uuid?`, `account_role!`, `account_name_snapshot!`, `agency_name_snapshot?`, `store_name_snapshot?`, `signer_name!`, `signer_role!`, `signer_cpf_hash!`, `signer_cpf_last4!`, `signature_data_url!`, `signature_hash!`, `confirmations jsonb!`, `ip_address?`, `user_agent?`, `client_timezone?`, `client_timestamp?`, `accepted_at!`, `evidence_hash!` |

Existe índice único parcial que limita o ambiente a um único usuário global com papel Admin.

### 15.3 Leads e configuração

| Tabela | Colunas atuais |
|---|---|
| `leads` | `id uuid!`, `admin_user_id uuid!`, `store_id uuid!`, `name!`, `phone!`, `channel?`, `campaign?`, `conversation_start?`, `conclusion?`, `visited?`, `bought?`, `created_by uuid?`, `updated_by uuid?`, `created_at!`, `updated_at!`, `purchase_amount numeric?`, `service_order?`, `notes?`, `inspected bool!`, `scheduled?`, `scheduled_visit_date date?`, `scheduled_visit_time time?`, `contact_date date!` |
| `lead_intelligence` | `lead_id uuid!`, `admin_user_id uuid!`, `store_id uuid!`, `lifecycle_status!`, `qualified bool!`, `loss_reason?`, `owner_name?`, `email?`, `first_response_at?`, `qualified_at?`, `lost_at?`, `purchased_at?`, `returning_customer bool!`, `created_at!`, `updated_at!` |
| `lead_events` | `id uuid!`, `admin_user_id uuid!`, `store_id uuid!`, `lead_id uuid!`, `event_type!`, `event_at!`, `actor_user_id uuid?`, `source!`, `metadata jsonb!`, `created_at!` |
| `lead_options` | `id uuid!`, `admin_user_id uuid!`, `group_key!`, `value!`, `sort_order int!`, `fixed bool!`, `is_active bool!`, `created_at!`, `updated_at!`, `store_id uuid?` |
| `lead_custom_categories` | `id uuid!`, `admin_user_id uuid!`, `name!`, `sort_order int!`, `is_active bool!`, `created_at!`, `updated_at!`, `store_id uuid?` |
| `lead_custom_options` | `id uuid!`, `admin_user_id uuid!`, `category_id uuid!`, `value!`, `sort_order int!`, `is_active bool!`, `created_at!`, `updated_at!` |
| `lead_custom_values` | `lead_id uuid!`, `admin_user_id uuid!`, `category_id uuid!`, `value!`, `created_at!`, `updated_at!` |
| `store_configuration_labels` | `store_id uuid!`, `admin_user_id uuid!`, `group_key!`, `label!`, `created_at!`, `updated_at!` |

### 15.4 Prospecções e Atendimentos

| Tabela | Colunas atuais |
|---|---|
| `prospections` | `id uuid!`, `admin_user_id uuid!`, `store_id uuid!`, `name!`, `phone?`, `cpf?`, `notes?`, `probability!`, `tags text[]!`, `professional_id uuid?`, `professional_name_snapshot?`, `returned_at?`, `purchased_at?`, `purchase_amount?`, `purchase_order?`, `created_by?`, `updated_by?`, `created_at!`, `updated_at!`, `import_source?`, `import_source_store_id?`, `import_source_id?`, `import_source_updated_at?`, `import_batch_id?`, `imported_at?` |
| `prospection_professionals` | `id uuid!`, `store_id uuid!`, `admin_user_id uuid!`, `name!`, `is_active bool!`, `created_at!`, `updated_at!`, `archived_at?`, `archived_by?` |
| `prospection_store_settings` | `store_id uuid!`, `admin_user_id uuid!`, `daily_goal int!`, `bonus_minimum numeric!`, `bonus_amount numeric!`, `accent_color!`, `created_at!`, `updated_at!`, `logo_background_color!` |
| `prospection_tag_categories` | `id uuid!`, `store_id uuid!`, `admin_user_id uuid!`, `name!`, `sort_order int!`, `created_at!`, `updated_at!` |
| `prospection_tags` | `id uuid!`, `store_id uuid!`, `admin_user_id uuid!`, `label!`, `created_at!`, `updated_at!`, `category_id uuid!`, `sort_order int!` |
| `prospection_import_batches` | `id uuid!`, `admin_user_id uuid!`, `store_id uuid!`, `imported_by?`, `source_format!`, `schema_version!`, `source_store_id!`, `payload_sha256!`, `exported_at?`, `summary jsonb!`, `created_at!` |
| `attendances` | `id uuid!`, `admin_user_id uuid!`, `store_id uuid!`, `professional_id?`, `professional_name_snapshot!`, `credited_professional_id?`, `credited_professional_name_snapshot?`, `prospection_professional_id?`, `prospection_professional_name_snapshot?`, `bonus_minimum_snapshot!`, `bonus_amount_snapshot!`, `bonus_eligible!`, `bonus_awarded_amount!`, `bonus_credit_status!`, `customer_name!`, `phone!`, `phone_normalized!`, `description!`, `tag!`, `service_value?`, `purchase_value?`, `service_order?`, `lead_id?`, `prospection_id?`, `match_status!`, `lead_match_count!`, `prospection_match_count!`, `match_ambiguous!`, `lead_candidates jsonb!`, `prospection_candidates jsonb!`, `lead_visit_applied!`, `lead_purchase_applied!`, `prospection_visit_applied!`, `prospection_purchase_applied!`, `purchase_credit_applied!`, `attended_at!`, `outcome_applied_at?`, `idempotency_key!`, `request_fingerprint!`, `metadata jsonb!`, `created_by?`, `created_at!`, `updated_at!` |

### 15.5 Inteligência artificial

| Tabela | Colunas atuais |
|---|---|
| `ai_settings` | `admin_user_id uuid!`, `provider!`, `model!`, `api_key!`, `system_prompt!`, `updated_by_user_id?`, `created_at!`, `updated_at!` |
| `ai_usage` | `id uuid!`, `admin_user_id uuid!`, `user_id?`, `store_id?`, `provider!`, `model!`, `request_kind!`, `input_tokens?`, `output_tokens?`, `latency_ms?`, `status!`, `created_at!` |

O Assistente de Suporte não cria uma tabela de conversa. O rate limit consulta `ai_usage` com `request_kind = 'support_assistant'` e usa o índice parcial `ai_usage_support_user_date_idx (user_id, created_at desc)`.

### 15.6 Estruturas de anúncios removidas

A migração `20260818171504_remove_marketing_attribution.sql` elimina as duas gerações de integração. As seguintes tabelas **não fazem parte do modelo atual**:

- legado/manual: `ad_daily_metrics`, `store_marketing_targets`, `marketing_connections`, `marketing_conversion_queue`;
- atribuição: `marketing_attribution_connections`, `marketing_tracking_sources`, `marketing_touchpoints`, `marketing_attribution_events`, `marketing_ad_metrics`, `marketing_sync_queue`, `marketing_sync_runs`, `marketing_offline_conversion_queue`, `marketing_attribution_logs`;
- privadas: `app_private.marketing_attribution_connection_secrets`, `app_private.marketing_oauth_states`, `app_private.marketing_maintenance_state`.

A mesma migração remove de `lead_intelligence` todos os campos de UTM, IDs de campanha/anúncio/criativo, click IDs, landing page, ID externo e consentimento de marketing. `lead_intelligence` e `lead_events` permanecem porque sustentam o funil comercial nativo, não atribuição externa.

### 15.7 Schema privado após a limpeza

`app_private` continua obrigatório para `session_user`, wrappers `rpc_*`, triggers e helpers `SECURITY DEFINER`, mas não guarda credenciais de anúncios, estados OAuth ou tabelas de manutenção de integrações. Segredos da IA permanecem em `public.ai_settings` sem concessão direta ao navegador; somente RPCs de runtime restritas ao `service_role` entregam a configuração em tempo de execução à Edge Function.

## 16. Catálogo de RPCs

As funções `public.lc_*` são contratos usados pelo frontend. Em geral elas encaminham para `app_private.rpc_*`, que valida sessão, tenant, loja e papel. `anon` poder executar um wrapper não significa acesso aberto: o token da aplicação e as regras internas continuam obrigatórios.

### 16.1 Autenticação, contas e planos

- `lc_login`, `lc_current_profile`, `lc_logout`
- `lc_account_usage`
- `lc_create_store`
- `lc_create_technician` — contrato legado
- `lc_create_technician_with_feature_plan`
- `lc_update_admin_credentials`
- `lc_update_store_account` — contrato legado
- `lc_update_store_with_feature_access`
- `lc_update_technician_account` — contrato legado
- `lc_update_technician_with_feature_plan`
- `lc_delete_agency_account`, `lc_delete_store_account`
- `lc_list_stores`, `lc_list_technicians`
- `lc_list_profile_avatars`, `lc_set_profile_avatar`
- `lc_get_prospection_entitlements`
- `lc_set_store_prospection_access`
- `lc_set_technician_prospection_limit`

### 16.2 Jurídico

- `lc_get_required_legal_terms`
- `lc_accept_legal_terms`
- `lc_list_legal_acceptances`
- `lc_get_legal_acceptance_document`

### 16.3 Leads, inteligência e configuração

- `lc_list_leads`, `lc_upsert_lead`, `lc_upsert_lead_with_intelligence`, `lc_delete_lead`, `lc_set_lead_inspected`
- `lc_list_lead_intelligence`, `lc_save_lead_intelligence`
- `lc_list_options`, `lc_add_option`, `lc_update_option`, `lc_delete_option`, `lc_reorder_options`
- `lc_list_custom_categories`, `lc_add_custom_category`, `lc_update_custom_category`, `lc_delete_custom_category`, `lc_reorder_custom_categories`
- `lc_add_custom_option`, `lc_update_custom_option`, `lc_delete_custom_option`, `lc_reorder_custom_options`
- `lc_list_configuration_labels`, `lc_update_configuration_label`

### 16.4 Prospecções

- `lc_get_prospection_configuration`, `lc_list_prospections`, `lc_export_prospections`
- `lc_upsert_prospection`, `lc_delete_prospection`, `lc_set_prospection_outcome`
- `lc_save_prospection_configuration`, `lc_save_prospection_store_settings`, `lc_save_prospection_logo_background`
- `lc_upsert_prospection_category`, `lc_delete_prospection_category`, `lc_reorder_prospection_categories`
- `lc_add_prospection_tag`, `lc_update_prospection_tag`, `lc_delete_prospection_tag`, `lc_reorder_prospection_tags`
- `lc_upsert_prospection_professional`
- `lc_import_prospec_backup`

### 16.5 Atendimentos

- `lc_get_attendance_workspace`
- `lc_list_attendances_v2` (uso atual, filtros exatos e paginação coerente)
- `lc_list_attendances` (compatibilidade com clientes anteriores)
- `lc_upsert_attendance`

### 16.6 Inteligência artificial

- `lc_get_ai_settings`, `lc_save_ai_settings`
- Restritas a `service_role`: `lc_ai_runtime_config`, `lc_support_assistant_runtime`, `lc_log_ai_usage`

`public.lc_support_assistant_runtime(text, uuid)` é um wrapper `SECURITY INVOKER` sobre `app_private.rpc_support_assistant_runtime(text, uuid)`, que é `SECURITY DEFINER` com `search_path` explícito. O segundo argumento opcional é a loja ativa: quando informado, o runtime revalida o acesso àquela loja e calcula capacidades somente sobre sua licença; para Loja, o escopo é sempre a própria conta. O runtime revalida `session_user`, aceita apenas Admin/Agência/Loja ativos e aplica atomicamente o limite de 40 solicitações por hora por `user_id`, retornando o `usage_id` reservado. `lc_complete_support_assistant_usage` conclui somente essa reserva e somente via `service_role`. `EXECUTE` foi revogado de `PUBLIC`, `anon` e `authenticated` em todas as RPCs do runtime.

### 16.7 RPCs retiradas

Não existem contratos públicos de conexão, métrica, sincronização, tracker ou conversão de anúncios. A migração remove:

- `lc_list_ad_daily_metrics`, `lc_upsert_ad_daily_metric`;
- `lc_list_marketing_targets`, `lc_save_marketing_targets`;
- `lc_list_marketing_connections`, `lc_marketing_connection_runtime`;
- os pares privados `app_private.rpc_*` correspondentes;
- toda função `public.ma_*` e `app_private.ma_*`, incluindo dashboard, conexões, OAuth, tracker, jornada, sincronização, conversões, diagnóstico, logs e retenção.

O `DROP` dinâmico da migração é limitado por prefixo e schema para não atingir funções do núcleo.

### 16.8 Contratos críticos resumidos

| RPC | Entradas principais | Efeito |
|---|---|---|
| `lc_login` | nick, senha | Autentica e cria token de 30 dias. |
| `lc_update_store_with_feature_access` | sessão, loja, nome, nick, senha opcional, agência, `prospection_enabled` | Atualiza conta, vínculo e licença atomicamente. |
| `lc_create_technician_with_feature_plan` | sessão, nome, nick, senha, limite de lojas, limite Prospecções | Cria agência com franquias. |
| `lc_upsert_lead_with_intelligence` | sessão, loja, campos do lead, custom values, ID opcional, data de contato, intelligence JSON | Salva o cadastro completo e eventos. |
| `lc_save_prospection_configuration` | sessão, loja, snapshot/revisão de configuração | Salva profissionais, categorias, tags e parâmetros atomicamente. |
| `lc_upsert_prospection` | sessão, loja, cadastro, profissional, probabilidade e tags | Cria/edita prospecção. |
| `lc_set_prospection_outcome` | sessão, prospecção, retorno/compra/valor/OS | Atualiza resultado com rastreabilidade. |
| `lc_upsert_attendance` | sessão, loja, profissional, cliente, telefone, descrição, tipo, valores, OS, idempotência | Registra, vincula e aplica resultados seguros. |
| `lc_support_assistant_runtime` | sessão, loja opcional | Entrega somente à Edge Function a configuração da IA, capacidades, ações permitidas e uma reserva atômica de uso após validar perfil, escopo e rate limit. |
| `lc_complete_support_assistant_usage` | reserva, tenant, usuário, tokens, latência e status | Finaliza somente a reserva de suporte correspondente; execução exclusiva de `service_role`. |

### 16.9 Automações internas por trigger

Estas funções não são endpoints normais da interface; são acionadas pelo banco para manter consistência do produto:

- `app_private.capture_lead_lifecycle`: mantém `lead_intelligence` e grava eventos nativos `lead_created`, `scheduled`, `visited` e `purchased` a partir de mudanças em `leads`.
- `leads_capture_lifecycle`: trigger de `leads` ligado à função anterior.
- triggers/helpers de Prospecções e Atendimentos preservam timestamps, retenção e integridade próprios desses módulos.

O conjunto permitido em `lead_events` é `lead_created`, `contacted`, `qualified`, `scheduled`, `visited`, `purchased`, `lost` e `reopened`. Não existe evento de atribuição externa.

## 17. Edge Functions

### 17.1 Código local

| Função | Responsabilidade | Autorização |
|---|---|---|
| `ai-analysis` | IA analítica por SSE e Assistente de Suporte por JSON não-streaming, com políticas e formatos independentes. | `x-app-session`; configuração real via RPCs executadas como `service_role`. |

`ai-analysis` é a única Edge Function presente em `supabase/functions/` e a única entrada em `supabase/config.toml`. `verify_jwt = false` é intencional porque o produto não usa Supabase Auth; a função exige `x-app-session`. Análise usa `lc_ai_runtime_config`; suporte usa `lc_support_assistant_runtime`. Ambas são chamadas pelo processo servidor com a chave de serviço, nunca pelo browser.

Na ação `support`, o servidor aceita apenas `action`, `messages` e o `store_id` opcional da loja ativa, aplica a política determinística, revalida esse escopo no banco, envia ao provedor somente o manual estático, capacidades booleanas, IDs permitidos e a pergunta aprovada, e valida novamente o JSON de saída. Respostas de suporte usam `Cache-Control: no-store` e `X-Content-Type-Options: nosniff`.

### 17.2 Estado local e estado remoto

Em 18 de agosto de 2026, o estado remoto foi conferido depois da limpeza: somente `ai-analysis` permanece ativa, na versão 2, com a rota `action: "support"` publicada. `marketing-api` e `marketing-worker` foram excluídas; não há implantação de `marketing-conversions`, `whatsapp-api`, `whatsapp-webhook` ou `whatsapp-worker`. O smoke test remoto confirmou `OPTIONS 200`, requisição sem sessão `401`, sessão inválida `401` e negação `401` das RPCs de suporte aos papéis web.

Excluir código do repositório não apaga automaticamente uma função publicada. Por isso, futuras manutenções devem sempre comparar o diretório local com `supabase functions list` e nunca reinstalar as funções descontinuadas acima.

O GitHub Pages não publica nem remove Edge Functions. A disponibilidade real da IA depende de `ai-analysis` estar implantada no mesmo projeto Supabase do frontend.

### 17.3 Configuração sensível

- `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY`: variáveis preferenciais usadas pela Edge Function. O código também reconhece `SUPABASE_SECRET_KEY` e `SUPABASE_SECRET_KEYS.default` como formatos server-side alternativos.
- A chave do provedor de IA é configurada por tenant em `ai_settings`; ela não volta para Admin/Agência em respostas comuns.
- Gemini ou DeepSeek é escolhido pela configuração central do Admin.

Não existem segredos, chaves Vault ou variáveis de ambiente para anúncios ou WhatsApp. Nunca registrar chaves de IA, service role ou tokens de sessão em Markdown, Git, frontend ou logs.

## 18. RLS e modelo de segurança

### 18.1 Modelo consolidado

- RLS está habilitado nas tabelas públicas.
- Não há policy de leitura/escrita direta para `anon`/`authenticated` nas tabelas de negócio.
- Privilégios diretos das tabelas críticas são revogados.
- O acesso normal ocorre por funções `SECURITY DEFINER` com `search_path` explícito e validação de escopo.
- Funções que expõem segredo/runtime são concedidas somente a `service_role`.
- Funções e helpers de `app_private` não são uma superfície de dados direta do navegador.

### 18.2 Barreiras aplicadas

1. Sessão válida e não revogada.
2. Usuário e loja ativos.
3. Termo jurídico atual aceito.
4. Mesmo `admin_user_id`.
5. Loja dentro da carteira ou própria loja.
6. Papel autorizado para a operação.
7. Licença Prospecções ativa quando exigida.
8. Validação e normalização de payload no servidor.
9. Idempotência em operações sujeitas a retry.
10. Central de análise limitada a uma loja permitida; abas premium bloqueadas sem licença.
11. Geração assíncrona e desmontagem dos painéis embutidos para impedir resposta obsoleta de outra loja.
12. Assistente de Suporte restrito por classificador determinístico, bloqueio de identificadores pessoais, payload textual mínimo, capacidades booleanas e allowlist dupla — servidor e navegador.
13. RPC de suporte sem `EXECUTE` para papéis web; acesso à chave e às capacidades somente via `service_role` dentro da Edge Function.

### 18.3 Dados sensíveis

- Senhas: bcrypt.
- Tokens de sessão: somente hash no banco.
- CPF jurídico: hash + últimos 4 dígitos.
- Chave do provedor de IA: nunca retornada por `lc_get_ai_settings`; leitura integral somente via RPC de serviço.
- Avatares: imagens WebP/data URL no banco; upload fonte limitado a 8 MB e otimizado no navegador.
- Sessão bruta e chats da IA analítica: armazenamento local do navegador; exigem cuidado reforçado contra XSS.
- Chat de suporte: somente memória da página, sem transcrição em `localStorage` ou banco; as mensagens aprovadas são processadas durante a requisição e somente metadados de uso são registrados.

## 19. Migrações e evolução do banco

### 19.1 Instalação limpa

Ordem recomendada para um ambiente novo:

1. `database.sql`
2. `prospection_configuration_batch_update.sql`
3. `prospection_backup_import_update.sql`
4. `attendance_module.sql`
5. `supabase/migrations/20260818190526_attendance_list_v2_filters.sql`
6. provisionar o Admin global com procedimento administrativo controlado;
7. publicar somente `supabase/functions/ai-analysis`;
8. configurar o provedor de IA pela conta Admin, se a ferramenta for usada.

Os passos 2 e 3 completam, respectivamente, o salvamento atômico da configuração e a importação idempotente de backups de Prospecções; esses dois contratos não estão incorporados ao `database.sql` consolidado. O runtime atômico do Assistente de Suporte e a ocultação da chave nas RPCs de configuração já estão no `database.sql` atual. Portanto, as migrations `20260818182307_support_assistant_authorization.sql` e `20260818193000_redact_ai_settings_key.sql` não devem ser reaplicadas em uma instalação limpa criada por esse arquivo.

As migrações de remoção não são necessárias numa instalação limpa baseada no `database.sql` atual. `remove_whatsapp_module.sql` e `supabase/migrations/20260818171504_remove_marketing_attribution.sql` existem para atualizar ambientes antigos.

### 19.2 Ambiente existente

Não reaplicar `database.sql` inteiro sem revisão. Para um banco existente:

1. gerar e verificar backup;
2. aplicar somente a migração relevante;
3. usar `20260818171504_remove_marketing_attribution.sql` para retirar anúncios/atribuição;
4. usar `remove_whatsapp_module.sql` apenas se ainda houver vestígios do módulo WhatsApp;
5. aplicar `20260818182307_support_assistant_authorization.sql` antes de publicar o Assistente de Suporte;
6. aplicar `20260818190526_attendance_list_v2_filters.sql` antes de publicar o frontend que chama a RPC v2;
7. aplicar `20260818193000_redact_ai_settings_key.sql` para garantir que a chave da IA nunca volte ao navegador;
8. validar tabelas, funções, grants, triggers, cron e funcionamento do app.

A remoção de atribuição é propositalmente destrutiva: apaga métricas, conexões, filas, logs e campos de rastreamento. O arquivo é transacional, usa limites de lock/execução e restringe o `DROP` dinâmico às funções `ma_*`, mas backup e validação continuam obrigatórios.

### 19.3 Inventário das migrações incrementais

| Arquivo/grupo | Área |
|---|---|
| `account_management_update.sql`, `admin_account_update.sql` | Gestão de contas e credenciais. |
| `technician_role_step1.sql`, `technician_role_step2.sql` | Introdução/evolução do papel Agência. |
| `b2b_client_hierarchy_update.sql` | Hierarquia Admin → Agência → Cliente. |
| `prospection_access_control_update.sql`, `prospection_plan_downgrade_fix.sql` | Licenças e downgrade. |
| `client_scoped_configuration_update.sql`, `store_options_update.sql`, `agency_store_configuration_editor_update.sql` | Configuração por loja. |
| `custom_categories_update.sql`, `option_add_value_update.sql`, `reactivate_deleted_options_update.sql` | Categorias/opções de Leads. |
| `appointment_scheduling_enum_update.sql`, `appointment_scheduling_update.sql` | Agendamento. |
| `lead_contact_date_step1.sql`, `lead_contact_date_update.sql`, `lead_contact_date_mac.sql` | Data de contato e variantes de implantação. |
| `lead_inspected_update.sql`, `lead_notes_update.sql`, `purchase_fields_update.sql` | Campos incrementais de Leads. |
| `central_ai_configuration_update.sql` | IA central do tenant. |
| `supabase/migrations/20260818182307_support_assistant_authorization.sql` | Runtime e autorização server-only do Assistente de Suporte, reserva atômica, conclusão de uso, capacidades e índice do rate limit. |
| `supabase/migrations/20260818190526_attendance_list_v2_filters.sql` | Listagem v2 de Atendimentos, com profissional histórico e estados de vínculo exatos antes da paginação. |
| `supabase/migrations/20260818193000_redact_ai_settings_key.sql` | Garante por migration rastreável que RPCs acessíveis ao navegador devolvam apenas `has_api_key`, nunca o segredo. |
| `lead_intelligence_update.sql` | Inteligência comercial e eventos nativos de ciclo de vida, sem atribuição externa. |
| `prospection_brand_identity_update.sql` | Identidade visual por loja. |
| `prospection_configuration_batch_update.sql` + QA | Configuração atômica/revisões. |
| `prospection_backup_import_update.sql` + QA | Importação idempotente. |
| `attendance_module.sql` | Módulo Atendimentos completo. |
| `legal_terms_retention_access_update.sql` | Termos, evidência e gate de acesso. |
| `remove_whatsapp_module.sql` | Retirada definitiva e destrutiva do módulo descontinuado. |
| `supabase/migrations/20260818171504_remove_marketing_attribution.sql` | Retirada definitiva e destrutiva das duas gerações de anúncios/atribuição. |

## 20. Agendamentos remotos

Estado esperado após as migrações:

| Job | Cron | Ação |
|---|---|---|
| `lc_attendance_retention_daily` | `17 3 * * *` | `app_private.attendance_purge_retention()` |

Não existe job de anúncios ou WhatsApp. A migração cancela `marketing-worker-2-minutes` e o alias histórico `marketing-worker-30-seconds`, além de remover o histórico desses jobs.

## 21. Deploy e operação

### 21.1 Frontend

O workflow `.github/workflows/pages.yml` executa em push para `main` ou manualmente:

1. checkout;
2. configuração do GitHub Pages;
3. cópia dos arquivos estáticos para `_site`, incluindo `support-assistant.js` e `support-assistant.css` junto de `app.js`, módulos, estilos, manifesto, ícones e `assets/`;
4. criação de `.nojekyll`;
5. upload do artefato;
6. deploy do Pages.

Não existe build, minificação ou injeção de variáveis. Mudanças em URLs/chaves públicas do Supabase são feitas no código e exigem novo deploy.

### 21.2 Banco e funções

Banco e Edge Functions **não são publicados pelo workflow do Pages**. São implantações separadas com Supabase CLI/SQL Editor.

Para publicar esta versão em um ambiente existente, a ordem segura é:

1. revisar e aplicar, nessa ordem, as migrations de suporte, listagem v2 de Atendimentos e ocultação da chave da IA;
2. implantar `supabase/functions/ai-analysis` com a rota de suporte;
3. publicar o frontend com `index.html`, `support-assistant.js` e `support-assistant.css`;
4. testar Loja com e sem Prospecções e Admin/Agência dentro e fora de um cliente.

Publicar apenas o frontend antes da migração e da Edge Function deixaria o botão visível, mas o runtime de suporte indisponível. Nesta entrega, as três migrations foram aplicadas e `ai-analysis` versão 2 foi implantada e testada antes da publicação do frontend.

Comandos típicos:

```bash
supabase link --project-ref menlvmsgkhgqxiydphbn
supabase functions deploy ai-analysis --no-verify-jwt
supabase functions list
```

Se uma implantação antiga ainda listar funções removidas, excluí-las explicitamente; apagar os diretórios locais ou publicar o Pages não altera o estado remoto:

```bash
supabase functions delete marketing-api --project-ref menlvmsgkhgqxiydphbn
supabase functions delete marketing-worker --project-ref menlvmsgkhgqxiydphbn
supabase functions delete marketing-conversions --project-ref menlvmsgkhgqxiydphbn
supabase functions delete whatsapp-api --project-ref menlvmsgkhgqxiydphbn
supabase functions delete whatsapp-webhook --project-ref menlvmsgkhgqxiydphbn
supabase functions delete whatsapp-worker --project-ref menlvmsgkhgqxiydphbn
```

Execute apenas os comandos referentes a funções que realmente existirem no projeto. A migração SQL também precisa ser aplicada separadamente; o deploy web não altera banco, cron ou Vault.

### 21.3 Execução local

Como o site é estático, um servidor simples basta:

```bash
python3 -m http.server 4173
```

Abrir `http://127.0.0.1:4173`. Usar servidor HTTP evita restrições de módulos/APIs que podem ocorrer com `file://`.

## 22. Validação e testes

### 22.1 Frontend

```bash
node --check app.js
node --check prospections.js
node --check attendances.js
node --check support-assistant.js
```

Checklist manual mínimo:

- login, restauração e logout;
- perfis Admin, Agência e Loja;
- tema claro/escuro;
- desktop e larguras `900px`, `720px`, `390px` e `320px`;
- criação/edição/exclusão de conta e loja;
- CRUD e exportação de Leads;
- agendamentos;
- Prospecções licenciada e downgrade;
- Atendimentos com match único, ambíguo e sem match;
- termos pendentes e aceitos;
- IA sem chave, com chave, streaming e interrupção;
- Central de análise com a mesma loja nas três abas e bloqueio de licença;
- troca rápida de cliente/aba sem reaparecimento de dados da seleção anterior;
- Prospecções: mesma experiência na loja e na Central, coorte sem conversão acima de 100% e **Listar** com os sete controles combinados;
- Atendimentos: busca, filtros com ícones, páginas de 30, carregar mais, retry, limite protegido da análise e aviso de amostra;
- switch operacional oculto fora de cliente e visível dentro do cliente;
- Assistente de Suporte para os três perfis, escopo recusado, PII recusada, sessão sem configuração, atalhos com/sem licença e limpeza do chat em logout/reload;
- Markdown do suporte sem execução de HTML/URL e com `**negrito**` verde;
- backup com e sem permissão do HD.

### 22.2 Banco

```bash
supabase db lint --linked --schema public,app_private --level error --fail-on error
```

Executar os arquivos `*_qa.sql` em transação e confirmar rollback ao final. Validar RLS, grants, funções duplicadas e jobs após qualquer migração.

### 22.3 Edge Function de IA

Validar `OPTIONS`/CORS, método diferente de POST, ausência ou expiração de `x-app-session`, configuração inexistente, provedor indisponível, limites de payload, streaming, interrupção e ausência de chave/service role em respostas e logs.

Validações locais específicas do suporte:

```bash
deno check supabase/functions/ai-analysis/index.ts
deno test --allow-env supabase/functions/ai-analysis/support_policy_test.ts
```

O teste automatizado cobre perguntas permitidas, continuação curta com tópico anterior, bloqueio de áreas privilegiadas/externas, bloqueio de identificadores pessoais, limite/formato do histórico, capacidade por módulo, prioridade de “análise de Leads” e impossibilidade de uma mensagem `assistant` forjada criar contexto. Neste checkout, em 18 de agosto de 2026, os quatro `node --check`, o `deno check`, o `deno lint`, os **7 testes Deno**, o lint remoto do banco e o QA visual em 390px/1440px foram executados com sucesso.

Estado verificado em 18 de agosto de 2026: `ai-analysis` versão 2 ativa, `OPTIONS` respondendo `200`, `POST` sem sessão ou com sessão inválida bloqueado com `401`, e RPCs de runtime/conclusão recusadas aos papéis web com `401`.

## 23. Lacunas e riscos conhecidos no retrato atual

### Prioridade alta

1. **Deploy web, banco e Edge Functions são independentes.** A retirada desta versão já foi aplicada e verificada remotamente, mas um futuro commit do frontend sozinho continuará sem alterar banco, cron, Vault ou funções publicadas.
2. **A migração de retirada é destrutiva.** Métricas, conexões, filas, logs e identificadores de atribuição apagados não são recuperáveis sem backup.
3. **O suporte exige implantação coordenada.** Migração, Edge Function e frontend precisam seguir essa ordem; a presença remota de `ai-analysis` ainda não confirma que a rota local de suporte está publicada.

### Prioridade média

4. `database.sql` é uma base consolidada extensa; reaplicá-la sem revisão em ambiente existente continua arriscado.
5. Não há suíte automatizada completa de regressão visual/E2E para uma interface grande e muito dependente de perfil, licença, tema e largura.
6. Sessão e chats da IA analítica ficam em `localStorage`; uma política CSP forte e revisão contínua contra XSS são importantes. O Markdown do novo suporte é seguro por construção, mas não corrige renderizadores legados da IA analítica.
7. `ai-analysis` responde CORS com origem ampla e depende da validação obrigatória de `x-app-session`; qualquer flexibilização dessa validação ou dos grants `service_role` seria uma falha crítica.
8. A política do suporte é determinística e testada, mas alterações no manual, expressões de escopo ou catálogo de ações exigem atualizar e repetir os testes. O recurso também depende de um provedor/chave central configurados pelo Admin.
9. O backup automático depende de navegador aberto, API Chromium, permissão e HD conectado; não é um backup de servidor independente.

### Limitações intencionais

10. PWA sem Service Worker: instalável, mas não offline.
11. A Central analisa uma loja por vez; não compara nem combina clientes.
12. Prospecções e Atendimentos ficam indisponíveis sem a licença conjunta.
13. **Listar** em Prospecções mostra até 200 registros filtrados. A análise de Atendimentos carrega até 2.000 registros por período e exibe até 20 no detalhamento; ambas informam o limite quando aplicável.
14. O chat de suporte é descartado em reload/logout por design e não oferece histórico recuperável.
15. A retenção remove históricos antigos conforme regras de dois anos/730 dias.

## 24. Retiradas definitivas

### 24.1 Anúncios e atribuição externa

Arquivos removidos do repositório:

- `marketing.js`, `marketing.css`;
- `marketing_attribution_module.sql`, `marketing_scheduler.sql`, `marketing_intelligence_update.sql`;
- `MARKETING_ATTRIBUTION_SETUP.md`, `MARKETING_INTELLIGENCE_SETUP.md`;
- `supabase/functions/marketing-api/`;
- `supabase/functions/marketing-worker/`;
- `supabase/functions/marketing-conversions/`;
- `supabase/functions/_shared/marketing/`.

`marketing_intelligence_update.sql` foi substituído por `lead_intelligence_update.sql`, que mantém apenas inteligência comercial nativa e auditoria de IA. `database.sql`, `index.html`, `app.js`, o workflow do Pages e `supabase/config.toml` não carregam nem publicam código de anúncios.

A migração de retirada também:

- remove as tabelas e RPCs inventariadas nas seções 15.6 e 16.7;
- remove triggers/funções `ma_*` e recria o lifecycle nativo de Leads;
- restringe `lead_events` aos eventos comerciais internos;
- cancela os crons `marketing-worker-2-minutes` e `marketing-worker-30-seconds`;
- remove os itens Vault `marketing_project_url` e `marketing_worker_secret`;
- elimina a necessidade de `MARKETING_ALLOWED_ORIGINS`, `MARKETING_APP_ORIGINS`, `MARKETING_CREDENTIALS_KEY`, `MARKETING_TRACKING_PEPPER` e `MARKETING_WORKER_SECRET`.

Não existe instrução suportada para reinstalar essa estrutura. Canais e campanhas continuam como rótulos internos; não há API, OAuth, pixel, tracker, sincronização ou envio de conversão.

### 24.2 WhatsApp

O estado correto do produto é:

- sem aba ou botão de módulo WhatsApp;
- sem JavaScript/CSS de WhatsApp;
- sem `whatsapp-api`, `whatsapp-webhook` ou `whatsapp-worker`;
- sem arquivos compartilhados de webhook/Meta exclusivos desse módulo;
- sem tabelas `whatsapp_*` públicas ou privadas;
- sem colunas `stores.whatsapp_enabled`, `app_users.whatsapp_phone` ou `app_users.whatsapp_store_limit`;
- sem RPCs `wa_*` ou com nome WhatsApp;
- sem secrets/jobs `whatsapp_*`;
- sem franquia de WhatsApp no plano;
- sem documentação operacional desse módulo.

`remove_whatsapp_module.sql` também recria as operações genéricas de plano apenas com a licença Prospecções + Atendimentos. A migração não altera Leads, telefones, Prospecções ou Atendimentos.

## 25. Glossário

| Termo | Significado no projeto |
|---|---|
| Admin | Conta global e proprietária do tenant. |
| Agência | Papel técnico `technician`; gerencia uma carteira de lojas. |
| Cliente/Loja | Unidade final que registra e acompanha dados. |
| Tenant | Conjunto isolado por `admin_user_id`. |
| Lead | Contato comercial captado e acompanhado no funil. |
| Prospecção | Pessoa/oportunidade em trabalho ativo de retorno. |
| Atendimento | Interação realizada por um profissional na loja. |
| OS | Ordem de serviço que comprova/rastreia uma compra. |
| RPC | Função PostgreSQL chamada remotamente. |
| Edge Function | Função Deno no Supabase; neste projeto, somente o proxy de IA. |
| Idempotência | Garantia de que retries não duplicam uma operação. |
| RLS | Segurança em nível de linha do PostgreSQL. |
| Snapshot | Cópia histórica de nome/configuração no momento do evento. |
| Coorte | Conjunto de registros criados no mesmo recorte e usado como base comum de uma taxa. |
| Allowlist | Lista fechada de IDs aceitos; qualquer ação fora dela é descartada. |

## 26. Fonte de verdade por assunto

| Assunto | Fonte principal |
|---|---|
| Estrutura visual | `index.html` e arquivos CSS |
| Fluxos do núcleo/Leads | `app.js` |
| Prospecções | `prospections.js`, `prospections.css` e RPCs `lc_*prospection*` |
| Atendimentos | `attendances.js`, `attendances.css`, `attendance_module.sql` e `supabase/migrations/20260818190526_attendance_list_v2_filters.sql` |
| Central única de análise | `index.html`, `app.js`, `styles.css`, `mobile.css` e APIs embutidas dos dois módulos |
| IA de análise | `app.js`, `central_ai_configuration_update.sql`, `supabase/functions/ai-analysis/index.ts` |
| Assistente de Suporte IA | `support-assistant.js`, `support-assistant.css`, `SUPPORT_ASSISTANT_INTEGRATION.md`, `supabase/functions/ai-analysis/index.ts`, `supabase/functions/ai-analysis/support_policy_test.ts`, `supabase/migrations/20260818182307_support_assistant_authorization.sql` e `supabase/migrations/20260818193000_redact_ai_settings_key.sql` |
| Retirada de anúncios/atribuição | `lead_intelligence_update.sql` e `supabase/migrations/20260818171504_remove_marketing_attribution.sql` |
| Retirada do WhatsApp | `remove_whatsapp_module.sql` |
| Segurança/permissões reais | Schema e funções do banco remoto |
| Deploy web | `.github/workflows/pages.yml` |
| Funções publicadas | `supabase functions list` no projeto vinculado |
| Histórico de evolução | `database.sql` e migrações `*_update.sql` |

Ao alterar o produto, atualizar este documento junto com o contrato afetado e registrar a nova data do retrato técnico.
