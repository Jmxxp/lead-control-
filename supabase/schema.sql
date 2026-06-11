create extension if not exists pgcrypto;

create schema if not exists app_private;

create table if not exists public.stores (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  username text unique,
  email text not null unique,
  auth_user_id uuid unique references auth.users(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  username text unique,
  role text not null check (role in ('admin', 'store')),
  store_id uuid references public.stores(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  name text not null,
  phone text not null,
  channel text not null,
  campaign text not null,
  conversation_start text not null,
  conclusion text not null,
  visited text not null,
  bought text,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.stores add column if not exists username text;
update public.stores
set username = split_part(email, '@', 1)
where username is null or username = '';

alter table public.profiles add column if not exists username text;
update public.profiles
set username = split_part(email, '@', 1)
where username is null or username = '';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'stores_username_key'
  ) then
    alter table public.stores add constraint stores_username_key unique (username);
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'profiles_username_key'
  ) then
    alter table public.profiles add constraint profiles_username_key unique (username);
  end if;
end;
$$;

create or replace function app_private.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists stores_set_updated_at on public.stores;
create trigger stores_set_updated_at
before update on public.stores
for each row execute function app_private.set_updated_at();

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function app_private.set_updated_at();

drop trigger if exists leads_set_updated_at on public.leads;
create trigger leads_set_updated_at
before update on public.leads
for each row execute function app_private.set_updated_at();

create or replace function app_private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth, app_private
as $$
declare
  user_role text := coalesce(new.raw_app_meta_data->>'role', 'admin');
  linked_store_id uuid := nullif(new.raw_app_meta_data->>'store_id', '')::uuid;
  user_name text := coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1));
begin
  insert into public.profiles (id, email, username, role, store_id)
  values (
    new.id,
    coalesce(new.email, ''),
    user_name,
    case when user_role = 'store' then 'store' else 'admin' end,
    linked_store_id
  )
  on conflict (id) do update
  set
    email = excluded.email,
    username = excluded.username,
    role = excluded.role,
    store_id = excluded.store_id;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function app_private.handle_new_user();

create or replace function app_private.current_role()
returns text
language sql
security definer
set search_path = public, auth, app_private
stable
as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function app_private.current_store_id()
returns uuid
language sql
security definer
set search_path = public, auth, app_private
stable
as $$
  select store_id from public.profiles where id = auth.uid();
$$;

create or replace function app_private.is_admin()
returns boolean
language sql
security definer
set search_path = public, auth, app_private
stable
as $$
  select coalesce(app_private.current_role() = 'admin', false);
$$;

grant usage on schema app_private to authenticated;
grant execute on all functions in schema app_private to authenticated;

alter table public.profiles enable row level security;
alter table public.stores enable row level security;
alter table public.leads enable row level security;

drop policy if exists "profiles_select_own_or_admin" on public.profiles;
create policy "profiles_select_own_or_admin"
on public.profiles
for select
to authenticated
using (id = auth.uid() or app_private.is_admin());

drop policy if exists "stores_select_own_or_admin" on public.stores;
create policy "stores_select_own_or_admin"
on public.stores
for select
to authenticated
using (app_private.is_admin() or id = app_private.current_store_id());

drop policy if exists "stores_insert_admin" on public.stores;
create policy "stores_insert_admin"
on public.stores
for insert
to authenticated
with check (app_private.is_admin());

drop policy if exists "stores_update_admin" on public.stores;
create policy "stores_update_admin"
on public.stores
for update
to authenticated
using (app_private.is_admin())
with check (app_private.is_admin());

drop policy if exists "leads_select_store_or_admin" on public.leads;
create policy "leads_select_store_or_admin"
on public.leads
for select
to authenticated
using (app_private.is_admin() or store_id = app_private.current_store_id());

drop policy if exists "leads_insert_store_or_admin" on public.leads;
create policy "leads_insert_store_or_admin"
on public.leads
for insert
to authenticated
with check (app_private.is_admin() or store_id = app_private.current_store_id());

drop policy if exists "leads_update_store_or_admin" on public.leads;
create policy "leads_update_store_or_admin"
on public.leads
for update
to authenticated
using (app_private.is_admin() or store_id = app_private.current_store_id())
with check (app_private.is_admin() or store_id = app_private.current_store_id());

drop policy if exists "leads_delete_store_or_admin" on public.leads;
create policy "leads_delete_store_or_admin"
on public.leads
for delete
to authenticated
using (app_private.is_admin() or store_id = app_private.current_store_id());

grant usage on schema public to anon, authenticated;
grant select on public.profiles to authenticated;
grant select, insert, update on public.stores to authenticated;
grant select, insert, update, delete on public.leads to authenticated;
