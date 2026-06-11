# Controle de Leads da Ótica

Sistema com login por nick e senha, Supabase, painel admin, cadastro de lojas e tela de leads por loja.
As opções dos setores do formulário começam vazias. O admin cria as opções padrão e cada loja pode editar as próprias opções.

## Configuração no Supabase

1. Abra o Supabase Dashboard do projeto.
2. Vá em `SQL Editor`.
3. Rode todo o arquivo `supabase/schema.sql`.
4. No Supabase Auth, deixe `Email` habilitado em `Authentication > Providers`.
5. Em `Authentication > Providers > Email`, desligue confirmação obrigatória de email. O sistema usa nick na tela e um email técnico interno no formato `nick@leadcontrol.local`.

## Rodar o sistema

Inicie pelo servidor Node, não abrindo o HTML direto. A chave `service_role` fica só no servidor:

```bash
SUPABASE_SERVICE_ROLE_KEY="SUA_SERVICE_ROLE_KEY" node server.js
```

Depois abra:

```txt
http://localhost:5173
```

## Fluxo de uso

1. Abra `index.html`.
2. Clique em `Criar admin` e crie o primeiro cadastro com nick e senha.
3. Entre como admin.
4. Cadastre as opções padrão que as novas lojas devem receber.
5. Crie as lojas com nick e senha.
6. Cada loja entra com o próprio login, vê apenas os leads dela e pode editar as próprias opções.

## Segurança

A chave `anon public` fica no frontend. A `service_role` nunca deve ser colocada em `index.html` ou `app.js`; ela deve ficar apenas em variável de ambiente no servidor Node.
