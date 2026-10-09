# Testes manuais de integração SQL

Estes testes não são executados automaticamente pela CI. Os arquivos que criam
fixtures são transacionais e encerram com `ROLLBACK`, mas devem ser executados
preferencialmente em ambiente local ou de staging com o schema atual. Alguns
cenários de Prospecções também exigem pelo menos um Admin ativo.

Exemplo:

```bash
supabase db query --local --file tests/sql/attendance-multiple-orders-cancellation.sql
```

Os dois testes de Prospecções que antes ficavam na raiz também estão aqui:

- `prospection-configuration-batch.sql`
- `prospection-backup-import.sql`

Em 8 de outubro de 2026, ambos passaram no projeto vinculado e as fixtures foram
revertidas pelo `ROLLBACK` final.

Novos testes de banco devem permanecer nesta pasta; migrations pertencem somente
a `supabase/migrations/`.

`good-morning-included-in-attendance.sql` valida a inclusão do Bom Dia Vendedor
em Atendimentos após a migration de inclusão: ausência de cota própria, contagem
única de módulos adicionais, compatibilidade das RPCs, trocas de módulos após
downgrade e isolamento de cotas entre agências. O cenário encerra com `ROLLBACK`.
