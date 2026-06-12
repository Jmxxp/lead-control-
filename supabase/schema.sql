-- RESET TOTAL DO APP
-- Rode este arquivo inteiro no Supabase SQL Editor.
-- Ele apaga usuários Auth, tabelas, políticas, funções e recria tudo do zero.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
alter extension pgcrypto set schema extensions;

create schema if not exists app_private;

drop trigger if exists on_auth_user_created on auth.users;
drop function if exists app_private.handle_new_user();

delete from auth.users;

drop function if exists public.app_logout();
drop function if exists public.app_create_store(text, text, text);
drop function if exists public.app_create_admin(text, text, text);
drop function if exists public.app_login(text, text);
drop function if exists public.app_current_profile();

drop function if exists app_private.is_admin() cascade;
drop function if exists app_private.current_store_id() cascade;
drop function if exists app_private.current_role() cascade;
drop function if exists app_private.current_app_user_id() cascade;
drop function if exists app_private.set_updated_at() cascade;

drop table if exists public.lead_options cascade;
drop table if exists public.leads cascade;
drop table if exists public.app_user_sessions cascade;
drop table if exists public.app_users cascade;
drop table if exists public.profiles cascade;
drop table if exists public.stores cascade;

create table public.stores (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  username text not null unique check (username = lower(username) and username ~ '^[a-z0-9._-]+$'),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.app_users (
  id uuid primary key default gen_random_uuid(),
  username text not null unique check (username = lower(username) and username ~ '^[a-z0-9._-]+$'),
  password_hash text not null,
  full_name text not null default '',
  role text not null check (role in ('admin', 'store')),
  store_id uuid references public.stores(id) on delete cascade,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (role = 'admin' and store_id is null)
    or (role = 'store' and store_id is not null)
  )
);

