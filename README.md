# Controle de Leads da Ótica

App estático em HTML, CSS e JavaScript usando Supabase direto do navegador.

## Onde os dados ficam

- Login e sessão: Supabase Auth. O SDK mantém a sessão no navegador para não pedir login toda hora.
- Usuários do app: tabela `public.app_users`, com nick e senha criptografada.
- Lojas: tabela `public.stores`.
- Leads: tabela `public.leads`.
- Opções do formulário: tabela `public.lead_options`.

Nenhum dado de negócio deve ficar em `localStorage`.

## Configuração no Supabase

1. Abra o Supabase Dashboard do projeto.
2. Vá em `SQL Editor`.
3. Rode todo o arquivo `supabase/schema.sql`.
4. Em `Authentication > Providers`, habilite `Anonymous sign-ins`.

O sistema usa apenas nick e senha. Não usa email real nem email técnico.

## Rodar o sistema

Abra `index.html` no navegador ou use qualquer servidor estático/Live Server.

Arquivos principais:

- `index.html`
- `styles.css`
- `app.js`
- `supabase/schema.sql`

## Fluxo

1. Abra o app.
2. Crie o admin.
3. Entre com o admin.
4. Cadastre lojas, opções e leads.
5. Use o mesmo login em outro computador/celular para acessar os dados do banco.
