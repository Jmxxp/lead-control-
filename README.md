# Controle de Leads

SPA estática para gestão de Leads, Prospecções e Atendimentos, com backend no Supabase e publicação pelo GitHub Pages.

## Estrutura

```text
assets/
├── css/       # Design system, módulos e responsividade
├── js/        # Runtime principal, módulos e cliente Web Push
├── icons/     # Favicons e ícones da PWA
└── images/    # Logos e imagem de compartilhamento
docs/          # Documentação técnica e operacional
supabase/      # Migrations, Edge Functions, bootstrap e legado isolado
tests/         # Testes Node e cenários SQL
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
node --test tests/*.test.js
git diff --check
```

## Documentação

- [Visão completa do projeto](docs/DOCUMENTACAO_COMPLETA_PROJETO.md)
- [Integração do Assistente de Suporte](docs/SUPPORT_ASSISTANT_INTEGRATION.md)
- [Contrato do Web Push](docs/PWA_PUSH_BACKEND_CONTRACT.md)
- [Organização do Supabase](supabase/README.md)

O diretório local `prospec/` e arquivos `prospec-backup*.json` são ignorados pelo Git, servem apenas como referência e não entram no deploy.
