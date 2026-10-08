# Bootstrap manual histórico

Estes arquivos existem porque o banco nasceu antes do histórico atual de
migrations. Eles não são carregados automaticamente pelo Supabase CLI.

Ordem em que o baseline foi composto historicamente:

1. `database.sql`
2. `modules/prospection_configuration_batch_update.sql`
3. `modules/prospection_backup_import_update.sql`
4. `modules/attendance_module.sql`

Esta lista é inventário, não um procedimento de instalação. A sequência não
representa o estado atual, e as migrations posteriores pressupõem objetos que
já existiam quando foram criadas. O projeto ainda não possui um bootstrap limpo
e reproduzível validado a partir destes arquivos.

Para criar um ambiente novo, gere primeiro um baseline atual a partir de um
banco conhecido, valide-o em banco vazio e execute todos os testes SQL. Nunca
execute arquivos de `bootstrap/` ou `legacy/` sobre o projeto atual.
