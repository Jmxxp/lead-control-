-- PASSO 1/2
-- Rode primeiro este bloco no SQL Editor.

set search_path = public, extensions;

alter table public.leads add column if not exists contact_date date;

update public.leads
set contact_date = coalesce(contact_date, (timezone('America/Sao_Paulo', created_at))::date, (timezone('America/Sao_Paulo', now()))::date)
where contact_date is null;

alter table public.leads alter column contact_date set default ((timezone('America/Sao_Paulo', now()))::date);
alter table public.leads alter column contact_date set not null;

create index if not exists leads_admin_contact_date_idx on public.leads (admin_user_id, contact_date desc, created_at desc);
create index if not exists leads_store_contact_date_idx on public.leads (store_id, contact_date desc, created_at desc);
