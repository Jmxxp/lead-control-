# Controle de Leads da Ótica

App estático em HTML, CSS e JavaScript usando Supabase direto do navegador.

## Onde os dados ficam

- Login e sessão: Supabase Auth. O SDK mantém a sessão no navegador para não pedir login toda hora.
- Lojas: tabela `public.stores`.
- Leads: tabela `public.leads`.
- Opções do formulário: tabela `public.lead_options`.

Nenhum dado de negócio deve ficar em `localStorage`.

## Configuração no Supabase

1. Abra o Supabase Dashboard do projeto.
2. Vá em `SQL Editor`.
3. Rode todo o arquivo `supabase/schema.sql`.
4. Em `Authentication > Providers`, deixe `Email` habilitado.
5. Em `Authentication > Providers > Email`, desligue confirmação obrigatória de email.

O sistema usa nick na tela e um email técnico interno no formato `nick@leadcontrol.local`.

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