create table public.app_user_sessions (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  app_user_id uuid not null references public.app_users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.leads (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  name text not null,
  phone text not null,
  channel text not null,
  campaign text not null,
  conversation_start text not null,
  conclusion text not null,
  visited text,
  bought text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.lead_options (
  id uuid primary key default gen_random_uuid(),
  store_id uuid references public.stores(id) on delete cascade,
  group_key text not null check (
    group_key in ('channel', 'campaign', 'conversationStart', 'conclusion', 'visited', 'bought')
  ),
  value text not null check (btrim(value) <> ''),
  sort_order integer not null default 0,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index lead_options_default_unique
on public.lead_options (group_key, lower(value))
where store_id is null;

create unique index lead_options_store_unique
on public.lead_options (store_id, group_key, lower(value))
where store_id is not null;

alter table public.stores replica identity full;
alter table public.leads replica identity full;
alter table public.lead_options replica identity full;

alter publication supabase_realtime add table public.stores;
alter publication supabase_realtime add table public.leads;
alter publication supabase_realtime add table public.lead_options;

create or replace function app_private.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger stores_set_updated_at
before update on public.stores
for each row execute function app_private.set_updated_at();

create trigger app_users_set_updated_at
before update on public.app_users
for each row execute function app_private.set_updated_at();

create trigger app_user_sessions_set_updated_at
before update on public.app_user_sessions
for each row execute function app_private.set_updated_at();

create trigger leads_set_updated_at
before update on public.leads
for each row execute function app_private.set_updated_at();

create trigger lead_options_set_updated_at
before update on public.lead_options
for each row execute function app_private.set_updated_at();

create or replace function app_private.current_app_user_id()
returns uuid
language sql
security definer
set search_path = public, app_private
stable
as $$
  select app_user_id
  from public.app_user_sessions
  where auth_user_id = auth.uid();
$$;

create or replace function app_private.current_role()
returns text
language sql
security definer
set search_path = public, app_private
stable
as $$
  select role
  from public.app_users
  where id = app_private.current_app_user_id();
$$;

create or replace function app_private.current_store_id()
returns uuid
language sql
security definer
set search_path = public, app_private
stable
as $$
  select store_id
  from public.app_users
  where id = app_private.current_app_user_id();
$$;

create or replace function app_private.is_admin()
returns boolean
language sql
security definer
set search_path = public, app_private
stable
as $$
  select coalesce(app_private.current_role() = 'admin', false);
$$;

create or replace function public.app_current_profile()
returns jsonb
language sql
security definer
set search_path = public, app_private
stable
as $$
  select jsonb_build_object(
    'id', users.id,
    'username', users.username,
    'role', users.role,
    'store_id', users.store_id,
    'store_name', coalesce(stores.name, '')
  )
  from public.app_users users
  left join public.stores stores on stores.id = users.store_id
  where users.id = app_private.current_app_user_id();
$$;

create or replace function public.app_login(login_username text, login_password text)
returns jsonb
language plpgsql
security definer
set search_path = public, app_private, extensions
as $$
declare
  matched_user public.app_users;
begin
  if auth.uid() is null then
    raise exception 'Sessão anônima obrigatória.';
  end if;

  select *
  into matched_user
  from public.app_users
  where username = lower(btrim(login_username))
    and password_hash = extensions.crypt(login_password, password_hash);

  if matched_user.id is null then
    raise exception 'Nick ou senha inválidos.';
  end if;

  insert into public.app_user_sessions (auth_user_id, app_user_id)
  values (auth.uid(), matched_user.id)
  on conflict (auth_user_id) do update
  set app_user_id = excluded.app_user_id,
      updated_at = now();

  return public.app_current_profile();
end;
$$;

create or replace function public.app_create_admin(admin_name text, admin_username text, admin_password text)
returns jsonb
language plpgsql
security definer
set search_path = public, app_private, extensions
as $$
declare
  created_user public.app_users;
begin
  if auth.uid() is null then
    raise exception 'Sessão anônima obrigatória.';
  end if;

  if exists (select 1 from public.app_users where role = 'admin') then
    raise exception 'Admin já existe.';
  end if;

  insert into public.app_users (username, password_hash, full_name, role)
  values (
    lower(btrim(admin_username)),
    extensions.crypt(admin_password, extensions.gen_salt('bf')),
    coalesce(nullif(btrim(admin_name), ''), lower(btrim(admin_username))),
    'admin'
  )
  returning * into created_user;

  insert into public.app_user_sessions (auth_user_id, app_user_id)
  values (auth.uid(), created_user.id)
  on conflict (auth_user_id) do update
  set app_user_id = excluded.app_user_id,
      updated_at = now();

  return public.app_current_profile();
end;
$$;

create or replace function public.app_create_store(store_name text, store_username text, store_password text)
returns jsonb
language plpgsql
security definer
set search_path = public, app_private, extensions
as $$
declare
  created_store public.stores;
begin
  if not app_private.is_admin() then
    raise exception 'Apenas admin pode criar lojas.';
  end if;

  insert into public.stores (name, username, created_by)
  values (btrim(store_name), lower(btrim(store_username)), app_private.current_app_user_id())
  returning * into created_store;

  insert into public.app_users (username, password_hash, full_name, role, store_id, created_by)
  values (
    lower(btrim(store_username)),
    extensions.crypt(store_password, extensions.gen_salt('bf')),
    btrim(store_name),
    'store',
    created_store.id,
    app_private.current_app_user_id()
  );

  return to_jsonb(created_store);
end;
$$;

create or replace function public.app_logout()
returns void
language sql
security definer
set search_path = public, app_private
as $$
  delete from public.app_user_sessions
  where auth_user_id = auth.uid();
$$;

alter table public.app_users enable row level security;
alter table public.app_user_sessions enable row level security;
alter table public.stores enable row level security;
alter table public.leads enable row level security;
alter table public.lead_options enable row level security;

create policy app_users_select_own_or_admin
on public.app_users
for select
to authenticated
using (id = app_private.current_app_user_id() or app_private.is_admin());

create policy app_user_sessions_select_own
on public.app_user_sessions
for select
to authenticated
using (auth_user_id = auth.uid());

create policy stores_select_store_or_admin
on public.stores
for select
to authenticated
using (app_private.is_admin() or id = app_private.current_store_id());

create policy stores_insert_admin
on public.stores
for insert
to authenticated
with check (app_private.is_admin());

create policy stores_update_admin
on public.stores
for update
to authenticated
using (app_private.is_admin())
with check (app_private.is_admin());

create policy leads_select_store_or_admin
on public.leads
for select
to authenticated
using (app_private.is_admin() or store_id = app_private.current_store_id());

create policy leads_insert_store_or_admin
on public.leads
for insert
to authenticated
with check (app_private.is_admin() or store_id = app_private.current_store_id());

create policy leads_update_store_or_admin
on public.leads
for update
to authenticated
using (app_private.is_admin() or store_id = app_private.current_store_id())
with check (app_private.is_admin() or store_id = app_private.current_store_id());

create policy leads_delete_store_or_admin
on public.leads
for delete
to authenticated
using (app_private.is_admin() or store_id = app_private.current_store_id());

create policy lead_options_select_store_or_admin
on public.lead_options
for select
to authenticated
using (
  app_private.is_admin()
  or store_id is null
  or store_id = app_private.current_store_id()
);

create policy lead_options_insert_store_or_admin
on public.lead_options
for insert
to authenticated
with check (
  app_private.is_admin()
  or store_id = app_private.current_store_id()
);

create policy lead_options_update_store_or_admin
on public.lead_options
for update
to authenticated
using (
  app_private.is_admin()
  or store_id = app_private.current_store_id()
)
with check (
  app_private.is_admin()
  or store_id = app_private.current_store_id()
);

create policy lead_options_delete_store_or_admin
on public.lead_options
for delete
to authenticated
using (
  app_private.is_admin()
  or store_id = app_private.current_store_id()
);

grant usage on schema public to anon, authenticated;
grant usage on schema app_private to authenticated;

revoke all on public.app_users from anon, authenticated;
revoke all on public.app_user_sessions from anon, authenticated;

grant execute on function public.app_current_profile() to authenticated;
grant execute on function public.app_login(text, text) to authenticated;
grant execute on function public.app_create_admin(text, text, text) to authenticated;
grant execute on function public.app_create_store(text, text, text) to authenticated;
grant execute on function public.app_logout() to authenticated;

grant select, insert, update on public.stores to authenticated;
grant select, insert, update, delete on public.leads to authenticated;
grant select, insert, update, delete on public.lead_options to authenticated;

notify pgrst, 'reload schema';
