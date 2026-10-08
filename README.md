# Controle de Leads

SPA estática para gestão de Leads, Prospecções e Atendimentos, com backend no Supabase e publicação pelo GitHub Pages.

## Estrutura

```text
assets/
├── css/       # Design system, módulos e responsividade
├── js/        # Runtime principal, módulos e cliente Web Push
├── icons/     # Favicons e ícones da PWA
└── images/    # Logo original e imagem de compartilhamento
docs/          # Documentação técnica e operacional
supabase/      # Migrations, Edge Functions, bootstrap e legado isolado
tests/
├── frontend/  # Testes automatizados Node
└── sql/       # Cenários de integração SQL
```

`index.html`, `manifest.webmanifest`, `service-worker.js` e `favicon.ico` ficam intencionalmente na raiz. O Service Worker precisa dessa posição para manter o escopo da aplicação, e o manifesto usa URLs relativas ao mesmo escopo.

## Execução local

Não há etapa de build nem dependências npm. Inicie um servidor estático na raiz:

```bash
python3 -m http.server 4173
```

Abra `http://127.0.0.1:4173`.

## Validação

```bash
for file in assets/js/*.js service-worker.js; do node --check "$file" || exit; done
node --test tests/frontend/*.test.js
git diff --check
```

No PowerShell, execute a suíte com `node --test (Get-ChildItem tests/frontend -Filter '*.test.js').FullName`. Os comandos completos estão no [guia de testes](tests/README.md).

## Identidade visual

O arquivo `assets/images/logo-source.png` é a fonte da logo atual. Os ícones derivados ficam em `assets/icons/`, o favicon convencional em `favicon.ico` e a imagem de compartilhamento em `assets/images/link-preview.png`.

## Documentação

- [Índice da documentação](docs/README.md)
- [Visão completa do projeto](docs/DOCUMENTACAO_COMPLETA_PROJETO.md)
- [Integração do Assistente de Suporte](docs/SUPPORT_ASSISTANT_INTEGRATION.md)
- [Contrato do Web Push](docs/PWA_PUSH_BACKEND_CONTRACT.md)
- [Organização do Supabase](supabase/README.md)
- [Guia de testes](tests/README.md)

O diretório local `prospec/` e arquivos `prospec-backup*.json` são ignorados pelo Git, servem apenas como referência e não entram no deploy.
