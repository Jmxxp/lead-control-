# Banco de dados

Esta pasta separa o SQL por finalidade. Apenas `migrations/` participa do fluxo
automático do Supabase CLI.

## Estrutura

- `migrations/`: histórico oficial versionado. Confirme a aplicação em cada
  ambiente com `supabase migration list --linked`. Depois de aplicado, um
  arquivo é imutável: não renomeie, não mova, não apague e não altere. Toda
  mudança nova deve nascer com `supabase migration new <nome>`.
- `bootstrap/`: baseline manual histórico e módulos que existiam antes da cadeia
  atual de migrations. Não é executado automaticamente e não deve ser reaplicado
  em um banco existente.
- `legacy/manual-patches/`: correções antigas preservadas para auditoria ou para
  atualização controlada de bancos legados. Elas podem rebaixar contratos atuais
  se forem executadas fora de ordem.
- `legacy/destructive/`: operações antigas e destrutivas. Exigem backup e revisão
  explícita antes de qualquer execução.
- `functions/`: Edge Functions publicadas separadamente do schema.

Os testes SQL ficam em `../tests/sql/` e terminam em `ROLLBACK` quando criam dados.

## Política do projeto

1. Mudanças novas entram somente como uma nova migration.
2. A migration é testada antes do `db push`.
3. O histórico local e remoto deve permanecer alinhado em
   `supabase migration list --linked`.
4. Scripts de `bootstrap/` e `legacy/` nunca substituem migrations novas.

Não consolide a cadeia atual em um único arquivo sem um projeto específico de
baseline. O squash padrão omite operações de dados e outros objetos operacionais,
enquanto este projeto possui backfills, cron e contratos que precisam de revisão
manual.
