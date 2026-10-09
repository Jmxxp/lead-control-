# Bom Dia Vendedor — dias sem expediente

O calendário de dias sem expediente faz parte da mesma configuração de meta, divisão e fila. Admin e a própria loja podem editar; Agência permanece somente leitura.

O Bom Dia Vendedor integra a licença de módulos adicionais e fica disponível quando Atendimentos está ativo. Não possui cota nem licença separadas. Essa regra exige a migration de inclusão e o contrato de acesso v3; em bancos anteriores, a disponibilidade legada continua sendo respeitada até a atualização.

## Contrato do frontend

- O workspace informa `closed_days_configuration_available: true` somente quando a RPC atômica v2 está instalada.
- `closed_days` é um array ordenado de `{ date: "YYYY-MM-DD", reason: "texto" }`.
- A gravação usa `lc_save_good_morning_seller_settings_v2` com `p_closed_days` junto de meta e alocações.
- Se a capability ainda estiver ausente, o calendário fica bloqueado e o frontend usa a RPC v1 apenas para meta e fila; a RPC v1 deve preservar os dias já cadastrados.
- Se a capability estiver ativa e a RPC v2 falhar ou estiver ausente, não há fallback para v1. Assim, nenhuma parte da configuração é salva separadamente.

## Regras

- Somente datas do mês corrente retornado pelo servidor.
- Segunda-feira a sábado; domingo já é excluído automaticamente.
- Datas únicas, no máximo 31 entradas.
- Motivo opcional, com até 160 caracteres; vazio é normalizado para `Sem expediente`.
- Uma data fechada sai de todos os contadores de dias usados nas metas mensal, semanal e diária.
- Atendimentos e vendas feitos nessa data continuam registrados e somados normalmente; o bloqueio altera somente o calendário de metas.

## Verificação local

```sh
node --test tests/frontend/attendances-closed-days.test.js
node --check assets/js/attendances.js
git diff --check
```
