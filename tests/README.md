# Testes

Execute os comandos a partir da raiz do projeto.

| Pasta | Finalidade |
| --- | --- |
| `frontend/` | Testes Node de Atendimentos, Prospecções, realtime e PWA. |
| [sql/](sql/README.md) | Cenários de integração SQL e instruções de execução. |

## Frontend

A suíte usa o runner nativo do Node e não requer instalação de pacotes npm.

No PowerShell:

```powershell
$scripts = @((Get-ChildItem assets/js -Filter '*.js').FullName) + @('service-worker.js')
foreach ($script in $scripts) {
    node --check $script
    if ($LASTEXITCODE -ne 0) { throw "Falha de sintaxe em $script" }
}
node --test (Get-ChildItem tests/frontend -Filter '*.test.js').FullName
git diff --check
```

Em Bash:

```bash
for file in assets/js/*.js service-worker.js; do node --check "$file" || exit; done
node --test tests/frontend/*.test.js
git diff --check
```

Para executar somente um arquivo:

```sh
node --test tests/frontend/attendances-closed-days.test.js
```

Use o caminho explícito `tests/frontend/` ao executar a suíte Node. Os testes das Edge Functions em `supabase/functions/` usam Deno; os comandos correspondentes estão na [documentação completa](../docs/DOCUMENTACAO_COMPLETA_PROJETO.md).

## Banco

Os cenários SQL são executados separadamente, em ambiente local ou de staging, seguindo o [guia SQL](sql/README.md). Eles não são executados pelo runner do Node.
