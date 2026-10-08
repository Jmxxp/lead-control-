# SQL legado

Arquivos desta pasta não são fonte de verdade do schema atual e não participam
do deploy automático.

- `manual-patches/` preserva atualizações históricas para auditoria e recuperação
  de bancos antigos.
- `destructive/` contém operações com perda intencional de dados.

Não execute esses arquivos no projeto atual sem comparar o contrato com
`../migrations/`, gerar backup e validar o plano de reversão.
