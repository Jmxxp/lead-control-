# Documentação

Comece pelo [README do projeto](../README.md) para consultar a estrutura e executar o site localmente.

| Documento | Conteúdo |
| --- | --- |
| [Visão completa do projeto](DOCUMENTACAO_COMPLETA_PROJETO.md) | Arquitetura, funcionalidades, contratos, operação e validação. |
| [Assistente de Suporte](SUPPORT_ASSISTANT_INTEGRATION.md) | Integração do assistente, configuração e comportamento. |
| [Web Push](PWA_PUSH_BACKEND_CONTRACT.md) | Contrato das notificações e integração com o backend. |
| [Bom Dia Vendedor](bom-dia-vendedor-dias-sem-expediente.md) | Calendário de dias sem expediente e regras das metas. |
| [Organização do Supabase](../supabase/README.md) | Migrations, funções, bootstrap e arquivos históricos. |
| [Guia de testes](../tests/README.md) | Testes do frontend e cenários de integração SQL. |

## Onde colocar os arquivos

- `assets/css/`: estilos e responsividade.
- `assets/js/`: código executado no navegador.
- `assets/icons/`: favicons e ícones instaláveis da PWA.
- `assets/images/`: logo original (`logo-source.png`) e imagem de compartilhamento (`link-preview.png`).
- `docs/`: documentação técnica e operacional.
- `tests/frontend/`: testes automatizados do frontend.
- `tests/sql/`: cenários de integração do banco, com instruções no [guia SQL](../tests/sql/README.md).
- `supabase/`: arquivos do backend, seguindo a [política de organização](../supabase/README.md).

`index.html`, `manifest.webmanifest`, `service-worker.js` e `favicon.ico` ficam na raiz para preservar os caminhos públicos e o escopo da PWA. A publicação é configurada em `.github/workflows/pages.yml`.
