-- PASSO 1/2
-- Rode este arquivo primeiro no SQL Editor do Supabase.
-- Depois que ele terminar com sucesso, rode technician_role_step2.sql.

set search_path = public, extensions;

alter type public.app_user_role add value if not exists 'technician';

alter table public.app_users
  drop constraint if exists app_users_role_scope_check;

alter table public.app_users
  add constraint app_users_role_scope_check check (
    (role::text = 'admin' and admin_user_id is null and store_id is null)
    or
    (role::text = 'technician' and admin_user_id is not null and store_id is null)
    or
    (role::text = 'store' and admin_user_id is not null and store_id is not null)
  );

create index if not exists app_users_admin_role_active_idx
  on public.app_users (admin_user_id, role, is_active);
