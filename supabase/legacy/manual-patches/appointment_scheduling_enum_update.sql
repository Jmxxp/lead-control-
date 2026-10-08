-- PASSO 1/2
-- Rode este arquivo sozinho no SQL Editor do Supabase.
-- Depois que ele terminar, rode appointment_scheduling_update.sql.

set search_path = public, extensions;

alter type public.lead_option_group add value if not exists 'scheduled' before 'visited';
