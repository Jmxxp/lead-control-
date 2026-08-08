-- Controle de Leads | Otica
-- Banco alvo: Supabase/PostgreSQL.
-- Rode este arquivo no SQL Editor de um projeto Supabase novo/limpo.
-- IMPORTANTE: em um banco existente, NAO execute o arquivo inteiro.
-- Execute somente a secao "ATUALIZACAO INCREMENTAL: PROSPECCOES" ate o final.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
set search_path = public, extensions;

create schema if not exists app_private;

-- O administrador e provisionado somente por comando manual no banco.
drop function if exists public.lc_create_admin(text, text, text);
drop function if exists app_private.rpc_create_admin(text, text, text);

do $$
begin
  if not exists (select 1 from pg_type where typname = 'app_user_role') then
    create type public.app_user_role as enum ('admin', 'technician', 'store');
  end if;

  if not exists (select 1 from pg_type where typname = 'lead_option_group') then
    create type public.lead_option_group as enum (
      'channel',
      'campaign',
      'conversationStart',
      'conclusion',
      'scheduled',
      'visited',
      'bought'
    );
  end if;
end $$;

alter type public.app_user_role add value if not exists 'technician' before 'store';

create or replace function app_private.normalize_nick(value text)
returns text
language sql
immutable
as $$
  select lower(regexp_replace(btrim(coalesce(value, '')), '[[:space:]]+', '-', 'g'));
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

create or replace function app_private.set_nick_key()
returns trigger
language plpgsql
as $$
begin
  new.nick_key = app_private.normalize_nick(new.nick);

  if new.nick_key = '' then
    raise exception 'Nick invalido.';
  end if;

  return new;
end;
$$;

create table if not exists public.app_users (
  id uuid primary key default gen_random_uuid(),
  nick text not null,
  nick_key text not null unique,
  password_hash text not null,
  full_name text not null check (length(btrim(full_name)) > 0),
  role public.app_user_role not null,
  admin_user_id uuid references public.app_users(id) on delete cascade,
  store_id uuid,
  is_active boolean not null default true,
  last_login_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint app_users_role_scope_check check (
    (role = 'admin' and admin_user_id is null and store_id is null)
    or
    (role = 'technician' and admin_user_id is not null and store_id is null)
    or
    (role = 'store' and admin_user_id is not null and store_id is not null)
  )
);

alter table public.app_users drop constraint if exists app_users_role_scope_check;
alter table public.app_users
  add constraint app_users_role_scope_check check (
    (role::text = 'admin' and admin_user_id is null and store_id is null)
    or
    (role::text = 'technician' and admin_user_id is not null and store_id is null)
    or
    (role::text = 'store' and admin_user_id is not null and store_id is not null)
  );

create table if not exists public.stores (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  technician_user_id uuid references public.app_users(id) on delete set null,
  name text not null check (length(btrim(name)) > 0),
  nick text not null,
  nick_key text not null unique,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint stores_admin_unique unique (id, admin_user_id)
);

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'app_users_store_admin_fk'
      and conrelid = 'public.app_users'::regclass
  ) then
    alter table public.app_users
      add constraint app_users_store_admin_fk
      foreign key (store_id, admin_user_id)
      references public.stores(id, admin_user_id)
      on delete cascade;
  end if;
end $$;

create table if not exists public.app_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.app_users(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_seen_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.lead_options (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  group_key public.lead_option_group not null,
  value text not null check (length(btrim(value)) > 0),
  sort_order integer not null default 0,
  fixed boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lead_options_yes_no_check check (
    group_key not in ('scheduled', 'visited', 'bought') or value in ('Sim', 'Não')
  ),
  constraint lead_options_unique_value unique (admin_user_id, group_key, value)
);

create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  name text not null check (length(btrim(name)) > 0),
  phone text not null check (length(btrim(phone)) > 0),
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  scheduled text check (scheduled is null or scheduled in ('Sim', 'Não')),
  scheduled_visit_date date,
  scheduled_visit_time time,
  visited text check (visited is null or visited in ('Sim', 'Não')),
  bought text check (bought is null or bought in ('Sim', 'Não')),
  purchase_amount numeric(12,2) check (purchase_amount is null or purchase_amount > 0),
  service_order text,
  notes text,
  created_by uuid references public.app_users(id) on delete set null,
  updated_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint leads_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

alter table public.leads
  add column if not exists purchase_amount numeric(12,2) check (purchase_amount is null or purchase_amount > 0);

alter table public.leads
  add column if not exists service_order text;

alter table public.leads
  add column if not exists notes text;

alter table public.leads
  add column if not exists scheduled text check (scheduled is null or scheduled in ('Sim', 'Não'));

alter table public.leads
  add column if not exists scheduled_visit_date date;

alter table public.leads
  add column if not exists scheduled_visit_time time;

create unique index if not exists app_users_one_store_user_idx
  on public.app_users (store_id)
  where role = 'store' and is_active;

create unique index if not exists app_users_single_admin_idx
  on public.app_users (role)
  where role = 'admin';

create index if not exists app_users_admin_user_id_idx on public.app_users(admin_user_id);
create index if not exists app_sessions_user_id_idx on public.app_sessions(user_id);
create index if not exists app_sessions_expires_at_idx on public.app_sessions(expires_at);
create index if not exists stores_admin_created_idx on public.stores(admin_user_id, created_at desc);
create index if not exists lead_options_admin_group_sort_idx on public.lead_options(admin_user_id, group_key, sort_order);
create index if not exists leads_admin_created_idx on public.leads(admin_user_id, created_at desc);
create index if not exists leads_store_created_idx on public.leads(store_id, created_at desc);
create index if not exists leads_channel_idx on public.leads(channel);
create index if not exists leads_campaign_idx on public.leads(campaign);
create index if not exists leads_conversation_start_idx on public.leads(conversation_start);
create index if not exists leads_conclusion_idx on public.leads(conclusion);
create index if not exists leads_visited_idx on public.leads(visited);
create index if not exists leads_scheduled_idx on public.leads(scheduled);
create index if not exists leads_bought_idx on public.leads(bought);

drop trigger if exists app_users_set_nick_key on public.app_users;
create trigger app_users_set_nick_key
before insert or update of nick on public.app_users
for each row execute function app_private.set_nick_key();

drop trigger if exists stores_set_nick_key on public.stores;
create trigger stores_set_nick_key
before insert or update of nick on public.stores
for each row execute function app_private.set_nick_key();

drop trigger if exists app_users_set_updated_at on public.app_users;
create trigger app_users_set_updated_at
before update on public.app_users
for each row execute function app_private.set_updated_at();

drop trigger if exists stores_set_updated_at on public.stores;
create trigger stores_set_updated_at
before update on public.stores
for each row execute function app_private.set_updated_at();

drop trigger if exists lead_options_set_updated_at on public.lead_options;
create trigger lead_options_set_updated_at
before update on public.lead_options
for each row execute function app_private.set_updated_at();

drop trigger if exists leads_set_updated_at on public.leads;
create trigger leads_set_updated_at
before update on public.leads
for each row execute function app_private.set_updated_at();

alter table public.app_users enable row level security;
alter table public.stores enable row level security;
alter table public.app_sessions enable row level security;
alter table public.lead_options enable row level security;
alter table public.leads enable row level security;

create or replace function app_private.seed_default_options(p_admin_user_id uuid)
returns void
language sql
security definer
set search_path = app_private, public, extensions
as $$
  insert into public.lead_options (admin_user_id, group_key, value, sort_order, fixed)
  values
    (p_admin_user_id, 'channel', 'WhatsApp', 10, false),
    (p_admin_user_id, 'channel', 'Instagram', 20, true),
    (p_admin_user_id, 'channel', 'Facebook', 30, true),
    (p_admin_user_id, 'channel', 'Ligação', 40, false),
    (p_admin_user_id, 'campaign', 'Orgânico', 10, false),
    (p_admin_user_id, 'campaign', 'Anúncio', 20, false),
    (p_admin_user_id, 'campaign', 'Indicação', 30, false),
    (p_admin_user_id, 'conversationStart', 'Preço', 10, false),
    (p_admin_user_id, 'conversationStart', 'Consulta', 20, false),
    (p_admin_user_id, 'conversationStart', 'Armação', 30, false),
    (p_admin_user_id, 'conversationStart', 'Lente', 40, false),
    (p_admin_user_id, 'conclusion', 'Aguardando', 10, false),
    (p_admin_user_id, 'conclusion', 'Retornar', 20, false),
    (p_admin_user_id, 'conclusion', 'Finalizado', 30, false),
    (p_admin_user_id, 'scheduled', 'Sim', 10, true),
    (p_admin_user_id, 'scheduled', 'Não', 20, true),
    (p_admin_user_id, 'visited', 'Sim', 10, true),
    (p_admin_user_id, 'visited', 'Não', 20, true),
    (p_admin_user_id, 'bought', 'Sim', 10, true),
    (p_admin_user_id, 'bought', 'Não', 20, true)
  on conflict (admin_user_id, group_key, value) do update
  set
    sort_order = excluded.sort_order,
    fixed = excluded.fixed,
    is_active = true;
$$;

update public.lead_options
set fixed = true
where group_key = 'channel'
  and value in ('Instagram', 'Facebook')
  and fixed = false;

create or replace function app_private.session_user(p_session_token text)
returns table (
  user_id uuid,
  admin_user_id uuid,
  user_role public.app_user_role,
  user_store_id uuid
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_token_hash text;
begin
  if coalesce(p_session_token, '') = '' then
    raise exception 'Sessao obrigatoria.' using errcode = '28000';
  end if;

  v_token_hash := encode(digest(p_session_token, 'sha256'), 'hex');

  return query
  select
    u.id,
    coalesce(u.admin_user_id, u.id),
    u.role,
    u.store_id
  from public.app_sessions s
  join public.app_users u on u.id = s.user_id
  left join public.stores st on st.id = u.store_id
  where s.token_hash = v_token_hash
    and s.revoked_at is null
    and s.expires_at > now()
    and u.is_active = true
    and (
      u.role in ('admin', 'technician')
      or (st.id is not null and st.is_active = true)
    )
  limit 1;

  if not found then
    raise exception 'Sessao invalida ou expirada.' using errcode = '28000';
  end if;

  update public.app_sessions
  set last_seen_at = now()
  where token_hash = v_token_hash;
end;
$$;

create or replace function app_private.create_session_result(p_user_id uuid)
returns table (
  session_token text,
  expires_at timestamptz,
  user_id uuid,
  admin_id uuid,
  nick text,
  full_name text,
  role public.app_user_role,
  store_id uuid,
  store_name text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_raw_token text;
  v_expires_at timestamptz;
begin
  v_raw_token := encode(gen_random_bytes(32), 'hex');
  v_expires_at := now() + interval '30 days';

  insert into public.app_sessions (user_id, token_hash, expires_at)
  values (p_user_id, encode(digest(v_raw_token, 'sha256'), 'hex'), v_expires_at);

  update public.app_users
  set last_login_at = now()
  where id = p_user_id;

  return query
  select
    v_raw_token,
    v_expires_at,
    u.id,
    coalesce(u.admin_user_id, u.id),
    u.nick_key,
    u.full_name,
    u.role,
    u.store_id,
    st.name
  from public.app_users u
  left join public.stores st on st.id = u.store_id
  where u.id = p_user_id;
end;
$$;

create or replace function app_private.profile_result(p_session_token text)
returns table (
  user_id uuid,
  admin_id uuid,
  nick text,
  full_name text,
  role public.app_user_role,
  store_id uuid,
  store_name text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select
    u.id,
    v_session.admin_user_id,
    u.nick_key,
    u.full_name,
    u.role,
    u.store_id,
    st.name
  from public.app_users u
  left join public.stores st on st.id = u.store_id
  where u.id = v_session.user_id;
end;
$$;

create or replace function app_private.rpc_login(p_nick text, p_password text)
returns table (
  session_token text,
  expires_at timestamptz,
  user_id uuid,
  admin_id uuid,
  nick text,
  full_name text,
  role public.app_user_role,
  store_id uuid,
  store_name text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_user public.app_users;
begin
  select u.*
  into v_user
  from public.app_users u
  left join public.stores st on st.id = u.store_id
  where u.nick_key = app_private.normalize_nick(p_nick)
    and u.is_active = true
    and (
      u.role in ('admin', 'technician')
      or (st.id is not null and st.is_active = true)
    );

  if not found or v_user.password_hash <> crypt(coalesce(p_password, ''), v_user.password_hash) then
    raise exception 'Nick ou senha invalidos.' using errcode = '28000';
  end if;

  return query select * from app_private.create_session_result(v_user.id);
end;
$$;

create or replace function app_private.rpc_logout(p_session_token text)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
begin
  update public.app_sessions
  set revoked_at = now()
  where token_hash = encode(digest(p_session_token, 'sha256'), 'hex')
    and revoked_at is null;

  return true;
end;
$$;

create or replace function app_private.rpc_create_store(
  p_session_token text,
  p_name text,
  p_nick text,
  p_password text
)
returns table (
  store_id uuid,
  store_name text,
  store_nick text,
  user_id uuid,
  user_nick text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_user_id uuid;
  v_nick_key text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role <> 'admin' then
    raise exception 'Apenas admin pode criar loja.';
  end if;

  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'Digite o nome da loja.';
  end if;

  if length(coalesce(p_password, '')) < 6 then
    raise exception 'A senha da loja precisa ter pelo menos 6 caracteres.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);

  if v_nick_key = '' then
    raise exception 'Digite um nick valido para a loja.';
  end if;

  if exists (select 1 from public.app_users where nick_key = v_nick_key) then
    raise exception 'Esse nick ja existe.';
  end if;

  insert into public.stores (admin_user_id, name, nick)
  values (v_session.admin_user_id, btrim(p_name), p_nick)
  returning id into v_store_id;

  insert into public.app_users (nick, password_hash, full_name, role, admin_user_id, store_id)
  values (
    p_nick,
    crypt(p_password, gen_salt('bf')),
    btrim(p_name),
    'store',
    v_session.admin_user_id,
    v_store_id
  )
  returning id into v_user_id;

  return query
  select st.id, st.name, st.nick_key, u.id, u.nick_key
  from public.stores st
  join public.app_users u on u.store_id = st.id
  where st.id = v_store_id;
end;
$$;

-- Compatibilidade ao executar acidentalmente este arquivo em uma instalacao
-- que ja recebeu a hierarquia B2B. O wrapper publico depende da funcao privada,
-- por isso precisa ser removido primeiro.
drop function if exists public.lc_list_stores(text);
drop function if exists app_private.rpc_list_stores(text);

create or replace function app_private.rpc_list_stores(p_session_token text)
returns table (
  id uuid,
  name text,
  nick text,
  created_at timestamptz,
  leads_count bigint,
  sales_count bigint
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select
    st.id,
    st.name,
    st.nick_key,
    st.created_at,
    count(l.id) as leads_count,
    count(l.id) filter (where l.bought = 'Sim') as sales_count
  from public.stores st
  left join public.leads l on l.store_id = st.id and l.admin_user_id = st.admin_user_id
  where st.is_active = true
    and st.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role = 'admin'
      or st.id = v_session.user_store_id
    )
  group by st.id
  order by st.created_at desc;
end;
$$;

create or replace function app_private.rpc_list_options(p_session_token text)
returns table (
  id uuid,
  group_key public.lead_option_group,
  value text,
  sort_order integer,
  fixed boolean
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select o.id, o.group_key, o.value, o.sort_order, o.fixed
  from public.lead_options o
  where o.admin_user_id = v_session.admin_user_id
    and o.is_active = true
  order by o.group_key, o.sort_order, o.created_at;
end;
$$;

create or replace function app_private.next_option_label(
  p_admin_user_id uuid,
  p_group_key public.lead_option_group
)
returns text
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_base text := 'Nova opção';
  v_label text := 'Nova opção';
  v_counter integer := 2;
begin
  while exists (
    select 1
    from public.lead_options
    where admin_user_id = p_admin_user_id
      and group_key = p_group_key
      and value = v_label
      and is_active = true
  ) loop
    v_label := v_base || ' ' || v_counter;
    v_counter := v_counter + 1;
  end loop;

  return v_label;
end;
$$;

drop function if exists public.lc_add_option(text, public.lead_option_group);
drop function if exists public.lc_add_option(text, public.lead_option_group, text);
drop function if exists app_private.rpc_add_option(text, public.lead_option_group);
drop function if exists app_private.rpc_add_option(text, public.lead_option_group, text);

create or replace function app_private.rpc_add_option(
  p_session_token text,
  p_group_key public.lead_option_group,
  p_value text default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_value text;
  v_sort_order integer;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar opcoes.';
  end if;

  if p_group_key in ('scheduled', 'visited', 'bought') then
    raise exception 'Este grupo de opcoes e fixo.';
  end if;

  v_value := coalesce(nullif(btrim(coalesce(p_value, '')), ''), app_private.next_option_label(v_session.admin_user_id, p_group_key));
  v_sort_order := coalesce((
    select max(sort_order) + 10
    from public.lead_options
    where admin_user_id = v_session.admin_user_id
      and group_key = p_group_key
      and is_active = true
  ), 10);

  if exists (
    select 1
    from public.lead_options
    where admin_user_id = v_session.admin_user_id
      and group_key = p_group_key
      and value = v_value
      and is_active = true
  ) then
    raise exception 'Essa opcao ja existe.';
  end if;

  update public.lead_options
  set
    is_active = true,
    sort_order = v_sort_order
  where admin_user_id = v_session.admin_user_id
    and group_key = p_group_key
    and value = v_value
    and is_active = false;

  if found then
    return true;
  end if;

  insert into public.lead_options (admin_user_id, group_key, value, sort_order)
  values (
    v_session.admin_user_id,
    p_group_key,
    v_value,
    v_sort_order
  );

  return true;
end;
$$;

create or replace function app_private.rpc_update_option(
  p_session_token text,
  p_option_id uuid,
  p_value text
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_option record;
  v_value text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar opcoes.';
  end if;

  v_value := btrim(coalesce(p_value, ''));

  if length(v_value) = 0 then
    raise exception 'Opcao nao encontrada, vazia ou fixa.';
  end if;

  select id, group_key, sort_order
  into v_option
  from public.lead_options
  where id = p_option_id
    and admin_user_id = v_session.admin_user_id
    and fixed = false
    and is_active = true;

  if not found then
    raise exception 'Opcao nao encontrada, vazia ou fixa.';
  end if;

  if exists (
    select 1
    from public.lead_options
    where admin_user_id = v_session.admin_user_id
      and group_key = v_option.group_key
      and value = v_value
      and is_active = true
      and id <> p_option_id
  ) then
    raise exception 'Essa opcao ja existe.';
  end if;

  update public.lead_options
  set
    is_active = true,
    sort_order = v_option.sort_order
  where admin_user_id = v_session.admin_user_id
    and group_key = v_option.group_key
    and value = v_value
    and is_active = false;

  if found then
    update public.lead_options
    set is_active = false
    where id = p_option_id;

    return true;
  end if;

  update public.lead_options
  set value = v_value
  where id = p_option_id;

  return true;
end;
$$;

create or replace function app_private.rpc_delete_option(
  p_session_token text,
  p_option_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar opcoes.';
  end if;

  update public.lead_options
  set is_active = false
  where id = p_option_id
    and admin_user_id = v_session.admin_user_id
    and fixed = false
    and is_active = true;

  if not found then
    raise exception 'Opcao nao encontrada ou fixa.';
  end if;

  return true;
end;
$$;

drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, uuid);
drop function if exists public.lc_list_leads(text);
drop function if exists app_private.rpc_list_leads(text);

create or replace function app_private.rpc_list_leads(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  scheduled text,
  scheduled_visit_date date,
  scheduled_visit_time time,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select
    l.id,
    l.store_id,
    st.name as store_name,
    l.name,
    l.phone,
    l.channel,
    l.campaign,
    l.conversation_start,
    l.conclusion,
    l.scheduled,
    l.scheduled_visit_date,
    l.scheduled_visit_time,
    l.visited,
    l.bought,
    l.purchase_amount,
    l.service_order,
    l.notes,
    l.created_at,
    l.updated_at
  from public.leads l
  join public.stores st on st.id = l.store_id
  where l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role = 'admin'
      or l.store_id = v_session.user_store_id
    )
  order by l.created_at desc;
end;
$$;

create or replace function app_private.rpc_upsert_lead(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_scheduled text default null,
  p_scheduled_visit_date date default null,
  p_scheduled_visit_time time default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_store_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_lead_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if length(btrim(coalesce(p_name, ''))) = 0 or length(btrim(coalesce(p_phone, ''))) = 0 then
    raise exception 'Preencha nome e telefone.';
  end if;

  if nullif(btrim(coalesce(p_visited, '')), '') = 'Sim'
     and nullif(btrim(coalesce(p_bought, '')), '') is null then
    raise exception 'Informe se o lead comprou ou nao.';
  end if;

  if nullif(btrim(coalesce(p_scheduled, '')), '') is null then
    raise exception 'Informe se o lead agendou visita ou nao.';
  end if;

  if nullif(btrim(coalesce(p_scheduled, '')), '') not in ('Sim', 'Não') then
    raise exception 'Agendamento invalido.';
  end if;

  if nullif(btrim(coalesce(p_scheduled, '')), '') = 'Sim'
     and p_scheduled_visit_date is null then
    raise exception 'Informe a data da visita agendada.';
  end if;

  if nullif(btrim(coalesce(p_bought, '')), '') = 'Sim'
     and (p_purchase_amount is null or p_purchase_amount <= 0 or nullif(btrim(coalesce(p_service_order, '')), '') is null) then
    raise exception 'Informe o valor da compra e a OS.';
  end if;

  if v_session.user_role = 'store' then
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if p_lead_id is not null and v_store_id is null then
    select store_id
    into v_store_id
    from public.leads
    where id = p_lead_id
      and admin_user_id = v_session.admin_user_id;
  end if;

  if v_store_id is null then
    raise exception 'Loja obrigatoria para cadastrar lead.';
  end if;

  if not exists (
    select 1
    from public.stores
    where id = v_store_id
      and admin_user_id = v_session.admin_user_id
      and is_active = true
  ) then
    raise exception 'Loja nao encontrada ou sem permissao.';
  end if;

  if p_lead_id is null then
    insert into public.leads (
      admin_user_id,
      store_id,
      name,
      phone,
      channel,
      campaign,
      conversation_start,
      conclusion,
      scheduled,
      scheduled_visit_date,
      scheduled_visit_time,
      visited,
      bought,
      purchase_amount,
      service_order,
      notes,
      created_by,
      updated_by
    )
    values (
      v_session.admin_user_id,
      v_store_id,
      btrim(p_name),
      btrim(p_phone),
      nullif(btrim(coalesce(p_channel, '')), ''),
      nullif(btrim(coalesce(p_campaign, '')), ''),
      nullif(btrim(coalesce(p_conversation_start, '')), ''),
      nullif(btrim(coalesce(p_conclusion, '')), ''),
      nullif(btrim(coalesce(p_scheduled, '')), ''),
      case when nullif(btrim(coalesce(p_scheduled, '')), '') = 'Sim' then p_scheduled_visit_date else null end,
      case when nullif(btrim(coalesce(p_scheduled, '')), '') = 'Sim' then p_scheduled_visit_time else null end,
      nullif(btrim(coalesce(p_visited, '')), ''),
      nullif(btrim(coalesce(p_bought, '')), ''),
      case when nullif(btrim(coalesce(p_bought, '')), '') = 'Sim' then p_purchase_amount else null end,
      case when nullif(btrim(coalesce(p_bought, '')), '') = 'Sim' then nullif(btrim(coalesce(p_service_order, '')), '') else null end,
      nullif(btrim(coalesce(p_notes, '')), ''),
      v_session.user_id,
      v_session.user_id
    )
    returning id into v_lead_id;
  else
    update public.leads
    set
      store_id = v_store_id,
      name = btrim(p_name),
      phone = btrim(p_phone),
      channel = nullif(btrim(coalesce(p_channel, '')), ''),
      campaign = nullif(btrim(coalesce(p_campaign, '')), ''),
      conversation_start = nullif(btrim(coalesce(p_conversation_start, '')), ''),
      conclusion = nullif(btrim(coalesce(p_conclusion, '')), ''),
      scheduled = nullif(btrim(coalesce(p_scheduled, '')), ''),
      scheduled_visit_date = case when nullif(btrim(coalesce(p_scheduled, '')), '') = 'Sim' then p_scheduled_visit_date else null end,
      scheduled_visit_time = case when nullif(btrim(coalesce(p_scheduled, '')), '') = 'Sim' then p_scheduled_visit_time else null end,
      visited = nullif(btrim(coalesce(p_visited, '')), ''),
      bought = nullif(btrim(coalesce(p_bought, '')), ''),
      purchase_amount = case when nullif(btrim(coalesce(p_bought, '')), '') = 'Sim' then p_purchase_amount else null end,
      service_order = case when nullif(btrim(coalesce(p_bought, '')), '') = 'Sim' then nullif(btrim(coalesce(p_service_order, '')), '') else null end,
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      updated_by = v_session.user_id
    where id = p_lead_id
      and admin_user_id = v_session.admin_user_id
      and (
        v_session.user_role = 'admin'
        or store_id = v_session.user_store_id
      )
    returning id into v_lead_id;

    if not found then
      raise exception 'Lead nao encontrado ou sem permissao.';
    end if;
  end if;

  return v_lead_id;
end;
$$;

create or replace function app_private.rpc_delete_lead(
  p_session_token text,
  p_lead_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  delete from public.leads
  where id = p_lead_id
    and admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role = 'admin'
      or store_id = v_session.user_store_id
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

create or replace function public.lc_login(p_nick text, p_password text)
returns table (
  session_token text,
  expires_at timestamptz,
  user_id uuid,
  admin_id uuid,
  nick text,
  full_name text,
  role public.app_user_role,
  store_id uuid,
  store_name text
)
language sql
security invoker
as $$
  select * from app_private.rpc_login(p_nick, p_password);
$$;

create or replace function public.lc_current_profile(p_session_token text)
returns table (
  user_id uuid,
  admin_id uuid,
  nick text,
  full_name text,
  role public.app_user_role,
  store_id uuid,
  store_name text
)
language sql
security invoker
as $$
  select * from app_private.profile_result(p_session_token);
$$;

create or replace function public.lc_logout(p_session_token text)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_logout(p_session_token);
$$;

create or replace function public.lc_create_store(
  p_session_token text,
  p_name text,
  p_nick text,
  p_password text
)
returns table (
  store_id uuid,
  store_name text,
  store_nick text,
  user_id uuid,
  user_nick text
)
language sql
security invoker
as $$
  select * from app_private.rpc_create_store(p_session_token, p_name, p_nick, p_password);
$$;

create or replace function public.lc_list_stores(p_session_token text)
returns table (
  id uuid,
  name text,
  nick text,
  created_at timestamptz,
  leads_count bigint,
  sales_count bigint
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_stores(p_session_token);
$$;

create or replace function public.lc_list_options(p_session_token text)
returns table (
  id uuid,
  group_key public.lead_option_group,
  value text,
  sort_order integer,
  fixed boolean
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_options(p_session_token);
$$;

create or replace function public.lc_add_option(
  p_session_token text,
  p_group_key public.lead_option_group,
  p_value text default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_add_option(p_session_token, p_group_key, p_value);
$$;

create or replace function public.lc_update_option(
  p_session_token text,
  p_option_id uuid,
  p_value text
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_update_option(p_session_token, p_option_id, p_value);
$$;

create or replace function public.lc_delete_option(
  p_session_token text,
  p_option_id uuid
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_option(p_session_token, p_option_id);
$$;

create or replace function public.lc_list_leads(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  scheduled text,
  scheduled_visit_date date,
  scheduled_visit_time time,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_leads(p_session_token);
$$;

create or replace function public.lc_upsert_lead(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_scheduled text default null,
  p_scheduled_visit_date date default null,
  p_scheduled_visit_time time default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_store_id uuid default null
)
returns uuid
language sql
security invoker
as $$
  select app_private.rpc_upsert_lead(
    p_session_token,
    p_lead_id,
    p_name,
    p_phone,
    p_channel,
    p_campaign,
    p_conversation_start,
    p_conclusion,
    p_scheduled,
    p_scheduled_visit_date,
    p_scheduled_visit_time,
    p_visited,
    p_bought,
    p_purchase_amount,
    p_service_order,
    p_notes,
    p_store_id
  );
$$;

create or replace function public.lc_delete_lead(
  p_session_token text,
  p_lead_id uuid
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_lead(p_session_token, p_lead_id);
$$;

revoke all on schema app_private from public;
grant usage on schema app_private to anon, authenticated;
grant usage on schema public to anon, authenticated;

revoke all on table public.app_users from anon, authenticated;
revoke all on table public.stores from anon, authenticated;
revoke all on table public.app_sessions from anon, authenticated;
revoke all on table public.lead_options from anon, authenticated;
revoke all on table public.leads from anon, authenticated;

grant select, insert, update, delete on table public.app_users to service_role;
grant select, insert, update, delete on table public.stores to service_role;
grant select, insert, update, delete on table public.app_sessions to service_role;
grant select, insert, update, delete on table public.lead_options to service_role;
grant select, insert, update, delete on table public.leads to service_role;

grant usage on type public.app_user_role to anon, authenticated;
grant usage on type public.lead_option_group to anon, authenticated;

revoke execute on all functions in schema app_private from public, anon, authenticated;

grant execute on function app_private.rpc_login(text, text) to anon, authenticated;
grant execute on function app_private.profile_result(text) to anon, authenticated;
grant execute on function app_private.rpc_logout(text) to anon, authenticated;
grant execute on function app_private.rpc_create_store(text, text, text, text) to anon, authenticated;
grant execute on function app_private.rpc_list_stores(text) to anon, authenticated;
grant execute on function app_private.rpc_list_options(text) to anon, authenticated;
grant execute on function app_private.rpc_add_option(text, public.lead_option_group, text) to anon, authenticated;
grant execute on function app_private.rpc_update_option(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_option(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_list_leads(text) to anon, authenticated;
grant execute on function app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_delete_lead(text, uuid) to anon, authenticated;

grant execute on function public.lc_login(text, text) to anon, authenticated;
grant execute on function public.lc_current_profile(text) to anon, authenticated;
grant execute on function public.lc_logout(text) to anon, authenticated;
grant execute on function public.lc_create_store(text, text, text, text) to anon, authenticated;
grant execute on function public.lc_list_stores(text) to anon, authenticated;
grant execute on function public.lc_list_options(text) to anon, authenticated;
grant execute on function public.lc_add_option(text, public.lead_option_group, text) to anon, authenticated;
grant execute on function public.lc_update_option(text, uuid, text) to anon, authenticated;
grant execute on function public.lc_delete_option(text, uuid) to anon, authenticated;
grant execute on function public.lc_list_leads(text) to anon, authenticated;
grant execute on function public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, uuid) to anon, authenticated;
grant execute on function public.lc_delete_lead(text, uuid) to anon, authenticated;

-- =============================================================================
-- ATUALIZACAO INCREMENTAL: PROSPECCOES
-- Em banco existente, selecione deste marcador ate o fim e execute a selecao.
-- Nao reaplica nem rebaixa as RPCs atuais de Leads/Agencias.
-- =============================================================================

-- Garante a regra de um unico administrador e remove definitivamente o endpoint
-- legado de cadastro. A ordem evita dependencia entre wrapper publico e privado.
drop function if exists public.lc_create_admin(text, text, text);
drop function if exists app_private.rpc_create_admin(text, text, text);

alter type public.app_user_role add value if not exists 'technician' before 'store';

alter table public.app_users drop constraint if exists app_users_role_scope_check;
alter table public.app_users
  add constraint app_users_role_scope_check check (
    (role::text = 'admin' and admin_user_id is null and store_id is null)
    or
    (role::text = 'technician' and admin_user_id is not null and store_id is null)
    or
    (role::text = 'store' and admin_user_id is not null and store_id is not null)
  );

create unique index if not exists app_users_single_admin_idx
  on public.app_users (role)
  where role = 'admin';

-- -----------------------------------------------------------------------------
-- Modulo integrado de Prospeccoes
-- Usa a mesma sessao, hierarquia Admin -> Agencia (technician) -> Cliente (store)
-- e o mesmo banco do Controle de Leads.
-- -----------------------------------------------------------------------------

alter table public.stores
  add column if not exists technician_user_id uuid references public.app_users(id) on delete set null;

create table if not exists public.prospection_store_settings (
  store_id uuid primary key,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  daily_goal integer not null default 15 check (daily_goal between 1 and 9999),
  bonus_minimum numeric(12,2) not null default 300 check (bonus_minimum >= 0),
  bonus_amount numeric(12,2) not null default 20 check (bonus_amount >= 0),
  accent_color text not null default '#16855f' check (accent_color ~ '^#[0-9a-fA-F]{6}$'),
  logo_background_color text not null default '#ffffff' check (logo_background_color ~ '^#[0-9a-fA-F]{6}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prospection_settings_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

alter table public.prospection_store_settings
  add column if not exists logo_background_color text not null default '#ffffff';

create table if not exists public.prospection_professionals (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  is_active boolean not null default true,
  archived_at timestamptz,
  archived_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prospection_professionals_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

-- Mantém o consolidado idempotente também em bases criadas por versões
-- anteriores, nas quais CREATE TABLE IF NOT EXISTS não adiciona colunas.
alter table public.prospection_professionals
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references public.app_users(id) on delete set null;

create unique index if not exists prospection_professionals_store_name_uidx
  on public.prospection_professionals (store_id, lower(name));

create table if not exists public.prospection_tag_categories (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prospection_tag_categories_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

create unique index if not exists prospection_tag_categories_store_name_uidx
  on public.prospection_tag_categories (store_id, lower(name));

create table if not exists public.prospection_tags (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  category_id uuid,
  label text not null check (length(btrim(label)) > 0),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prospection_tags_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

create unique index if not exists prospection_tags_store_label_uidx
  on public.prospection_tags (store_id, lower(label));

alter table public.prospection_tags
  add column if not exists category_id uuid,
  add column if not exists sort_order integer not null default 0;

insert into public.prospection_tag_categories (store_id, admin_user_id, name, sort_order)
select st.id, st.admin_user_id, 'Campanhas', 10
from public.stores st
on conflict do nothing;

update public.prospection_tags pt
set category_id = (
  select pc.id
  from public.prospection_tag_categories pc
  where pc.store_id = pt.store_id
    and pc.admin_user_id = pt.admin_user_id
  order by pc.sort_order, pc.created_at
  limit 1
)
where pt.category_id is null;

alter table public.prospection_tags
  alter column category_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'prospection_tags_category_fk'
      and conrelid = 'public.prospection_tags'::regclass
  ) then
    alter table public.prospection_tags
      add constraint prospection_tags_category_fk
      foreign key (category_id)
      references public.prospection_tag_categories(id)
      on delete cascade;
  end if;
end $$;

create table if not exists public.prospections (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  name text not null check (length(btrim(name)) > 0),
  phone text,
  cpf text,
  notes text,
  probability text not null default 'blue' check (probability in ('red', 'yellow', 'blue', 'green')),
  tags text[] not null default '{}'::text[],
  professional_id uuid references public.prospection_professionals(id) on delete set null,
  professional_name_snapshot text,
  returned_at timestamptz,
  purchased_at timestamptz,
  purchase_amount numeric(12,2),
  purchase_order text,
  created_by uuid references public.app_users(id) on delete set null,
  updated_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prospections_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint prospections_purchase_amount_check
    check (purchase_amount is null or purchase_amount > 0),
  constraint prospections_purchase_consistency_check
    check (
      (purchased_at is null and purchase_amount is null and purchase_order is null)
      or
      (purchased_at is not null and purchase_amount > 0 and purchase_order is not null and length(btrim(purchase_order)) > 0)
    )
);

create index if not exists prospections_admin_created_idx
  on public.prospections (admin_user_id, created_at desc);
create index if not exists prospections_store_created_idx
  on public.prospections (store_id, created_at desc);
create index if not exists prospections_store_returned_idx
  on public.prospections (store_id, returned_at desc) where returned_at is not null;
create index if not exists prospections_store_purchased_idx
  on public.prospections (store_id, purchased_at desc) where purchased_at is not null;
create index if not exists prospections_professional_created_idx
  on public.prospections (professional_id, created_at desc) where professional_id is not null;

drop trigger if exists prospection_store_settings_updated_at on public.prospection_store_settings;
create trigger prospection_store_settings_updated_at
before update on public.prospection_store_settings
for each row execute function app_private.set_updated_at();

drop trigger if exists prospection_professionals_updated_at on public.prospection_professionals;
create trigger prospection_professionals_updated_at
before update on public.prospection_professionals
for each row execute function app_private.set_updated_at();

drop trigger if exists prospection_tags_updated_at on public.prospection_tags;
create trigger prospection_tags_updated_at
before update on public.prospection_tags
for each row execute function app_private.set_updated_at();

drop trigger if exists prospection_tag_categories_updated_at on public.prospection_tag_categories;
create trigger prospection_tag_categories_updated_at
before update on public.prospection_tag_categories
for each row execute function app_private.set_updated_at();

drop trigger if exists prospections_updated_at on public.prospections;
create trigger prospections_updated_at
before update on public.prospections
for each row execute function app_private.set_updated_at();

alter table public.prospection_store_settings enable row level security;
alter table public.prospection_professionals enable row level security;
alter table public.prospection_tag_categories enable row level security;
alter table public.prospection_tags enable row level security;
alter table public.prospections enable row level security;

create or replace function app_private.prospection_store_allowed(
  p_admin_user_id uuid,
  p_user_id uuid,
  p_user_role public.app_user_role,
  p_user_store_id uuid,
  p_store_id uuid,
  p_management_only boolean default false
)
returns boolean
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  select exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = p_admin_user_id
      and st.is_active = true
      and (
        p_user_role::text = 'admin'
        or (p_user_role::text = 'technician' and st.technician_user_id = p_user_id)
        or (
          coalesce(p_management_only, false) = false
          and p_user_role::text = 'store'
          and st.id = p_user_store_id
        )
      )
  );
$$;

create or replace function app_private.prospection_configuration_revision(
  p_store_id uuid
)
returns text
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  select encode(
    extensions.digest(
      jsonb_build_object(
        'settings', jsonb_build_object(
          'daily_goal', coalesce(ps.daily_goal, 15),
          'bonus_minimum', coalesce(ps.bonus_minimum, 300),
          'bonus_amount', coalesce(ps.bonus_amount, 20),
          'accent_color', coalesce(ps.accent_color, '#16855f'),
          'logo_background_color', coalesce(ps.logo_background_color, '#ffffff')
        ),
        'categories', coalesce((
          select jsonb_agg(jsonb_build_array(pc.id, pc.name, pc.sort_order) order by pc.id)
          from public.prospection_tag_categories pc
          where pc.store_id = p_store_id
        ), '[]'::jsonb),
        'tags', coalesce((
          select jsonb_agg(jsonb_build_array(pt.id, pt.category_id, pt.label, pt.sort_order) order by pt.id)
          from public.prospection_tags pt
          where pt.store_id = p_store_id
        ), '[]'::jsonb),
        'professionals', coalesce((
          select jsonb_agg(jsonb_build_array(pp.id, pp.name, pp.is_active) order by pp.id)
          from public.prospection_professionals pp
          where pp.store_id = p_store_id
            and pp.archived_at is null
        ), '[]'::jsonb)
      )::text,
      'sha256'
    ),
    'hex'
  )
  from (select 1) seed
  left join public.prospection_store_settings ps on ps.store_id = p_store_id;
$$;

create or replace function app_private.rpc_get_prospection_configuration(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);

  select jsonb_build_object(
    'settings', coalesce((
      select jsonb_agg(jsonb_build_object(
        'store_id', st.id,
        'daily_goal', coalesce(ps.daily_goal, 15),
        'bonus_minimum', coalesce(ps.bonus_minimum, 300),
        'bonus_amount', coalesce(ps.bonus_amount, 20),
        'accent_color', coalesce(ps.accent_color, '#16855f'),
        'logo_background_color', coalesce(ps.logo_background_color, '#ffffff'),
        'revision', app_private.prospection_configuration_revision(st.id)
      ) order by st.name)
      from public.stores st
      left join public.prospection_store_settings ps on ps.store_id = st.id
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and app_private.prospection_store_allowed(
          v_session.admin_user_id,
          v_session.user_id,
          v_session.user_role,
          v_session.user_store_id,
          st.id,
          false
        )
    ), '[]'::jsonb),
    'professionals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pp.id,
        'store_id', pp.store_id,
        'name', pp.name,
        'is_active', pp.is_active
      ) order by pp.name)
      from public.prospection_professionals pp
      where pp.admin_user_id = v_session.admin_user_id
        and pp.archived_at is null
        and app_private.prospection_store_allowed(
          v_session.admin_user_id,
          v_session.user_id,
          v_session.user_role,
          v_session.user_store_id,
          pp.store_id,
          false
        )
    ), '[]'::jsonb),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pc.id,
        'store_id', pc.store_id,
        'name', pc.name,
        'sort_order', pc.sort_order
      ) order by pc.sort_order, pc.created_at)
      from public.prospection_tag_categories pc
      where pc.admin_user_id = v_session.admin_user_id
        and app_private.prospection_store_allowed(
          v_session.admin_user_id,
          v_session.user_id,
          v_session.user_role,
          v_session.user_store_id,
          pc.store_id,
          false
        )
    ), '[]'::jsonb),
    'tags', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pt.id,
        'store_id', pt.store_id,
        'category_id', pt.category_id,
        'label', pt.label,
        'sort_order', pt.sort_order
      ) order by pt.sort_order, pt.created_at)
      from public.prospection_tags pt
      where pt.admin_user_id = v_session.admin_user_id
        and app_private.prospection_store_allowed(
          v_session.admin_user_id,
          v_session.user_id,
          v_session.user_role,
          v_session.user_store_id,
          pt.store_id,
          false
        )
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

create or replace function app_private.rpc_save_prospection_logo_background(
  p_session_token text,
  p_store_id uuid,
  p_logo_background_color text
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if not app_private.prospection_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id,
    true
  ) then
    raise exception 'Sem permissao para configurar a identidade deste cliente.';
  end if;

  if coalesce(p_logo_background_color, '') !~ '^#[0-9a-fA-F]{6}$' then
    raise exception 'Cor de fundo da logo invalida.';
  end if;

  insert into public.prospection_store_settings (
    store_id,
    admin_user_id,
    logo_background_color
  ) values (
    p_store_id,
    v_session.admin_user_id,
    lower(p_logo_background_color)
  )
  on conflict (store_id) do update set
    logo_background_color = excluded.logo_background_color;

  return true;
end;
$$;

create or replace function app_private.rpc_list_prospections(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  technician_id uuid,
  name text,
  phone text,
  cpf text,
  notes text,
  probability text,
  tags text[],
  professional_id uuid,
  professional_name text,
  returned_at timestamptz,
  purchased_at timestamptz,
  purchase_amount numeric,
  purchase_order text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select
    pr.id,
    pr.store_id,
    st.name,
    st.technician_user_id,
    pr.name,
    pr.phone,
    pr.cpf,
    pr.notes,
    pr.probability,
    pr.tags,
    pr.professional_id,
    coalesce(pp.name, pr.professional_name_snapshot),
    pr.returned_at,
    pr.purchased_at,
    pr.purchase_amount,
    pr.purchase_order,
    pr.created_at,
    pr.updated_at
  from public.prospections pr
  join public.stores st on st.id = pr.store_id and st.admin_user_id = pr.admin_user_id
  left join public.prospection_professionals pp on pp.id = pr.professional_id
  where pr.admin_user_id = v_session.admin_user_id
    and app_private.prospection_store_allowed(
      v_session.admin_user_id,
      v_session.user_id,
      v_session.user_role,
      v_session.user_store_id,
      pr.store_id,
      false
    )
  order by pr.created_at desc;
end;
$$;

create or replace function app_private.rpc_upsert_prospection(
  p_session_token text,
  p_prospection_id uuid,
  p_store_id uuid,
  p_name text,
  p_phone text default null,
  p_cpf text default null,
  p_notes text default null,
  p_probability text default 'blue',
  p_tags text[] default '{}'::text[],
  p_professional_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_prospection_id uuid;
  v_professional_name text;
  v_tags text[];
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := case when v_session.user_role::text = 'store' then v_session.user_store_id else p_store_id end;

  if not app_private.prospection_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id,
    false
  ) then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'Informe o nome da prospeccao.';
  end if;

  if coalesce(p_probability, '') not in ('red', 'yellow', 'blue', 'green') then
    raise exception 'Probabilidade invalida.';
  end if;

  if p_professional_id is not null then
    -- Bloqueia apenas o cadastro escolhido até concluir a gravação. Uma
    -- exclusão concorrente aguarda, sem serializar toda a operação da loja.
    select pp.name into v_professional_name
    from public.prospection_professionals pp
    where pp.id = p_professional_id
      and pp.store_id = v_store_id
      and pp.admin_user_id = v_session.admin_user_id
      and pp.is_active = true
      and pp.archived_at is null
    for share;

    if not found then
      raise exception 'Profissional nao encontrado para este cliente.';
    end if;
  end if;

  select coalesce(array_agg(pt.label order by pt.label), '{}'::text[])
  into v_tags
  from public.prospection_tags pt
  where pt.store_id = v_store_id
    and pt.admin_user_id = v_session.admin_user_id
    and pt.label = any(coalesce(p_tags, '{}'::text[]));

  if p_prospection_id is null then
    insert into public.prospections (
      admin_user_id,
      store_id,
      name,
      phone,
      cpf,
      notes,
      probability,
      tags,
      professional_id,
      professional_name_snapshot,
      created_by,
      updated_by
    ) values (
      v_session.admin_user_id,
      v_store_id,
      btrim(p_name),
      nullif(btrim(coalesce(p_phone, '')), ''),
      nullif(btrim(coalesce(p_cpf, '')), ''),
      nullif(btrim(coalesce(p_notes, '')), ''),
      p_probability,
      v_tags,
      p_professional_id,
      v_professional_name,
      v_session.user_id,
      v_session.user_id
    ) returning id into v_prospection_id;
  else
    update public.prospections pr
    set
      name = btrim(p_name),
      phone = nullif(btrim(coalesce(p_phone, '')), ''),
      cpf = nullif(btrim(coalesce(p_cpf, '')), ''),
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      probability = p_probability,
      tags = v_tags,
      professional_id = p_professional_id,
      professional_name_snapshot = v_professional_name,
      updated_by = v_session.user_id
    where pr.id = p_prospection_id
      and pr.admin_user_id = v_session.admin_user_id
      and pr.store_id = v_store_id
    returning pr.id into v_prospection_id;

    if not found then
      raise exception 'Prospeccao nao encontrada ou sem permissao.';
    end if;
  end if;

  return v_prospection_id;
end;
$$;

create or replace function app_private.rpc_set_prospection_outcome(
  p_session_token text,
  p_prospection_id uuid,
  p_returned boolean default null,
  p_purchased boolean default null,
  p_purchase_amount numeric default null,
  p_purchase_order text default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_prospection record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  select pr.store_id, pr.purchased_at into v_prospection
  from public.prospections pr
  where pr.id = p_prospection_id
    and pr.admin_user_id = v_session.admin_user_id;

  if not found or not app_private.prospection_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_prospection.store_id,
    false
  ) then
    raise exception 'Prospeccao nao encontrada ou sem permissao.';
  end if;

  if p_returned = false and v_prospection.purchased_at is not null and p_purchased is null then
    raise exception 'Remova a compra antes de remover a volta.';
  end if;

  if p_purchased = true then
    if coalesce(p_purchase_amount, 0) <= 0 then
      raise exception 'Informe um valor de compra maior que zero.';
    end if;
    if length(btrim(coalesce(p_purchase_order, ''))) = 0 then
      raise exception 'Informe o numero da OS.';
    end if;
  end if;

  update public.prospections pr
  set
    returned_at = case
      when p_purchased = true then coalesce(pr.returned_at, now())
      when p_returned is null then pr.returned_at
      when p_returned = true then coalesce(pr.returned_at, now())
      else null
    end,
    purchased_at = case
      when p_purchased is null then pr.purchased_at
      when p_purchased = true then coalesce(pr.purchased_at, now())
      else null
    end,
    purchase_amount = case
      when p_purchased is null then pr.purchase_amount
      when p_purchased = true then p_purchase_amount
      else null
    end,
    purchase_order = case
      when p_purchased is null then pr.purchase_order
      when p_purchased = true then btrim(p_purchase_order)
      else null
    end,
    updated_by = v_session.user_id
  where pr.id = p_prospection_id;

  return true;
end;
$$;

create or replace function app_private.rpc_delete_prospection(
  p_session_token text,
  p_prospection_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  select pr.store_id into v_store_id
  from public.prospections pr
  where pr.id = p_prospection_id
    and pr.admin_user_id = v_session.admin_user_id;

  if not found or not app_private.prospection_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id,
    false
  ) then
    raise exception 'Prospeccao nao encontrada ou sem permissao.';
  end if;

  delete from public.prospections where id = p_prospection_id;
  return true;
end;
$$;

create or replace function app_private.rpc_save_prospection_store_settings(
  p_session_token text,
  p_store_id uuid,
  p_daily_goal integer,
  p_bonus_minimum numeric,
  p_bonus_amount numeric,
  p_accent_color text
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if not app_private.prospection_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id,
    true
  ) then
    raise exception 'Sem permissao para configurar este cliente.';
  end if;

  if coalesce(p_daily_goal, 0) not between 1 and 9999 then
    raise exception 'Informe uma meta diaria valida.';
  end if;
  if coalesce(p_bonus_minimum, -1) < 0 or coalesce(p_bonus_amount, -1) < 0 then
    raise exception 'Os valores de bonificacao nao podem ser negativos.';
  end if;
  if coalesce(p_accent_color, '') !~ '^#[0-9a-fA-F]{6}$' then
    raise exception 'Cor invalida.';
  end if;

  insert into public.prospection_store_settings (
    store_id,
    admin_user_id,
    daily_goal,
    bonus_minimum,
    bonus_amount,
    accent_color
  ) values (
    p_store_id,
    v_session.admin_user_id,
    p_daily_goal,
    p_bonus_minimum,
    p_bonus_amount,
    lower(p_accent_color)
  )
  on conflict (store_id) do update set
    daily_goal = excluded.daily_goal,
    bonus_minimum = excluded.bonus_minimum,
    bonus_amount = excluded.bonus_amount,
    accent_color = excluded.accent_color;

  return true;
end;
$$;

drop function if exists public.lc_add_prospection_tag(text, uuid, text);
drop function if exists app_private.rpc_add_prospection_tag(text, uuid, text);

create or replace function app_private.rpc_upsert_prospection_category(
  p_session_token text,
  p_store_id uuid,
  p_category_id uuid,
  p_name text
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_category_id uuid;
  v_name text;
  v_sort_order integer;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_name := btrim(coalesce(p_name, ''));

  if not app_private.prospection_store_allowed(v_session.admin_user_id, v_session.user_id, v_session.user_role, v_session.user_store_id, p_store_id, true) then
    raise exception 'Sem permissao para configurar este cliente.';
  end if;
  if length(v_name) = 0 then raise exception 'Informe o nome da categoria.'; end if;

  if p_category_id is null then
    v_sort_order := coalesce((
      select max(pc.sort_order) + 10
      from public.prospection_tag_categories pc
      where pc.store_id = p_store_id
    ), 10);

    insert into public.prospection_tag_categories (store_id, admin_user_id, name, sort_order)
    values (p_store_id, v_session.admin_user_id, v_name, v_sort_order)
    returning id into v_category_id;
  else
    update public.prospection_tag_categories pc
    set name = v_name
    where pc.id = p_category_id
      and pc.store_id = p_store_id
      and pc.admin_user_id = v_session.admin_user_id
    returning pc.id into v_category_id;

    if not found then raise exception 'Categoria nao encontrada.'; end if;
  end if;

  return v_category_id;
exception
  when unique_violation then
    raise exception 'Ja existe uma categoria com este nome.';
end;
$$;

create or replace function app_private.rpc_delete_prospection_category(
  p_session_token text,
  p_category_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select pc.store_id into v_store_id
  from public.prospection_tag_categories pc
  where pc.id = p_category_id
    and pc.admin_user_id = v_session.admin_user_id;

  if not found or not app_private.prospection_store_allowed(v_session.admin_user_id, v_session.user_id, v_session.user_role, v_session.user_store_id, v_store_id, true) then
    raise exception 'Categoria nao encontrada ou sem permissao.';
  end if;

  delete from public.prospection_tag_categories where id = p_category_id;
  return true;
end;
$$;

create or replace function app_private.rpc_reorder_prospection_categories(
  p_session_token text,
  p_store_id uuid,
  p_ordered_ids uuid[]
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.prospection_store_allowed(v_session.admin_user_id, v_session.user_id, v_session.user_role, v_session.user_store_id, p_store_id, true) then
    raise exception 'Sem permissao para configurar este cliente.';
  end if;
  if coalesce((
    select count(distinct ordered.id)
    from unnest(p_ordered_ids) as ordered(id)
    join public.prospection_tag_categories pc
      on pc.id = ordered.id
     and pc.store_id = p_store_id
     and pc.admin_user_id = v_session.admin_user_id
  ), 0) <> (select count(*) from public.prospection_tag_categories where store_id = p_store_id)
  or coalesce(cardinality(p_ordered_ids), 0) <> (select count(*) from public.prospection_tag_categories where store_id = p_store_id) then
    raise exception 'A ordem das categorias esta incompleta.';
  end if;

  update public.prospection_tag_categories pc
  set sort_order = ordered.position * 10
  from unnest(p_ordered_ids) with ordinality as ordered(id, position)
  where pc.id = ordered.id
    and pc.store_id = p_store_id
    and pc.admin_user_id = v_session.admin_user_id;

  return true;
end;
$$;

create or replace function app_private.rpc_add_prospection_tag(
  p_session_token text,
  p_store_id uuid,
  p_category_id uuid,
  p_label text
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_tag_id uuid;
  v_label text;
  v_sort_order integer;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_label := btrim(coalesce(p_label, ''));

  if not app_private.prospection_store_allowed(v_session.admin_user_id, v_session.user_id, v_session.user_role, v_session.user_store_id, p_store_id, true) then
    raise exception 'Sem permissao para configurar este cliente.';
  end if;
  if length(v_label) = 0 then raise exception 'Informe o nome da etiqueta.'; end if;
  if not exists (
    select 1
    from public.prospection_tag_categories pc
    where pc.id = p_category_id
      and pc.store_id = p_store_id
      and pc.admin_user_id = v_session.admin_user_id
  ) then
    raise exception 'Categoria nao encontrada.';
  end if;

  v_sort_order := coalesce((
    select max(pt.sort_order) + 10
    from public.prospection_tags pt
    where pt.category_id = p_category_id
  ), 10);

  insert into public.prospection_tags (store_id, admin_user_id, category_id, label, sort_order)
  values (p_store_id, v_session.admin_user_id, p_category_id, v_label, v_sort_order)
  returning id into v_tag_id;

  return v_tag_id;
exception
  when unique_violation then
    raise exception 'Ja existe uma etiqueta com este nome.';
end;
$$;

create or replace function app_private.rpc_update_prospection_tag(
  p_session_token text,
  p_tag_id uuid,
  p_category_id uuid,
  p_label text
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_label text;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_label := btrim(coalesce(p_label, ''));
  select pt.store_id into v_store_id
  from public.prospection_tags pt
  where pt.id = p_tag_id
    and pt.admin_user_id = v_session.admin_user_id;

  if not found or not app_private.prospection_store_allowed(v_session.admin_user_id, v_session.user_id, v_session.user_role, v_session.user_store_id, v_store_id, true) then
    raise exception 'Etiqueta nao encontrada ou sem permissao.';
  end if;
  if length(v_label) = 0 then raise exception 'Informe o nome da etiqueta.'; end if;
  if not exists (
    select 1 from public.prospection_tag_categories pc
    where pc.id = p_category_id
      and pc.store_id = v_store_id
      and pc.admin_user_id = v_session.admin_user_id
  ) then
    raise exception 'Categoria nao encontrada.';
  end if;

  update public.prospection_tags
  set label = v_label, category_id = p_category_id
  where id = p_tag_id;
  return true;
exception
  when unique_violation then
    raise exception 'Ja existe uma etiqueta com este nome.';
end;
$$;

create or replace function app_private.rpc_reorder_prospection_tags(
  p_session_token text,
  p_category_id uuid,
  p_ordered_ids uuid[]
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select pc.store_id into v_store_id
  from public.prospection_tag_categories pc
  where pc.id = p_category_id
    and pc.admin_user_id = v_session.admin_user_id;

  if not found or not app_private.prospection_store_allowed(v_session.admin_user_id, v_session.user_id, v_session.user_role, v_session.user_store_id, v_store_id, true) then
    raise exception 'Categoria nao encontrada ou sem permissao.';
  end if;
  if coalesce((
    select count(distinct ordered.id)
    from unnest(p_ordered_ids) as ordered(id)
    join public.prospection_tags pt
      on pt.id = ordered.id
     and pt.category_id = p_category_id
     and pt.admin_user_id = v_session.admin_user_id
  ), 0) <> (select count(*) from public.prospection_tags where category_id = p_category_id)
  or coalesce(cardinality(p_ordered_ids), 0) <> (select count(*) from public.prospection_tags where category_id = p_category_id) then
    raise exception 'A ordem das etiquetas esta incompleta.';
  end if;

  update public.prospection_tags pt
  set sort_order = ordered.position * 10
  from unnest(p_ordered_ids) with ordinality as ordered(id, position)
  where pt.id = ordered.id
    and pt.category_id = p_category_id
    and pt.admin_user_id = v_session.admin_user_id;
  return true;
end;
$$;

create or replace function app_private.rpc_delete_prospection_tag(
  p_session_token text,
  p_tag_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select pt.store_id into v_store_id from public.prospection_tags pt where pt.id = p_tag_id and pt.admin_user_id = v_session.admin_user_id;

  if not found or not app_private.prospection_store_allowed(v_session.admin_user_id, v_session.user_id, v_session.user_role, v_session.user_store_id, v_store_id, true) then
    raise exception 'Etiqueta nao encontrada ou sem permissao.';
  end if;

  delete from public.prospection_tags where id = p_tag_id;
  return true;
end;
$$;

create or replace function app_private.rpc_upsert_prospection_professional(
  p_session_token text,
  p_store_id uuid,
  p_professional_id uuid,
  p_name text,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_professional_id uuid;
  v_name text;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_name := btrim(coalesce(p_name, ''));

  if not app_private.prospection_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, p_store_id, true
  ) then
    raise exception 'Sem permissao para configurar este cliente.';
  end if;
  if length(v_name) = 0 then raise exception 'Informe o nome do profissional.'; end if;

  perform 1
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
  for update;

  if p_professional_id is null then
    select pp.id into v_professional_id
    from public.prospection_professionals pp
    where pp.store_id = p_store_id
      and pp.admin_user_id = v_session.admin_user_id
      and lower(pp.name) = lower(v_name)
    order by (pp.archived_at is null) desc, pp.created_at
    limit 1
    for update;

    if v_professional_id is null then
      insert into public.prospection_professionals (
        store_id, admin_user_id, name, is_active
      ) values (
        p_store_id, v_session.admin_user_id, v_name, coalesce(p_is_active, true)
      ) returning id into v_professional_id;
    else
      update public.prospection_professionals pp
      set name = v_name,
          is_active = coalesce(p_is_active, true),
          archived_at = null,
          archived_by = null
      where pp.id = v_professional_id;
    end if;
  else
    update public.prospection_professionals pp
    set name = v_name,
        is_active = coalesce(p_is_active, true)
    where pp.id = p_professional_id
      and pp.store_id = p_store_id
      and pp.admin_user_id = v_session.admin_user_id
      and pp.archived_at is null
    returning pp.id into v_professional_id;

    if not found then raise exception 'Profissional nao encontrado.'; end if;
  end if;

  return v_professional_id;
end;
$$;

create or replace function public.lc_get_prospection_configuration(p_session_token text)
returns jsonb
language sql
security invoker
as $$
  select app_private.rpc_get_prospection_configuration(p_session_token);
$$;

create or replace function public.lc_list_prospections(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  technician_id uuid,
  name text,
  phone text,
  cpf text,
  notes text,
  probability text,
  tags text[],
  professional_id uuid,
  professional_name text,
  returned_at timestamptz,
  purchased_at timestamptz,
  purchase_amount numeric,
  purchase_order text,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_prospections(p_session_token);
$$;

create or replace function public.lc_upsert_prospection(
  p_session_token text,
  p_prospection_id uuid,
  p_store_id uuid,
  p_name text,
  p_phone text default null,
  p_cpf text default null,
  p_notes text default null,
  p_probability text default 'blue',
  p_tags text[] default '{}'::text[],
  p_professional_id uuid default null
)
returns uuid
language sql
security invoker
as $$
  select app_private.rpc_upsert_prospection(
    p_session_token,
    p_prospection_id,
    p_store_id,
    p_name,
    p_phone,
    p_cpf,
    p_notes,
    p_probability,
    p_tags,
    p_professional_id
  );
$$;

create or replace function public.lc_set_prospection_outcome(
  p_session_token text,
  p_prospection_id uuid,
  p_returned boolean default null,
  p_purchased boolean default null,
  p_purchase_amount numeric default null,
  p_purchase_order text default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_set_prospection_outcome(
    p_session_token,
    p_prospection_id,
    p_returned,
    p_purchased,
    p_purchase_amount,
    p_purchase_order
  );
$$;

create or replace function public.lc_delete_prospection(p_session_token text, p_prospection_id uuid)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_prospection(p_session_token, p_prospection_id);
$$;

create or replace function public.lc_save_prospection_store_settings(
  p_session_token text,
  p_store_id uuid,
  p_daily_goal integer,
  p_bonus_minimum numeric,
  p_bonus_amount numeric,
  p_accent_color text
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_save_prospection_store_settings(
    p_session_token,
    p_store_id,
    p_daily_goal,
    p_bonus_minimum,
    p_bonus_amount,
    p_accent_color
  );
$$;

create or replace function public.lc_save_prospection_logo_background(
  p_session_token text,
  p_store_id uuid,
  p_logo_background_color text
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_save_prospection_logo_background(
    p_session_token,
    p_store_id,
    p_logo_background_color
  );
$$;

create or replace function public.lc_upsert_prospection_category(
  p_session_token text,
  p_store_id uuid,
  p_category_id uuid,
  p_name text
)
returns uuid
language sql
security invoker
as $$
  select app_private.rpc_upsert_prospection_category(p_session_token, p_store_id, p_category_id, p_name);
$$;

create or replace function public.lc_delete_prospection_category(p_session_token text, p_category_id uuid)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_prospection_category(p_session_token, p_category_id);
$$;

create or replace function public.lc_reorder_prospection_categories(p_session_token text, p_store_id uuid, p_ordered_ids uuid[])
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_reorder_prospection_categories(p_session_token, p_store_id, p_ordered_ids);
$$;

create or replace function public.lc_add_prospection_tag(p_session_token text, p_store_id uuid, p_category_id uuid, p_label text)
returns uuid
language sql
security invoker
as $$
  select app_private.rpc_add_prospection_tag(p_session_token, p_store_id, p_category_id, p_label);
$$;

create or replace function public.lc_update_prospection_tag(p_session_token text, p_tag_id uuid, p_category_id uuid, p_label text)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_update_prospection_tag(p_session_token, p_tag_id, p_category_id, p_label);
$$;

create or replace function public.lc_reorder_prospection_tags(p_session_token text, p_category_id uuid, p_ordered_ids uuid[])
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_reorder_prospection_tags(p_session_token, p_category_id, p_ordered_ids);
$$;

create or replace function public.lc_delete_prospection_tag(p_session_token text, p_tag_id uuid)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_prospection_tag(p_session_token, p_tag_id);
$$;

create or replace function public.lc_upsert_prospection_professional(
  p_session_token text,
  p_store_id uuid,
  p_professional_id uuid,
  p_name text,
  p_is_active boolean default true
)
returns uuid
language sql
security invoker
as $$
  select app_private.rpc_upsert_prospection_professional(
    p_session_token,
    p_store_id,
    p_professional_id,
    p_name,
    p_is_active
  );
$$;

revoke all on table public.prospection_store_settings from anon, authenticated;
revoke all on table public.prospection_professionals from anon, authenticated;
revoke all on table public.prospection_tag_categories from anon, authenticated;
revoke all on table public.prospection_tags from anon, authenticated;
revoke all on table public.prospections from anon, authenticated;

grant select, insert, update, delete on table public.prospection_store_settings to service_role;
grant select, insert, update, delete on table public.prospection_professionals to service_role;
grant select, insert, update, delete on table public.prospection_tag_categories to service_role;
grant select, insert, update, delete on table public.prospection_tags to service_role;
grant select, insert, update, delete on table public.prospections to service_role;

revoke all on function app_private.prospection_store_allowed(uuid, uuid, public.app_user_role, uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function app_private.prospection_configuration_revision(uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_get_prospection_configuration(text) from public, anon, authenticated;
revoke all on function app_private.rpc_list_prospections(text) from public, anon, authenticated;
revoke all on function app_private.rpc_upsert_prospection(text, uuid, uuid, text, text, text, text, text, text[], uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_set_prospection_outcome(text, uuid, boolean, boolean, numeric, text) from public, anon, authenticated;
revoke all on function app_private.rpc_delete_prospection(text, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_save_prospection_store_settings(text, uuid, integer, numeric, numeric, text) from public, anon, authenticated;
revoke all on function app_private.rpc_save_prospection_logo_background(text, uuid, text) from public, anon, authenticated;
revoke all on function app_private.rpc_upsert_prospection_category(text, uuid, uuid, text) from public, anon, authenticated;
revoke all on function app_private.rpc_delete_prospection_category(text, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_reorder_prospection_categories(text, uuid, uuid[]) from public, anon, authenticated;
revoke all on function app_private.rpc_add_prospection_tag(text, uuid, uuid, text) from public, anon, authenticated;
revoke all on function app_private.rpc_update_prospection_tag(text, uuid, uuid, text) from public, anon, authenticated;
revoke all on function app_private.rpc_reorder_prospection_tags(text, uuid, uuid[]) from public, anon, authenticated;
revoke all on function app_private.rpc_delete_prospection_tag(text, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_upsert_prospection_professional(text, uuid, uuid, text, boolean) from public, anon, authenticated;

grant execute on function app_private.rpc_get_prospection_configuration(text) to anon, authenticated;
grant execute on function app_private.rpc_list_prospections(text) to anon, authenticated;
grant execute on function app_private.rpc_upsert_prospection(text, uuid, uuid, text, text, text, text, text, text[], uuid) to anon, authenticated;
grant execute on function app_private.rpc_set_prospection_outcome(text, uuid, boolean, boolean, numeric, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_prospection(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_save_prospection_store_settings(text, uuid, integer, numeric, numeric, text) to anon, authenticated;
grant execute on function app_private.rpc_save_prospection_logo_background(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_upsert_prospection_category(text, uuid, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_prospection_category(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_reorder_prospection_categories(text, uuid, uuid[]) to anon, authenticated;
grant execute on function app_private.rpc_add_prospection_tag(text, uuid, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_update_prospection_tag(text, uuid, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_reorder_prospection_tags(text, uuid, uuid[]) to anon, authenticated;
grant execute on function app_private.rpc_delete_prospection_tag(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_upsert_prospection_professional(text, uuid, uuid, text, boolean) to anon, authenticated;

revoke all on function public.lc_get_prospection_configuration(text) from public;
revoke all on function public.lc_list_prospections(text) from public;
revoke all on function public.lc_upsert_prospection(text, uuid, uuid, text, text, text, text, text, text[], uuid) from public;
revoke all on function public.lc_set_prospection_outcome(text, uuid, boolean, boolean, numeric, text) from public;
revoke all on function public.lc_delete_prospection(text, uuid) from public;
revoke all on function public.lc_save_prospection_store_settings(text, uuid, integer, numeric, numeric, text) from public;
revoke all on function public.lc_save_prospection_logo_background(text, uuid, text) from public;
revoke all on function public.lc_upsert_prospection_category(text, uuid, uuid, text) from public;
revoke all on function public.lc_delete_prospection_category(text, uuid) from public;
revoke all on function public.lc_reorder_prospection_categories(text, uuid, uuid[]) from public;
revoke all on function public.lc_add_prospection_tag(text, uuid, uuid, text) from public;
revoke all on function public.lc_update_prospection_tag(text, uuid, uuid, text) from public;
revoke all on function public.lc_reorder_prospection_tags(text, uuid, uuid[]) from public;
revoke all on function public.lc_delete_prospection_tag(text, uuid) from public;
revoke all on function public.lc_upsert_prospection_professional(text, uuid, uuid, text, boolean) from public;

grant execute on function public.lc_get_prospection_configuration(text) to anon, authenticated;
grant execute on function public.lc_list_prospections(text) to anon, authenticated;
grant execute on function public.lc_upsert_prospection(text, uuid, uuid, text, text, text, text, text, text[], uuid) to anon, authenticated;
grant execute on function public.lc_set_prospection_outcome(text, uuid, boolean, boolean, numeric, text) to anon, authenticated;
grant execute on function public.lc_delete_prospection(text, uuid) to anon, authenticated;
grant execute on function public.lc_save_prospection_store_settings(text, uuid, integer, numeric, numeric, text) to anon, authenticated;
grant execute on function public.lc_save_prospection_logo_background(text, uuid, text) to anon, authenticated;
grant execute on function public.lc_upsert_prospection_category(text, uuid, uuid, text) to anon, authenticated;
grant execute on function public.lc_delete_prospection_category(text, uuid) to anon, authenticated;
grant execute on function public.lc_reorder_prospection_categories(text, uuid, uuid[]) to anon, authenticated;
grant execute on function public.lc_add_prospection_tag(text, uuid, uuid, text) to anon, authenticated;
grant execute on function public.lc_update_prospection_tag(text, uuid, uuid, text) to anon, authenticated;
grant execute on function public.lc_reorder_prospection_tags(text, uuid, uuid[]) to anon, authenticated;
grant execute on function public.lc_delete_prospection_tag(text, uuid) to anon, authenticated;
grant execute on function public.lc_upsert_prospection_professional(text, uuid, uuid, text, boolean) to anon, authenticated;

-- Exclusao controlada de Clientes e Agencias.
create or replace function app_private.rpc_delete_store_account(
  p_session_token text,
  p_store_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if not app_private.prospection_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id,
    true
  ) then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  update public.stores
  set is_active = false
  where id = p_store_id
    and admin_user_id = v_session.admin_user_id;

  update public.app_users
  set is_active = false
  where store_id = p_store_id
    and admin_user_id = v_session.admin_user_id
    and role::text = 'store';

  update public.app_sessions s
  set revoked_at = coalesce(s.revoked_at, now())
  from public.app_users u
  where s.user_id = u.id
    and u.store_id = p_store_id
    and u.admin_user_id = v_session.admin_user_id;

  return true;
end;
$$;

create or replace function app_private.rpc_delete_agency_account(
  p_session_token text,
  p_agency_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode excluir Agencias.';
  end if;

  if not exists (
    select 1
    from public.app_users u
    where u.id = p_agency_id
      and u.admin_user_id = v_session.admin_user_id
      and u.role::text = 'technician'
  ) then
    raise exception 'Agencia nao encontrada.';
  end if;

  if exists (
    select 1
    from public.stores st
    where st.technician_user_id = p_agency_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true
  ) then
    raise exception 'Exclua ou transfira os clientes ativos antes de excluir esta Agencia.';
  end if;

  delete from public.app_users
  where id = p_agency_id
    and admin_user_id = v_session.admin_user_id
    and role::text = 'technician';

  return true;
end;
$$;

create or replace function public.lc_delete_store_account(p_session_token text, p_store_id uuid)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_store_account(p_session_token, p_store_id);
$$;

create or replace function public.lc_delete_agency_account(p_session_token text, p_agency_id uuid)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_agency_account(p_session_token, p_agency_id);
$$;

revoke all on function app_private.rpc_delete_store_account(text, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_delete_agency_account(text, uuid) from public, anon, authenticated;
grant execute on function app_private.rpc_delete_store_account(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_delete_agency_account(text, uuid) to anon, authenticated;

revoke all on function public.lc_delete_store_account(text, uuid) from public;
revoke all on function public.lc_delete_agency_account(text, uuid) from public;
grant execute on function public.lc_delete_store_account(text, uuid) to anon, authenticated;
grant execute on function public.lc_delete_agency_account(text, uuid) to anon, authenticated;

-- ATUALIZACAO INCREMENTAL: LICENCAS DE PROSPECCOES
-- O bloco abaixo tambem esta disponivel isoladamente em
-- prospection_access_control_update.sql. Nao altera retornos de RPCs existentes.

alter table public.app_users
  add column if not exists prospection_store_limit integer not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'app_users_prospection_store_limit_check'
      and conrelid = 'public.app_users'::regclass
  ) then
    alter table public.app_users
      add constraint app_users_prospection_store_limit_check
      check (prospection_store_limit between 0 and 9999);
  end if;
end $$;

alter table public.stores
  add column if not exists prospection_enabled boolean not null default true;

alter table public.stores
  alter column prospection_enabled set default false;

update public.app_users agency
set prospection_store_limit = greatest(
  agency.prospection_store_limit,
  (
    select count(*)::integer
    from public.stores st
    where (
        st.technician_user_id = agency.id
        or (
          st.technician_user_id is null
          and 1 = (
            select count(*) from public.app_users only_agency
            where only_agency.admin_user_id = agency.admin_user_id
              and only_agency.role::text = 'technician'
              and only_agency.is_active = true
          )
        )
      )
      and st.is_active = true
      and st.prospection_enabled = true
  )
)
where agency.role::text = 'technician';

create index if not exists stores_technician_prospection_enabled_idx
  on public.stores (technician_user_id, prospection_enabled)
  where is_active = true;

create or replace function app_private.enforce_prospection_store_quota()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_limit integer;
  v_in_use integer;
begin
  if tg_op = 'UPDATE' then
    if old.technician_user_id is not distinct from new.technician_user_id
       and old.admin_user_id is not distinct from new.admin_user_id
       and old.is_active is not distinct from new.is_active
       and old.prospection_enabled is not distinct from new.prospection_enabled then
      return new;
    end if;
  end if;

  if new.is_active is distinct from true or new.prospection_enabled is distinct from true then return new; end if;
  if new.technician_user_id is null then raise exception 'Defina a agencia responsavel antes de liberar Prospeccoes.'; end if;

  select u.prospection_store_limit into v_limit
  from public.app_users u
  where u.id = new.technician_user_id
    and u.admin_user_id = new.admin_user_id
    and u.role::text = 'technician'
    and u.is_active = true
  for update;
  if not found then raise exception 'Agencia responsavel nao encontrada ou inativa.'; end if;

  select count(*)::integer into v_in_use
  from public.stores st
  where st.technician_user_id = new.technician_user_id
    and st.admin_user_id = new.admin_user_id
    and st.is_active = true
    and st.prospection_enabled = true
    and st.id <> new.id;
  if v_in_use >= v_limit then
    raise exception 'Limite de clientes com Prospeccoes atingido (% de %).', v_in_use, v_limit;
  end if;
  return new;
end;
$$;

drop trigger if exists stores_enforce_prospection_quota on public.stores;
create trigger stores_enforce_prospection_quota
before insert or update of technician_user_id, admin_user_id, is_active, prospection_enabled on public.stores
for each row execute function app_private.enforce_prospection_store_quota();

create or replace function app_private.rpc_get_prospection_entitlements(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  return jsonb_build_object(
    'profile', jsonb_build_object(
      'role', v_session.user_role::text,
      'prospection_store_limit', case when v_session.user_role::text = 'technician' then coalesce((select u.prospection_store_limit from public.app_users u where u.id = v_session.user_id), 0) else 0 end,
      'prospection_store_count', case when v_session.user_role::text = 'technician' then (select count(*) from public.stores st where st.admin_user_id = v_session.admin_user_id and st.technician_user_id = v_session.user_id and st.is_active = true and st.prospection_enabled = true) else 0 end
    ),
    'stores', coalesce((
      select jsonb_agg(jsonb_build_object('store_id', st.id, 'technician_id', st.technician_user_id, 'prospection_enabled', st.prospection_enabled) order by st.created_at)
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id and st.is_active = true
        and (v_session.user_role::text = 'admin' or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id) or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id))
    ), '[]'::jsonb),
    'technicians', coalesce((
      select jsonb_agg(jsonb_build_object(
        'technician_id', u.id,
        'prospection_store_limit', u.prospection_store_limit,
        'prospection_store_count', (select count(*) from public.stores st where st.admin_user_id = v_session.admin_user_id and st.technician_user_id = u.id and st.is_active = true and st.prospection_enabled = true)
      ) order by u.full_name, u.nick)
      from public.app_users u
      where u.admin_user_id = v_session.admin_user_id and u.role::text = 'technician' and u.is_active = true
        and (v_session.user_role::text = 'admin' or u.id = v_session.user_id)
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app_private.rpc_set_technician_prospection_limit(p_session_token text, p_technician_id uuid, p_limit integer)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare v_session record; v_store_limit integer;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text <> 'admin' then raise exception 'Apenas o Admin pode alterar o limite de Prospeccoes.'; end if;
  if coalesce(p_limit, -1) not between 0 and 9999 then raise exception 'Informe um limite de Prospeccoes entre 0 e 9999.'; end if;
  select u.store_limit into v_store_limit from public.app_users u where u.id = p_technician_id and u.admin_user_id = v_session.admin_user_id and u.role::text = 'technician' and u.is_active = true for update;
  if not found then raise exception 'Agencia nao encontrada.'; end if;
  if p_limit > v_store_limit then raise exception 'O limite de Prospeccoes nao pode superar o limite total de % clientes.', v_store_limit; end if;
  update public.app_users set prospection_store_limit = p_limit where id = p_technician_id;
  return true;
end;
$$;

create or replace function app_private.rpc_set_store_prospection_access(p_session_token text, p_store_id uuid, p_enabled boolean)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare v_session record; v_store record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text not in ('admin', 'technician') then raise exception 'Somente o Admin ou a Agencia podem alterar este acesso.'; end if;
  select st.* into v_store from public.stores st
  where st.id = p_store_id and st.admin_user_id = v_session.admin_user_id and st.is_active = true
    and (v_session.user_role::text = 'admin' or st.technician_user_id = v_session.user_id)
  for update;
  if not found then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  update public.stores set prospection_enabled = coalesce(p_enabled, false) where id = p_store_id;
  return true;
end;
$$;

create or replace function public.lc_get_prospection_entitlements(p_session_token text) returns jsonb language sql security invoker as $$ select app_private.rpc_get_prospection_entitlements(p_session_token); $$;
create or replace function public.lc_set_technician_prospection_limit(p_session_token text, p_technician_id uuid, p_limit integer) returns boolean language sql security invoker as $$ select app_private.rpc_set_technician_prospection_limit(p_session_token, p_technician_id, p_limit); $$;
create or replace function public.lc_set_store_prospection_access(p_session_token text, p_store_id uuid, p_enabled boolean) returns boolean language sql security invoker as $$ select app_private.rpc_set_store_prospection_access(p_session_token, p_store_id, p_enabled); $$;

create or replace function app_private.prospection_store_allowed(p_admin_user_id uuid, p_user_id uuid, p_user_role public.app_user_role, p_user_store_id uuid, p_store_id uuid, p_management_only boolean default false)
returns boolean language sql stable security definer set search_path = app_private, public, extensions as $$
  select exists (
    select 1 from public.stores st
    where st.id = p_store_id and st.admin_user_id = p_admin_user_id and st.is_active = true and st.prospection_enabled = true
      and (p_user_role::text = 'admin' or (p_user_role::text = 'technician' and st.technician_user_id = p_user_id) or (coalesce(p_management_only, false) = false and p_user_role::text = 'store' and st.id = p_user_store_id))
  );
$$;

create or replace function app_private.rpc_delete_store_account(p_session_token text, p_store_id uuid)
returns boolean language plpgsql security definer set search_path = app_private, public, extensions as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not exists (select 1 from public.stores st where st.id = p_store_id and st.admin_user_id = v_session.admin_user_id and st.is_active = true and (v_session.user_role::text = 'admin' or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id))) then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  update public.stores set is_active = false where id = p_store_id;
  update public.app_users set is_active = false where store_id = p_store_id and admin_user_id = v_session.admin_user_id and role::text = 'store';
  update public.app_sessions s set revoked_at = coalesce(s.revoked_at, now()) from public.app_users u where s.user_id = u.id and u.store_id = p_store_id and u.admin_user_id = v_session.admin_user_id;
  return true;
end;
$$;

revoke all on function app_private.enforce_prospection_store_quota() from public, anon, authenticated;
revoke all on function app_private.rpc_get_prospection_entitlements(text) from public, anon, authenticated;
revoke all on function app_private.rpc_set_technician_prospection_limit(text, uuid, integer) from public, anon, authenticated;
revoke all on function app_private.rpc_set_store_prospection_access(text, uuid, boolean) from public, anon, authenticated;
revoke all on function app_private.prospection_store_allowed(uuid, uuid, public.app_user_role, uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function app_private.rpc_get_prospection_entitlements(text) to anon, authenticated;
grant execute on function app_private.rpc_set_technician_prospection_limit(text, uuid, integer) to anon, authenticated;
grant execute on function app_private.rpc_set_store_prospection_access(text, uuid, boolean) to anon, authenticated;
revoke all on function public.lc_get_prospection_entitlements(text) from public;
revoke all on function public.lc_set_technician_prospection_limit(text, uuid, integer) from public;
revoke all on function public.lc_set_store_prospection_access(text, uuid, boolean) from public;
grant execute on function public.lc_get_prospection_entitlements(text) to anon, authenticated;
grant execute on function public.lc_set_technician_prospection_limit(text, uuid, integer) to anon, authenticated;
grant execute on function public.lc_set_store_prospection_access(text, uuid, boolean) to anon, authenticated;
-- CONSOLIDACAO B2B INTEGRADA AO BANCO COMPLETO
-- Hierarquia B2B: admin -> empresa de trafego (technician) -> lojas.
-- Rode este arquivo no SQL Editor do Supabase depois das migracoes existentes.

begin;

set search_path = public, extensions;

alter table public.app_users
  add column if not exists store_limit integer not null default 5;

update public.app_users
set store_limit = 0
where role::text <> 'technician'
  and store_limit <> 0;

alter table public.app_users
  alter column store_limit set default 0;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'app_users_store_limit_check'
      and conrelid = 'public.app_users'::regclass
  ) then
    alter table public.app_users
      add constraint app_users_store_limit_check
      check (store_limit between 0 and 9999);
  end if;
end;
$$;

alter table public.stores
  add column if not exists technician_user_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'stores_technician_user_fk'
      and conrelid = 'public.stores'::regclass
  ) then
    alter table public.stores
      add constraint stores_technician_user_fk
      foreign key (technician_user_id)
      references public.app_users(id)
      on delete set null;
  end if;
end;
$$;

-- Preserva instalacoes antigas: quando um admin tem uma unica empresa,
-- associa automaticamente a ela as lojas que ainda nao tinham responsavel.
with single_technician as (
  select admin_user_id, min(id::text)::uuid as technician_user_id
  from public.app_users
  where role::text = 'technician'
    and is_active = true
  group by admin_user_id
  having count(*) = 1
)
update public.stores st
set technician_user_id = single_technician.technician_user_id
from single_technician
where st.admin_user_id = single_technician.admin_user_id
  and st.technician_user_id is null;

create index if not exists stores_technician_active_created_idx
  on public.stores (technician_user_id, is_active, created_at desc);

create or replace function app_private.technician_can_access_store(
  p_admin_user_id uuid,
  p_technician_user_id uuid,
  p_store_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  select exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = p_admin_user_id
      and st.technician_user_id = p_technician_user_id
      and st.is_active = true
  );
$$;

-- Criacao de empresas com limite definido pelo admin.
drop function if exists public.lc_create_technician(text, text, text, text);
drop function if exists app_private.rpc_create_technician(text, text, text, text);

create or replace function app_private.rpc_create_technician(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer default 5
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_user_id uuid;
  v_nick_key text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o admin pode criar uma empresa.';
  end if;

  if length(btrim(coalesce(p_full_name, ''))) = 0 then
    raise exception 'Digite o nome da empresa.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para a empresa.';
  end if;

  if length(coalesce(p_password, '')) < 6 then
    raise exception 'A senha da empresa precisa ter pelo menos 6 caracteres.';
  end if;

  if coalesce(p_store_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de clientes entre 0 e 9999.';
  end if;

  if exists (select 1 from public.app_users au where au.nick_key = v_nick_key) then
    raise exception 'Esse login ja existe.';
  end if;

  insert into public.app_users as new_user (
    nick,
    password_hash,
    full_name,
    role,
    admin_user_id,
    store_id,
    store_limit
  )
  values (
    v_nick_key,
    crypt(p_password, gen_salt('bf')),
    btrim(p_full_name),
    'technician',
    v_session.admin_user_id,
    null,
    p_store_limit
  )
  returning new_user.id into v_user_id;

  return query
  select
    u.id,
    u.nick_key,
    u.full_name,
    u.is_active,
    u.created_at,
    u.store_limit,
    0::bigint
  from public.app_users u
  where u.id = v_user_id;
end;
$$;

create or replace function public.lc_create_technician(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer default 5
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_create_technician(
    p_session_token,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit
  );
$$;

-- Listagem das empresas com consumo atual da franquia.
drop function if exists public.lc_list_technicians(text);
drop function if exists app_private.rpc_list_technicians(text);

create or replace function app_private.rpc_list_technicians(p_session_token text)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o admin pode listar empresas.';
  end if;

  return query
  select
    u.id,
    u.nick_key,
    u.full_name,
    u.is_active,
    u.created_at,
    u.store_limit,
    count(st.id) filter (where st.is_active = true) as store_count
  from public.app_users u
  left join public.stores st on st.technician_user_id = u.id
  where u.admin_user_id = v_session.admin_user_id
    and u.role::text = 'technician'
  group by u.id
  order by u.created_at desc;
end;
$$;

create or replace function public.lc_list_technicians(p_session_token text)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_technicians(p_session_token);
$$;

-- Alteracao de credenciais e limite da empresa.
drop function if exists public.lc_update_technician_account(text, uuid, text, text, text);
drop function if exists app_private.rpc_update_technician_account(text, uuid, text, text, text);

create or replace function app_private.rpc_update_technician_account(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_nick_key text;
  v_password text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o admin pode editar uma empresa.';
  end if;

  if length(btrim(coalesce(p_full_name, ''))) = 0 then
    raise exception 'Digite o nome da empresa.';
  end if;

  if coalesce(p_store_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de clientes entre 0 e 9999.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para a empresa.';
  end if;

  v_password := nullif(coalesce(p_password, ''), '');
  if v_password is not null and length(v_password) < 6 then
    raise exception 'A nova senha precisa ter pelo menos 6 caracteres.';
  end if;

  if not exists (
    select 1
    from public.app_users au
    where au.id = p_technician_id
      and au.admin_user_id = v_session.admin_user_id
      and au.role::text = 'technician'
      and au.is_active = true
  ) then
    raise exception 'Empresa nao encontrada.';
  end if;

  if exists (
    select 1
    from public.app_users au
    where au.nick_key = v_nick_key
      and au.id <> p_technician_id
  ) then
    raise exception 'Esse login ja existe.';
  end if;

  update public.app_users au
  set
    nick = v_nick_key,
    full_name = btrim(p_full_name),
    store_limit = p_store_limit,
    password_hash = case
      when v_password is null then au.password_hash
      else crypt(v_password, gen_salt('bf'))
    end
  where au.id = p_technician_id
    and au.admin_user_id = v_session.admin_user_id
    and au.role::text = 'technician';

  return query
  select
    au.id,
    au.nick_key,
    au.full_name,
    au.is_active,
    au.created_at,
    au.store_limit,
    count(st.id) filter (where st.is_active = true) as store_count
  from public.app_users au
  left join public.stores st on st.technician_user_id = au.id
  where au.id = p_technician_id
  group by au.id;
end;
$$;

create or replace function public.lc_update_technician_account(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_update_technician_account(
    p_session_token,
    p_technician_id,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit
  );
$$;

-- Criacao de loja pela propria empresa, com bloqueio concorrente do limite.
drop function if exists public.lc_create_store(text, text, text, text);
drop function if exists app_private.rpc_create_store(text, text, text, text);

create or replace function app_private.rpc_create_store(
  p_session_token text,
  p_name text,
  p_nick text,
  p_password text,
  p_technician_id uuid default null
)
returns table (
  store_id uuid,
  store_name text,
  store_nick text,
  user_id uuid,
  user_nick text,
  technician_id uuid
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_user_id uuid;
  v_nick_key text;
  v_technician_id uuid;
  v_store_limit integer;
  v_store_count bigint;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'technician' then
    v_technician_id := v_session.user_id;
    if p_technician_id is not null and p_technician_id <> v_session.user_id then
      raise exception 'Empresa sem permissao para criar esta loja.';
    end if;
  elsif v_session.user_role::text = 'admin' then
    v_technician_id := p_technician_id;
  else
    raise exception 'Apenas o admin ou a empresa podem criar lojas.';
  end if;

  if v_technician_id is null then
    raise exception 'Selecione a empresa responsavel pela loja.';
  end if;

  -- O lock impede que cadastros simultaneos ultrapassem a franquia.
  select au.store_limit
  into v_store_limit
  from public.app_users au
  where au.id = v_technician_id
    and au.admin_user_id = v_session.admin_user_id
    and au.role::text = 'technician'
    and au.is_active = true
  for update;

  if not found then
    raise exception 'Empresa nao encontrada ou inativa.';
  end if;

  select count(*)
  into v_store_count
  from public.stores st
  where st.technician_user_id = v_technician_id
    and st.is_active = true;

  if v_store_count >= v_store_limit then
    raise exception 'Limite de clientes atingido (% de %).', v_store_count, v_store_limit;
  end if;

  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'Digite o nome da loja.';
  end if;

  if length(coalesce(p_password, '')) < 6 then
    raise exception 'A senha da loja precisa ter pelo menos 6 caracteres.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para a loja.';
  end if;

  if exists (select 1 from public.app_users au where au.nick_key = v_nick_key) then
    raise exception 'Esse login ja existe.';
  end if;

  insert into public.stores (admin_user_id, technician_user_id, name, nick)
  values (v_session.admin_user_id, v_technician_id, btrim(p_name), v_nick_key)
  returning id into v_store_id;

  insert into public.app_users (nick, password_hash, full_name, role, admin_user_id, store_id, store_limit)
  values (
    v_nick_key,
    crypt(p_password, gen_salt('bf')),
    btrim(p_name),
    'store',
    v_session.admin_user_id,
    v_store_id,
    0
  )
  returning id into v_user_id;

  return query
  select st.id, st.name, st.nick_key, u.id, u.nick_key, st.technician_user_id
  from public.stores st
  join public.app_users u on u.store_id = st.id and u.role::text = 'store'
  where st.id = v_store_id;
end;
$$;

create or replace function public.lc_create_store(
  p_session_token text,
  p_name text,
  p_nick text,
  p_password text,
  p_technician_id uuid default null
)
returns table (
  store_id uuid,
  store_name text,
  store_nick text,
  user_id uuid,
  user_nick text,
  technician_id uuid
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_create_store(
    p_session_token,
    p_name,
    p_nick,
    p_password,
    p_technician_id
  );
$$;

-- Cada papel ve apenas as lojas do seu escopo.
drop function if exists public.lc_list_stores(text);
drop function if exists app_private.rpc_list_stores(text);

create or replace function app_private.rpc_list_stores(p_session_token text)
returns table (
  id uuid,
  name text,
  nick text,
  created_at timestamptz,
  leads_count bigint,
  sales_count bigint,
  technician_id uuid,
  technician_name text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select
    st.id,
    st.name,
    st.nick_key,
    st.created_at,
    count(l.id) as leads_count,
    count(l.id) filter (where l.bought = 'Sim') as sales_count,
    st.technician_user_id,
    tech.full_name
  from public.stores st
  left join public.app_users tech on tech.id = st.technician_user_id
  left join public.leads l on l.store_id = st.id and l.admin_user_id = st.admin_user_id
  where st.is_active = true
    and st.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
    )
  group by st.id, tech.full_name
  order by st.created_at desc;
end;
$$;

create or replace function public.lc_list_stores(p_session_token text)
returns table (
  id uuid,
  name text,
  nick text,
  created_at timestamptz,
  leads_count bigint,
  sales_count bigint,
  technician_id uuid,
  technician_name text
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_stores(p_session_token);
$$;

-- A empresa pode trocar nome/login/senha apenas das lojas da propria carteira.
drop function if exists public.lc_update_store_account(text, uuid, text, text, text);
drop function if exists public.lc_update_store_account(text, uuid, text, text, text, uuid);
drop function if exists app_private.rpc_update_store_account(text, uuid, text, text, text);
drop function if exists app_private.rpc_update_store_account(text, uuid, text, text, text, uuid);

create or replace function app_private.rpc_update_store_account(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null
)
returns table (
  id uuid,
  name text,
  nick text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_nick_key text;
  v_password text;
  v_technician_id uuid;
  v_current_technician_id uuid;
  v_store_limit integer;
  v_store_count bigint;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Sem permissao para editar esta loja.';
  end if;

  if v_session.user_role::text = 'technician' then
    v_technician_id := v_session.user_id;
    if p_technician_id is not null and p_technician_id <> v_session.user_id then
      raise exception 'Empresa sem permissao para transferir esta loja.';
    end if;
  else
    v_technician_id := p_technician_id;
  end if;

  if v_technician_id is null then
    raise exception 'Selecione a empresa responsavel pela loja.';
  end if;

  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'Digite o nome da loja.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para a loja.';
  end if;

  v_password := nullif(coalesce(p_password, ''), '');
  if v_password is not null and length(v_password) < 6 then
    raise exception 'A nova senha precisa ter pelo menos 6 caracteres.';
  end if;

  select st.technician_user_id
  into v_current_technician_id
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true
      and (
        v_session.user_role::text = 'admin'
        or st.technician_user_id = v_session.user_id
      );

  if not found then
    raise exception 'Loja nao encontrada ou sem permissao.';
  end if;

  select au.store_limit
  into v_store_limit
  from public.app_users au
  where au.id = v_technician_id
    and au.admin_user_id = v_session.admin_user_id
    and au.role::text = 'technician'
    and au.is_active = true
  for update;

  if not found then
    raise exception 'Empresa nao encontrada ou inativa.';
  end if;

  if v_current_technician_id is distinct from v_technician_id then
    select count(*)
    into v_store_count
    from public.stores st
    where st.technician_user_id = v_technician_id
      and st.is_active = true;

    if v_store_count >= v_store_limit then
      raise exception 'Limite de clientes da empresa de destino atingido (% de %).', v_store_count, v_store_limit;
    end if;
  end if;

  if exists (
    select 1
    from public.app_users au
    where au.nick_key = v_nick_key
      and not (au.role::text = 'store' and au.store_id = p_store_id)
  ) or exists (
    select 1
    from public.stores st
    where st.nick_key = v_nick_key
      and st.id <> p_store_id
  ) then
    raise exception 'Esse login ja existe.';
  end if;

  update public.stores st
  set
    name = btrim(p_name),
    nick = v_nick_key,
    technician_user_id = v_technician_id
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id;

  update public.app_users au
  set
    nick = v_nick_key,
    full_name = btrim(p_name),
    password_hash = case
      when v_password is null then au.password_hash
      else crypt(v_password, gen_salt('bf'))
    end
  where au.role::text = 'store'
    and au.store_id = p_store_id
    and au.admin_user_id = v_session.admin_user_id
    and au.is_active = true;

  if not found then
    raise exception 'Usuario da loja nao encontrado.';
  end if;

  return query
  select st.id, st.name, st.nick_key
  from public.stores st
  where st.id = p_store_id;
end;
$$;

create or replace function public.lc_update_store_account(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null
)
returns table (
  id uuid,
  name text,
  nick text
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_update_store_account(
    p_session_token,
    p_store_id,
    p_name,
    p_nick,
    p_password,
    p_technician_id
  );
$$;

-- Indicador da franquia para o painel da empresa.
create or replace function app_private.rpc_account_usage(p_session_token text)
returns table (
  technician_id uuid,
  store_limit integer,
  store_count bigint
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'technician' then
    raise exception 'Indicador disponivel apenas para empresas.';
  end if;

  return query
  select
    u.id,
    u.store_limit,
    count(st.id) filter (where st.is_active = true) as store_count
  from public.app_users u
  left join public.stores st on st.technician_user_id = u.id
  where u.id = v_session.user_id
  group by u.id;
end;
$$;

create or replace function public.lc_account_usage(p_session_token text)
returns table (
  technician_id uuid,
  store_limit integer,
  store_count bigint
)
language sql
security invoker
as $$
  select * from app_private.rpc_account_usage(p_session_token);
$$;

-- Leitura dos leads isolada por empresa em uma funcao nova. O nome separado
-- torna a migracao compativel com as duas versoes antigas de contact_date.
create or replace function app_private.rpc_list_leads_b2b(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  contact_date date,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  scheduled text,
  scheduled_visit_date date,
  scheduled_visit_time time,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  inspected boolean,
  custom_values jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select
    l.id,
    l.store_id,
    st.name,
    l.name,
    l.phone,
    l.contact_date,
    l.channel,
    l.campaign,
    l.conversation_start,
    l.conclusion,
    l.scheduled,
    l.scheduled_visit_date,
    l.scheduled_visit_time,
    l.visited,
    l.bought,
    l.purchase_amount,
    l.service_order,
    l.notes,
    l.inspected,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'category_id', c.id,
          'category_name', c.name,
          'value', v.value
        )
        order by c.sort_order, c.created_at
      )
      from public.lead_custom_values v
      join public.lead_custom_categories c
        on c.id = v.category_id
       and c.admin_user_id = v.admin_user_id
       and c.is_active = true
      where v.lead_id = l.id
        and v.admin_user_id = l.admin_user_id
    ), '[]'::jsonb),
    l.created_at,
    l.updated_at
  from public.leads l
  join public.stores st on st.id = l.store_id
  where l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
    )
  order by l.created_at desc;
end;
$$;

drop function if exists public.lc_list_leads(text);

create or replace function public.lc_list_leads(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  contact_date date,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  scheduled text,
  scheduled_visit_date date,
  scheduled_visit_time time,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  inspected boolean,
  custom_values jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_leads_b2b(p_session_token);
$$;

-- A API publica valida a carteira antes de encaminhar qualquer gravacao.
-- Isso impede que uma empresa use manualmente o RPC para gravar em outra loja.
create or replace function public.lc_upsert_lead(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_scheduled text default null,
  p_scheduled_visit_date date default null,
  p_scheduled_visit_time time default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_custom_values jsonb default '[]'::jsonb,
  p_store_id uuid default null,
  p_contact_date date default null
)
returns uuid
language plpgsql
security invoker
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_lead_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := p_store_id;

  if v_store_id is null and p_lead_id is not null then
    select l.store_id
    into v_store_id
    from public.leads l
    where l.id = p_lead_id
      and l.admin_user_id = v_session.admin_user_id;
  end if;

  if v_session.user_role::text = 'technician'
     and not app_private.technician_can_access_store(
       v_session.admin_user_id,
       v_session.user_id,
       v_store_id
     ) then
    raise exception 'Loja nao encontrada ou sem permissao.';
  end if;

  v_lead_id := app_private.rpc_upsert_lead(
    p_session_token,
    p_lead_id,
    p_name,
    p_phone,
    p_channel,
    p_campaign,
    p_conversation_start,
    p_conclusion,
    p_scheduled,
    p_scheduled_visit_date,
    p_scheduled_visit_time,
    p_visited,
    p_bought,
    p_purchase_amount,
    p_service_order,
    p_notes,
    p_custom_values,
    p_store_id
  );

  perform app_private.rpc_set_lead_contact_date(
    p_session_token,
    v_lead_id,
    p_contact_date
  );

  return v_lead_id;
end;
$$;

create or replace function app_private.rpc_set_lead_inspected(
  p_session_token text,
  p_lead_id uuid,
  p_inspected boolean
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  update public.leads l
  set
    inspected = coalesce(p_inspected, false),
    updated_by = v_session.user_id
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          l.store_id
        )
      )
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_set_lead_contact_date(
  p_session_token text,
  p_lead_id uuid,
  p_contact_date date default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  update public.leads l
  set
    contact_date = coalesce(p_contact_date, l.contact_date, (timezone('America/Sao_Paulo', now()))::date),
    updated_by = v_session.user_id
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          l.store_id
        )
      )
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_delete_lead(
  p_session_token text,
  p_lead_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  delete from public.leads l
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          l.store_id
        )
      )
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

-- Mantem os grants das funcoes substituidas e registra as novas assinaturas.
grant execute on function app_private.technician_can_access_store(uuid, uuid, uuid) to anon, authenticated;
grant execute on function app_private.rpc_create_technician(text, text, text, text, integer) to anon, authenticated;
grant execute on function public.lc_create_technician(text, text, text, text, integer) to anon, authenticated;
grant execute on function app_private.rpc_list_technicians(text) to anon, authenticated;
grant execute on function public.lc_list_technicians(text) to anon, authenticated;
grant execute on function app_private.rpc_update_technician_account(text, uuid, text, text, text, integer) to anon, authenticated;
grant execute on function public.lc_update_technician_account(text, uuid, text, text, text, integer) to anon, authenticated;
grant execute on function app_private.rpc_create_store(text, text, text, text, uuid) to anon, authenticated;
grant execute on function public.lc_create_store(text, text, text, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_list_stores(text) to anon, authenticated;
grant execute on function public.lc_list_stores(text) to anon, authenticated;
grant execute on function app_private.rpc_update_store_account(text, uuid, text, text, text, uuid) to anon, authenticated;
grant execute on function public.lc_update_store_account(text, uuid, text, text, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_account_usage(text) to anon, authenticated;
grant execute on function public.lc_account_usage(text) to anon, authenticated;
grant execute on function app_private.rpc_list_leads_b2b(text) to anon, authenticated;
grant execute on function public.lc_list_leads(text) to anon, authenticated;
grant execute on function app_private.rpc_set_lead_inspected(text, uuid, boolean) to anon, authenticated;
grant execute on function app_private.rpc_set_lead_contact_date(text, uuid, date) to anon, authenticated;
grant execute on function app_private.rpc_delete_lead(text, uuid) to anon, authenticated;
grant execute on function public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date) to anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- Fonte integrada: agency_whatsapp_upgrade_update.sql
-- WhatsApp comercial da agencia e pedido de upgrade identificado.
-- Migracao incremental: nao altera o retorno de RPCs existentes.

begin;

set search_path = public, extensions;

alter table public.app_users
  add column if not exists whatsapp_phone text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'app_users_whatsapp_phone_check'
      and conrelid = 'public.app_users'::regclass
  ) then
    alter table public.app_users
      add constraint app_users_whatsapp_phone_check
      check (
        whatsapp_phone is null
        or whatsapp_phone ~ '^[1-9][0-9]{11,14}$'
      );
  end if;
end $$;

create or replace function app_private.normalize_agency_whatsapp(p_value text)
returns text
language plpgsql
immutable
as $$
declare
  v_digits text;
begin
  v_digits := regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g');

  if length(v_digits) in (10, 11) then
    v_digits := '55' || v_digits;
  end if;

  if v_digits !~ '^[1-9][0-9]{11,14}$' then
    raise exception 'Informe um WhatsApp valido com DDD.';
  end if;

  return v_digits;
end;
$$;

create or replace function app_private.rpc_set_agency_whatsapp(
  p_session_token text,
  p_whatsapp text,
  p_technician_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_target_id uuid;
  v_phone text;
  v_agency record;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'admin' then
    v_target_id := p_technician_id;
  elsif v_session.user_role::text = 'technician' then
    if p_technician_id is not null and p_technician_id <> v_session.user_id then
      raise exception 'A Agencia pode alterar apenas o proprio WhatsApp.';
    end if;
    v_target_id := v_session.user_id;
  else
    raise exception 'Apenas o Admin ou a Agencia podem alterar este WhatsApp.';
  end if;

  if v_target_id is null then
    raise exception 'Informe a Agencia responsavel.';
  end if;

  select u.id, u.full_name, u.nick_key
  into v_agency
  from public.app_users u
  where u.id = v_target_id
    and u.admin_user_id = v_session.admin_user_id
    and u.role::text = 'technician'
    and u.is_active = true
  for update;

  if not found then
    raise exception 'Agencia nao encontrada ou sem permissao.';
  end if;

  v_phone := app_private.normalize_agency_whatsapp(p_whatsapp);

  update public.app_users
  set whatsapp_phone = v_phone,
      updated_at = now()
  where id = v_target_id;

  return jsonb_build_object(
    'technician_id', v_agency.id,
    'agency_name', v_agency.full_name,
    'agency_login', v_agency.nick_key,
    'whatsapp', v_phone
  );
end;
$$;

create or replace function public.lc_set_agency_whatsapp(
  p_session_token text,
  p_whatsapp text,
  p_technician_id uuid default null
)
returns jsonb
language sql
security invoker
as $$
  select app_private.rpc_set_agency_whatsapp(
    p_session_token,
    p_whatsapp,
    p_technician_id
  );
$$;

create or replace function app_private.rpc_get_agency_whatsapp_context(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_profile jsonb;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'technician' then
    select jsonb_build_object(
      'agency_id', u.id,
      'agency_name', u.full_name,
      'agency_login', u.nick_key,
      'agency_whatsapp', u.whatsapp_phone,
      'requester_name', u.full_name,
      'requester_login', u.nick_key
    )
    into v_profile
    from public.app_users u
    where u.id = v_session.user_id;
  elsif v_session.user_role::text = 'store' then
    select jsonb_build_object(
      'agency_id', tech.id,
      'agency_name', tech.full_name,
      'agency_login', tech.nick_key,
      'agency_whatsapp', tech.whatsapp_phone,
      'store_id', st.id,
      'store_name', st.name,
      'requester_name', requester.full_name,
      'requester_login', requester.nick_key
    )
    into v_profile
    from public.stores st
    join public.app_users requester on requester.id = v_session.user_id
    left join public.app_users tech on tech.id = st.technician_user_id
    where st.id = v_session.user_store_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true;
  else
    v_profile := jsonb_build_object(
      'requester_name', (select u.full_name from public.app_users u where u.id = v_session.user_id),
      'requester_login', (select u.nick_key from public.app_users u where u.id = v_session.user_id)
    );
  end if;

  return jsonb_build_object(
    'profile', coalesce(v_profile, '{}'::jsonb),
    'agencies', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'technician_id', u.id,
          'agency_name', u.full_name,
          'agency_login', u.nick_key,
          'whatsapp', u.whatsapp_phone
        )
        order by u.full_name, u.nick_key
      )
      from public.app_users u
      where u.admin_user_id = v_session.admin_user_id
        and u.role::text = 'technician'
        and u.is_active = true
        and (
          v_session.user_role::text = 'admin'
          or u.id = v_session.user_id
        )
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.lc_get_agency_whatsapp_context(p_session_token text)
returns jsonb
language sql
security invoker
as $$
  select app_private.rpc_get_agency_whatsapp_context(p_session_token);
$$;

create or replace function app_private.rpc_create_technician_with_whatsapp(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer,
  p_whatsapp text
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_created record;
  v_contact jsonb;
begin
  select * into strict v_created
  from app_private.rpc_create_technician(
    p_session_token,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit
  );

  v_contact := app_private.rpc_set_agency_whatsapp(
    p_session_token,
    p_whatsapp,
    v_created.id
  );

  return to_jsonb(v_created) || v_contact;
end;
$$;

create or replace function public.lc_create_technician_with_whatsapp(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer,
  p_whatsapp text
)
returns jsonb
language sql
security invoker
as $$
  select app_private.rpc_create_technician_with_whatsapp(
    p_session_token,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit,
    p_whatsapp
  );
$$;

create or replace function app_private.rpc_update_technician_with_whatsapp(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5,
  p_whatsapp text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_updated record;
  v_contact jsonb;
begin
  select * into strict v_updated
  from app_private.rpc_update_technician_account(
    p_session_token,
    p_technician_id,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit
  );

  v_contact := app_private.rpc_set_agency_whatsapp(
    p_session_token,
    p_whatsapp,
    p_technician_id
  );

  return to_jsonb(v_updated) || v_contact;
end;
$$;

create or replace function public.lc_update_technician_with_whatsapp(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5,
  p_whatsapp text default null
)
returns jsonb
language sql
security invoker
as $$
  select app_private.rpc_update_technician_with_whatsapp(
    p_session_token,
    p_technician_id,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit,
    p_whatsapp
  );
$$;

revoke all on function app_private.normalize_agency_whatsapp(text) from public, anon, authenticated;
revoke all on function app_private.rpc_set_agency_whatsapp(text, text, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_get_agency_whatsapp_context(text) from public, anon, authenticated;
revoke all on function app_private.rpc_create_technician_with_whatsapp(text, text, text, text, integer, text) from public, anon, authenticated;
revoke all on function app_private.rpc_update_technician_with_whatsapp(text, uuid, text, text, text, integer, text) from public, anon, authenticated;

revoke all on function public.lc_set_agency_whatsapp(text, text, uuid) from public;
revoke all on function public.lc_get_agency_whatsapp_context(text) from public;
revoke all on function public.lc_create_technician_with_whatsapp(text, text, text, text, integer, text) from public;
revoke all on function public.lc_update_technician_with_whatsapp(text, uuid, text, text, text, integer, text) from public;

grant execute on function app_private.rpc_set_agency_whatsapp(text, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_get_agency_whatsapp_context(text) to anon, authenticated;
grant execute on function app_private.rpc_create_technician_with_whatsapp(text, text, text, text, integer, text) to anon, authenticated;
grant execute on function app_private.rpc_update_technician_with_whatsapp(text, uuid, text, text, text, integer, text) to anon, authenticated;

grant execute on function public.lc_set_agency_whatsapp(text, text, uuid) to anon, authenticated;
grant execute on function public.lc_get_agency_whatsapp_context(text) to anon, authenticated;
grant execute on function public.lc_create_technician_with_whatsapp(text, text, text, text, integer, text) to anon, authenticated;
grant execute on function public.lc_update_technician_with_whatsapp(text, uuid, text, text, text, integer, text) to anon, authenticated;

notify pgrst, 'reload schema';

commit;
-- CONSOLIDACAO DO BANCO COMPLETO | GOVERNANCA, TERMOS E RETENCAO
-- A mesma secao tambem existe em legal_terms_retention_access_update.sql para
-- atualizacao segura de bancos que ja estao em producao.
-- =============================================================================

-- Controle de Leads + Prospecções
-- Atualização incremental: licenças, exportação pós-downgrade, retenção de
-- dois anos e aceite versionado dos Termos de Uso.
-- Rode este arquivo uma única vez no SQL Editor do Supabase.

begin;

set local search_path = public, extensions;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists app_private;

-- --------------------------------------------------------------------------
-- TERMOS DE USO VERSIONADOS E EVIDÊNCIA DE ACEITE
-- --------------------------------------------------------------------------

create table if not exists public.system_legal_terms (
  id uuid primary key default gen_random_uuid(),
  version text not null unique,
  title text not null,
  content text not null,
  content_hash text not null,
  effective_at timestamptz not null default now(),
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  check (length(btrim(version)) > 0),
  check (length(btrim(title)) > 0),
  check (length(btrim(content)) > 0)
);

create unique index if not exists system_legal_terms_one_active_uidx
  on public.system_legal_terms (is_active)
  where is_active = true;

create table if not exists public.legal_term_acceptances (
  id uuid primary key default gen_random_uuid(),
  terms_id uuid not null references public.system_legal_terms(id) on delete restrict,
  terms_version text not null,
  terms_title text not null,
  terms_snapshot text not null,
  terms_hash text not null,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  accepting_user_id uuid references public.app_users(id) on delete set null,
  account_role public.app_user_role not null,
  account_name_snapshot text not null,
  agency_name_snapshot text,
  store_name_snapshot text,
  signer_name text not null,
  signer_role text not null,
  signer_cpf_hash text not null,
  signer_cpf_last4 text not null,
  signature_data_url text not null,
  signature_hash text not null,
  confirmations jsonb not null default '[]'::jsonb,
  ip_address text,
  user_agent text,
  client_timezone text,
  client_timestamp timestamptz,
  accepted_at timestamptz not null default now(),
  evidence_hash text not null,
  unique (terms_id, accepting_user_id),
  check (length(btrim(signer_name)) >= 3),
  check (length(btrim(signer_role)) >= 2),
  check (signer_cpf_last4 ~ '^[0-9]{4}$'),
  check (signature_data_url like 'data:image/png;base64,%')
);

create index if not exists legal_term_acceptances_admin_date_idx
  on public.legal_term_acceptances (admin_user_id, accepted_at desc);
create index if not exists legal_term_acceptances_user_date_idx
  on public.legal_term_acceptances (accepting_user_id, accepted_at desc);

alter table public.system_legal_terms enable row level security;
alter table public.legal_term_acceptances enable row level security;

update public.system_legal_terms
set is_active = false
where is_active = true
  and version <> '2026.08.05-4';

insert into public.system_legal_terms (
  version,
  title,
  content,
  content_hash,
  effective_at,
  is_active
)
values (
  '2026.08.05-4',
  'Termos de Uso, Privacidade e Licença da Plataforma',
  $terms$
## 1. Partes, finalidade e aceite
Estes Termos regulam o acesso à plataforma de Controle de Leads e Prospecções (“Plataforma”) pelo usuário, pela empresa cliente e, quando aplicável, pela agência responsável. O fornecedor e licenciante da Plataforma é JOAO MARCOS DIAS PAINA JUNIOR, pessoa física inscrita no CPF sob o nº 532.222.238-31, telefone (19) 99637-0701 e e-mail muitofacil18@gmail.com (“Fornecedor”). Ao assinar eletronicamente, o usuário confirma que leu, compreendeu e aceita integralmente estes Termos e que possui capacidade e poderes para vincular a conta e a organização que representa.

## 2. Objeto e licença limitada
A Plataforma disponibiliza recursos de cadastro, organização, análise, acompanhamento e exportação de leads e prospecções. É concedida licença temporária, revogável, não exclusiva, intransferível e limitada ao uso interno da organização autorizada, durante a vigência do plano contratado. Nenhum direito sobre código-fonte, arquitetura, identidade visual, fluxos, métodos, modelos de dados, documentação, lógica de negócio ou tecnologia é transferido ao usuário.

## 3. Contas, credenciais e usuários autorizados
Cada acesso é pessoal e deve ser utilizado exclusivamente pela pessoa ou equipe expressamente autorizada. É proibido vender, ceder, sublicenciar, emprestar, compartilhar credenciais ou permitir acesso a terceiros sem autorização formal. O titular da conta responde por manter senha e dispositivos seguros, encerrar sessões em equipamentos compartilhados e informar imediatamente qualquer suspeita de uso indevido.

## 4. Hierarquia de acesso e confidencialidade
Os dados de cada cliente permanecem segregados por conta. Podem acessá-los: o próprio cliente autorizado; a agência vinculada àquele cliente, para execução dos serviços contratados; e o Admin, para administração, suporte, segurança, auditoria e operação da Plataforma. Usuários não podem acessar contas fora de seu escopo. Todos os envolvidos devem preservar confidencialidade e utilizar os dados apenas para as finalidades profissionais autorizadas.

## 5. Proteção de dados pessoais e LGPD
As partes comprometem-se a observar a Lei nº 13.709/2018 (LGPD), incluindo finalidade, adequação, necessidade, transparência, segurança, prevenção e prestação de contas. Em regra, o cliente e/ou a agência que decide quais dados inserir e para quais finalidades atua como controlador; o fornecedor da Plataforma atua como operador nos limites das instruções e da prestação tecnológica, sem prejuízo das responsabilidades específicas que a lei atribuir a cada parte.

- O usuário deve possuir base legal válida para cadastrar e tratar dados de leads, clientes, funcionários e demais titulares.
- Devem ser inseridos apenas dados necessários à finalidade comercial legítima e informada.
- Solicitações de titulares devem ser encaminhadas imediatamente ao responsável pela conta e tratadas conforme a LGPD.
- É proibido inserir dados obtidos de forma ilícita, discriminatória, enganosa ou incompatível com a finalidade declarada.
- A assinatura desenhada, o identificador da conta e as evidências do aceite são tratados para autenticação, execução contratual, prevenção a fraude e exercício regular de direitos.

## 6. Compartilhamento e infraestrutura Supabase
Os dados não são vendidos, alugados nem compartilhados para publicidade de terceiros. O acesso funcional fica restrito ao usuário autorizado, ao Admin e à agência vinculada, conforme a hierarquia da conta. Poderá ocorrer tratamento técnico por fornecedores essenciais de infraestrutura, especialmente o Supabase, utilizado para banco de dados, autenticação, disponibilidade e recursos de segurança, além de divulgação quando exigida por lei, ordem judicial ou autoridade competente.

A segurança opera em modelo de responsabilidade compartilhada. A Plataforma depende da disponibilidade e da arquitetura de segurança do Supabase, do qual o fornecedor é cliente, e também das configurações, controles de acesso e código mantidos pelo fornecedor da Plataforma. Essa dependência não elimina obrigações legais inderrogáveis, mas eventos exclusivamente causados pela infraestrutura de terceiros serão apurados conforme a participação e a responsabilidade de cada agente.

## 7. Segurança e incidentes
São adotadas medidas técnicas e administrativas compatíveis com a natureza do serviço, incluindo segregação lógica, autenticação, restrição de acesso e trilha de evidências. Nenhum sistema é absolutamente imune a falhas. O usuário deve colaborar com investigações, preservar evidências e comunicar incidentes. Incidentes com risco ou dano relevante serão tratados e comunicados nos termos aplicáveis da LGPD.

## 8. Retenção, exportação e exclusão
Os registros operacionais de Prospecções são mantidos por uma janela móvel máxima de 2 (dois) anos contada da criação de cada registro. Dados mais antigos são eliminados automaticamente para dar lugar aos registros novos, salvo obrigação legal, ordem de preservação ou necessidade legítima de exercício de direitos. O cliente deve realizar exportações periódicas quando precisar manter histórico próprio por prazo superior.

Se o acesso ao módulo Prospecções for desativado, a operação e a visualização analítica ficam bloqueadas, mas a conta poderá exportar os registros ainda existentes durante a janela de retenção. A reativação não recupera dados que já tenham sido eliminados pela política de dois anos. Evidências de aceite, auditoria, segurança e documentos contratuais podem ser conservados por prazo distinto quando necessários ao cumprimento de obrigação legal ou ao exercício regular de direitos.

## 9. Propriedade intelectual e uso restrito
Todos os direitos sobre a Plataforma, incluindo software, interfaces, design, fluxos, automações, lógica de registro, organização, facilitação de uso, relatórios, documentação, marcas, segredos de negócio e melhorias pertencem ao fornecedor ou a seus licenciantes. O usuário não poderá copiar, reproduzir, adaptar, traduzir, desmontar, descompilar, realizar engenharia reversa, extrair código, contornar controles, criar obra derivada ou explorar elemento substancial da Plataforma, salvo autorização escrita ou hipótese legal que não possa ser afastada contratualmente.

## 10. Não concorrência por uso indevido e não aproveitamento parasitário
Durante o acesso e por 24 (vinte e quatro) meses após seu término, o usuário e a organização que representa não poderão usar informações confidenciais, acesso privilegiado, fluxos internos, lógica, documentação ou conhecimento não público obtido na Plataforma para desenvolver, financiar, encomendar, comercializar ou auxiliar cópia ou solução substancialmente concorrente destinada ao mesmo público-alvo. Esta restrição não impede atividade profissional lícita, desenvolvimento comprovadamente independente, uso de conhecimento geral ou concorrência baseada em recursos públicos e próprios.

## 11. Proibição de repasse e aliciamento técnico
É proibido repassar o acesso ou demonstrar áreas restritas a desenvolvedores, concorrentes ou terceiros com objetivo de reprodução, benchmarking não autorizado ou apropriação de tecnologia. Também é proibido induzir colaboradores ou fornecedores a revelar código, arquitetura, credenciais, documentação ou segredos da Plataforma.

## 12. Multa, perdas e danos
A violação comprovada das obrigações de confidencialidade, não compartilhamento, propriedade intelectual, engenharia reversa, cópia, concorrência por uso indevido ou acesso não autorizado sujeitará o infrator à multa contratual de R$ 150.000,00 (cento e cinquenta mil reais) por evento grave, sem prejuízo da cessação imediata da conduta, tutela de urgência e indenização por perdas e danos comprovadamente excedentes, quando cabível e na medida permitida pela legislação. A aplicação observará a natureza da obrigação, a extensão do dano e os limites legais aplicáveis à cláusula penal.

## 13. Uso aceitável
É proibido utilizar a Plataforma para fraude, spam ilícito, discriminação, assédio, violação de direitos, tratamento ilegal de dados, invasão, testes de vulnerabilidade sem autorização, sobrecarga deliberada, malware ou qualquer atividade ilícita. O usuário responde pelo conteúdo inserido e pelas comunicações realizadas a partir dos dados cadastrados.

## 14. Natureza B2B, planos, cancelamentos e suspensão
A Plataforma é disponibilizada como serviço B2B, destinado ao uso profissional por agências, empresas e clientes empresariais, integrado às respectivas atividades econômicas e não direcionado a uso pessoal, familiar ou doméstico. Recursos podem depender de plano e quantidade de licenças definidos pelo Admin. A Agência escolhe quais clientes utilizarão as licenças disponíveis, sem ultrapassar a cota. Redução de plano pode bloquear novas ativações e exigir desativação de acessos excedentes.

Na relação comercial entre a Agência e os clientes que ela cadastra, contrata ou mantém, a Agência atua de forma independente e é responsável pelas próprias ofertas, preços, cobranças, recebimentos, suporte comercial, cancelamentos e devoluções ou reembolsos decorrentes de desistência ou encerramento. O Fornecedor não responde pela devolução de quantias que não tenha recebido. Valores cobrados e recebidos diretamente pelo Fornecedor serão tratados pelo próprio Fornecedor conforme a contratação e a legislação aplicável.

A caracterização contratual como B2B e a distribuição de responsabilidades não afastam direitos ou deveres legais obrigatórios que venham a ser reconhecidos no caso concreto. O acesso poderá ser suspenso por inadimplência, risco de segurança, violação destes Termos, ordem legal ou uso que prejudique terceiros ou a Plataforma.

## 15. Disponibilidade, resultados e limitações
A Plataforma é ferramenta de apoio e não garante vendas, faturamento, retorno de campanhas ou resultado comercial específico. Métricas dependem da qualidade e atualização dos dados inseridos. Manutenções, falhas de internet e indisponibilidades de infraestrutura podem ocorrer. Nenhuma cláusula exclui responsabilidade que não possa ser afastada por lei.

## 16. Assinatura eletrônica e evidências
As partes reconhecem como válida a assinatura eletrônica realizada na Plataforma por desenho com mouse, dedo ou caneta, vinculada à sessão autenticada, versão do documento, data e hora do servidor, identificador da conta, hashes de integridade e evidências técnicas disponíveis. O usuário concorda com o armazenamento dessas evidências e reconhece que elas poderão ser apresentadas para comprovar autoria, integridade, aceite e exercício regular de direitos.

## 17. Alterações e novo aceite
Os Termos podem ser atualizados para refletir mudanças legais, técnicas ou comerciais. Alterações materiais gerarão nova versão e poderão exigir novo aceite antes da continuidade do uso. A versão aceita permanece vinculada à respectiva evidência.

## 18. Rescisão e sobrevivência
O usuário pode deixar de utilizar a Plataforma, observadas obrigações contratuais e financeiras existentes. Permanecem após o término as cláusulas de confidencialidade, propriedade intelectual, restrições contra cópia e uso indevido, proteção de dados, retenção de evidências, responsabilidade e solução de controvérsias.

## 19. Legislação e solução de controvérsias
Aplicam-se as leis da República Federativa do Brasil. As partes buscarão solução de boa-fé antes de medida judicial. Fica eleito o foro do domicílio do Fornecedor acima identificado, salvo competência legal obrigatória, especialmente em relações de consumo.

## 20. Feedback, sugestões e melhorias
Ao enviar voluntariamente sugestão, ideia, correção, melhoria, feedback ou proposta relacionada à Plataforma, o usuário autoriza o Fornecedor, na máxima extensão permitida pela lei, a usar, avaliar, adaptar, desenvolver, incorporar, reproduzir, licenciar e explorar esse conteúdo livremente, sem obrigação de remuneração, reconhecimento, licença adicional ou atribuição ao usuário. Essa autorização é gratuita, mundial, por prazo indeterminado, não exclusiva, transferível e sublicenciável, e não alcança dados pessoais, informações confidenciais do usuário nem materiais preexistentes de terceiros além do necessário à finalidade autorizada.

## 21. Inteligência artificial, banco de dados, UX/UI e terceiros
Integram a propriedade intelectual e os ativos tecnológicos da Plataforma, conforme sua natureza e titularidade, os modelos e recursos de inteligência artificial, prompts, instruções de sistema, configurações, embeddings, agentes, fluxos de decisão, parâmetros, avaliações, automações, métricas e demais tecnologias utilizadas ou desenvolvidas, ainda que operem com serviços de terceiros.

Também são protegidos a estrutura, modelagem, organização, relacionamentos, índices, arquitetura, consultas e demais elementos técnicos do banco de dados, bem como a experiência do usuário (UX), identidade visual, interface (UI), navegação, disposição funcional, hierarquia de informações, fluxos operacionais e elementos de interação da Plataforma.

A Plataforma poderá utilizar bibliotecas, componentes, APIs, modelos, serviços e softwares licenciados por terceiros. Os respectivos direitos permanecem com seus titulares, e estes Termos não concedem ao usuário direitos além daqueles necessários ao uso regular da Plataforma.

## 22. APIs, automações, benchmarking e captura de interface
Sem autorização expressa do Fornecedor, é proibido utilizar APIs, integrações, automações, robôs, scripts, crawlers, técnicas de scraping ou outros mecanismos destinados à coleta massiva de informações, reprodução, extração, contorno de controles, engenharia reversa ou replicação total ou parcial da Plataforma, ressalvadas hipóteses legais que não possam ser afastadas.

O usuário não poderá utilizar o acesso para realizar testes comparativos, benchmarking técnico ou comercial, medição sistemática ou análise destinada ao desenvolvimento, treinamento, validação ou promoção de produto concorrente com base em elementos não públicos da Plataforma.

É vedada a gravação ou captura sistemática de telas, documentação técnica, mapeamento de fluxos ou reprodução da interface quando destinada à engenharia reversa, cópia ou desenvolvimento de solução concorrente. Permanecem permitidas capturas pontuais necessárias ao uso interno autorizado, suporte, treinamento da própria equipe ou exercício regular de direitos.

## 23. Segredos comerciais, auditoria e preservação de evidências
Consideram-se Segredos Comerciais, entre outros elementos não públicos, algoritmos, código, arquitetura, fluxos internos, modelos de dados, documentação, integrações, automações, métricas, estratégias, métodos operacionais, processos de desenvolvimento, configurações técnicas, credenciais, mecanismos de segurança e demais informações confidenciais relacionadas à Plataforma.

Havendo necessidade de segurança, prevenção a fraude, suporte, auditoria, investigação de incidente ou apuração de possível violação destes Termos, o Fornecedor poderá registrar e preservar logs, eventos, identificadores, trilhas técnicas e evidências pertinentes, observando finalidade, necessidade, acesso restrito, prazos aplicáveis e a legislação de proteção de dados.

## 24. Força maior e evolução da Plataforma
Na medida permitida pela lei, o Fornecedor não responderá por atraso ou indisponibilidade comprovadamente decorrente de caso fortuito ou força maior, falhas externas de energia, telecomunicações ou internet, indisponibilidade de provedores e serviços em nuvem, ataques generalizados, eventos naturais, conflitos, greves, atos de autoridade ou outros eventos inevitáveis fora de seu controle razoável. Essa previsão não exclui deveres legais obrigatórios nem a adoção de medidas razoáveis para reduzir impactos e restabelecer o serviço.

O Fornecedor poderá alterar, adicionar, remover, reorganizar ou substituir funcionalidades para evolução técnica, segurança, desempenho, conformidade legal ou melhoria da Plataforma, preservados os direitos dos usuários, a boa-fé e as obrigações legais e contratuais aplicáveis. Mudanças materiais poderão ser comunicadas e exigir novo aceite.

## 25. Interpretação restrita da não concorrência
A cláusula 10 não estabelece exclusividade, reserva de mercado ou proibição geral de trabalhar, empreender, prestar serviços ou desenvolver produto concorrente. Sua finalidade exclusiva é impedir o aproveitamento comprovado de Segredos Comerciais, acesso privilegiado, material confidencial e conhecimento não público obtido por meio da Plataforma para copiar ou reproduzir elemento substancial protegido.

O prazo de 24 (vinte e quatro) meses aplica-se somente a essa obrigação específica de não utilização indevida, sem limitar obrigações de confidencialidade, propriedade intelectual e proteção de segredos que, por sua natureza ou por lei, devam subsistir por período distinto. Permanecem permitidos desenvolvimento comprovadamente independente, conhecimento geral, informações públicas, experiência profissional legítima e concorrência baseada em recursos próprios e lícitos.

## 26. Declarações finais
Ao marcar as confirmações e assinar, o usuário declara que: leu integralmente estes Termos; recebeu oportunidade de esclarecer dúvidas; possui autorização para representar a organização; fornecerá dados verdadeiros; manterá credenciais seguras; respeitará a LGPD e os direitos dos titulares; não compartilhará o acesso; não copiará nem auxiliará cópia da Plataforma; e aceita a política de retenção e exportação descrita acima.
  $terms$,
  encode(digest(convert_to($terms$
## 1. Partes, finalidade e aceite
Estes Termos regulam o acesso à plataforma de Controle de Leads e Prospecções (“Plataforma”) pelo usuário, pela empresa cliente e, quando aplicável, pela agência responsável. O fornecedor e licenciante da Plataforma é JOAO MARCOS DIAS PAINA JUNIOR, pessoa física inscrita no CPF sob o nº 532.222.238-31, telefone (19) 99637-0701 e e-mail muitofacil18@gmail.com (“Fornecedor”). Ao assinar eletronicamente, o usuário confirma que leu, compreendeu e aceita integralmente estes Termos e que possui capacidade e poderes para vincular a conta e a organização que representa.

## 2. Objeto e licença limitada
A Plataforma disponibiliza recursos de cadastro, organização, análise, acompanhamento e exportação de leads e prospecções. É concedida licença temporária, revogável, não exclusiva, intransferível e limitada ao uso interno da organização autorizada, durante a vigência do plano contratado. Nenhum direito sobre código-fonte, arquitetura, identidade visual, fluxos, métodos, modelos de dados, documentação, lógica de negócio ou tecnologia é transferido ao usuário.

## 3. Contas, credenciais e usuários autorizados
Cada acesso é pessoal e deve ser utilizado exclusivamente pela pessoa ou equipe expressamente autorizada. É proibido vender, ceder, sublicenciar, emprestar, compartilhar credenciais ou permitir acesso a terceiros sem autorização formal. O titular da conta responde por manter senha e dispositivos seguros, encerrar sessões em equipamentos compartilhados e informar imediatamente qualquer suspeita de uso indevido.

## 4. Hierarquia de acesso e confidencialidade
Os dados de cada cliente permanecem segregados por conta. Podem acessá-los: o próprio cliente autorizado; a agência vinculada àquele cliente, para execução dos serviços contratados; e o Admin, para administração, suporte, segurança, auditoria e operação da Plataforma. Usuários não podem acessar contas fora de seu escopo. Todos os envolvidos devem preservar confidencialidade e utilizar os dados apenas para as finalidades profissionais autorizadas.

## 5. Proteção de dados pessoais e LGPD
As partes comprometem-se a observar a Lei nº 13.709/2018 (LGPD), incluindo finalidade, adequação, necessidade, transparência, segurança, prevenção e prestação de contas. Em regra, o cliente e/ou a agência que decide quais dados inserir e para quais finalidades atua como controlador; o fornecedor da Plataforma atua como operador nos limites das instruções e da prestação tecnológica, sem prejuízo das responsabilidades específicas que a lei atribuir a cada parte.

- O usuário deve possuir base legal válida para cadastrar e tratar dados de leads, clientes, funcionários e demais titulares.
- Devem ser inseridos apenas dados necessários à finalidade comercial legítima e informada.
- Solicitações de titulares devem ser encaminhadas imediatamente ao responsável pela conta e tratadas conforme a LGPD.
- É proibido inserir dados obtidos de forma ilícita, discriminatória, enganosa ou incompatível com a finalidade declarada.
- A assinatura desenhada, o identificador da conta e as evidências do aceite são tratados para autenticação, execução contratual, prevenção a fraude e exercício regular de direitos.

## 6. Compartilhamento e infraestrutura Supabase
Os dados não são vendidos, alugados nem compartilhados para publicidade de terceiros. O acesso funcional fica restrito ao usuário autorizado, ao Admin e à agência vinculada, conforme a hierarquia da conta. Poderá ocorrer tratamento técnico por fornecedores essenciais de infraestrutura, especialmente o Supabase, utilizado para banco de dados, autenticação, disponibilidade e recursos de segurança, além de divulgação quando exigida por lei, ordem judicial ou autoridade competente.

A segurança opera em modelo de responsabilidade compartilhada. A Plataforma depende da disponibilidade e da arquitetura de segurança do Supabase, do qual o fornecedor é cliente, e também das configurações, controles de acesso e código mantidos pelo fornecedor da Plataforma. Essa dependência não elimina obrigações legais inderrogáveis, mas eventos exclusivamente causados pela infraestrutura de terceiros serão apurados conforme a participação e a responsabilidade de cada agente.

## 7. Segurança e incidentes
São adotadas medidas técnicas e administrativas compatíveis com a natureza do serviço, incluindo segregação lógica, autenticação, restrição de acesso e trilha de evidências. Nenhum sistema é absolutamente imune a falhas. O usuário deve colaborar com investigações, preservar evidências e comunicar incidentes. Incidentes com risco ou dano relevante serão tratados e comunicados nos termos aplicáveis da LGPD.

## 8. Retenção, exportação e exclusão
Os registros operacionais de Prospecções são mantidos por uma janela móvel máxima de 2 (dois) anos contada da criação de cada registro. Dados mais antigos são eliminados automaticamente para dar lugar aos registros novos, salvo obrigação legal, ordem de preservação ou necessidade legítima de exercício de direitos. O cliente deve realizar exportações periódicas quando precisar manter histórico próprio por prazo superior.

Se o acesso ao módulo Prospecções for desativado, a operação e a visualização analítica ficam bloqueadas, mas a conta poderá exportar os registros ainda existentes durante a janela de retenção. A reativação não recupera dados que já tenham sido eliminados pela política de dois anos. Evidências de aceite, auditoria, segurança e documentos contratuais podem ser conservados por prazo distinto quando necessários ao cumprimento de obrigação legal ou ao exercício regular de direitos.

## 9. Propriedade intelectual e uso restrito
Todos os direitos sobre a Plataforma, incluindo software, interfaces, design, fluxos, automações, lógica de registro, organização, facilitação de uso, relatórios, documentação, marcas, segredos de negócio e melhorias pertencem ao fornecedor ou a seus licenciantes. O usuário não poderá copiar, reproduzir, adaptar, traduzir, desmontar, descompilar, realizar engenharia reversa, extrair código, contornar controles, criar obra derivada ou explorar elemento substancial da Plataforma, salvo autorização escrita ou hipótese legal que não possa ser afastada contratualmente.

## 10. Não concorrência por uso indevido e não aproveitamento parasitário
Durante o acesso e por 24 (vinte e quatro) meses após seu término, o usuário e a organização que representa não poderão usar informações confidenciais, acesso privilegiado, fluxos internos, lógica, documentação ou conhecimento não público obtido na Plataforma para desenvolver, financiar, encomendar, comercializar ou auxiliar cópia ou solução substancialmente concorrente destinada ao mesmo público-alvo. Esta restrição não impede atividade profissional lícita, desenvolvimento comprovadamente independente, uso de conhecimento geral ou concorrência baseada em recursos públicos e próprios.

## 11. Proibição de repasse e aliciamento técnico
É proibido repassar o acesso ou demonstrar áreas restritas a desenvolvedores, concorrentes ou terceiros com objetivo de reprodução, benchmarking não autorizado ou apropriação de tecnologia. Também é proibido induzir colaboradores ou fornecedores a revelar código, arquitetura, credenciais, documentação ou segredos da Plataforma.

## 12. Multa, perdas e danos
A violação comprovada das obrigações de confidencialidade, não compartilhamento, propriedade intelectual, engenharia reversa, cópia, concorrência por uso indevido ou acesso não autorizado sujeitará o infrator à multa contratual de R$ 150.000,00 (cento e cinquenta mil reais) por evento grave, sem prejuízo da cessação imediata da conduta, tutela de urgência e indenização por perdas e danos comprovadamente excedentes, quando cabível e na medida permitida pela legislação. A aplicação observará a natureza da obrigação, a extensão do dano e os limites legais aplicáveis à cláusula penal.

## 13. Uso aceitável
É proibido utilizar a Plataforma para fraude, spam ilícito, discriminação, assédio, violação de direitos, tratamento ilegal de dados, invasão, testes de vulnerabilidade sem autorização, sobrecarga deliberada, malware ou qualquer atividade ilícita. O usuário responde pelo conteúdo inserido e pelas comunicações realizadas a partir dos dados cadastrados.

## 14. Natureza B2B, planos, cancelamentos e suspensão
A Plataforma é disponibilizada como serviço B2B, destinado ao uso profissional por agências, empresas e clientes empresariais, integrado às respectivas atividades econômicas e não direcionado a uso pessoal, familiar ou doméstico. Recursos podem depender de plano e quantidade de licenças definidos pelo Admin. A Agência escolhe quais clientes utilizarão as licenças disponíveis, sem ultrapassar a cota. Redução de plano pode bloquear novas ativações e exigir desativação de acessos excedentes.

Na relação comercial entre a Agência e os clientes que ela cadastra, contrata ou mantém, a Agência atua de forma independente e é responsável pelas próprias ofertas, preços, cobranças, recebimentos, suporte comercial, cancelamentos e devoluções ou reembolsos decorrentes de desistência ou encerramento. O Fornecedor não responde pela devolução de quantias que não tenha recebido. Valores cobrados e recebidos diretamente pelo Fornecedor serão tratados pelo próprio Fornecedor conforme a contratação e a legislação aplicável.

A caracterização contratual como B2B e a distribuição de responsabilidades não afastam direitos ou deveres legais obrigatórios que venham a ser reconhecidos no caso concreto. O acesso poderá ser suspenso por inadimplência, risco de segurança, violação destes Termos, ordem legal ou uso que prejudique terceiros ou a Plataforma.

## 15. Disponibilidade, resultados e limitações
A Plataforma é ferramenta de apoio e não garante vendas, faturamento, retorno de campanhas ou resultado comercial específico. Métricas dependem da qualidade e atualização dos dados inseridos. Manutenções, falhas de internet e indisponibilidades de infraestrutura podem ocorrer. Nenhuma cláusula exclui responsabilidade que não possa ser afastada por lei.

## 16. Assinatura eletrônica e evidências
As partes reconhecem como válida a assinatura eletrônica realizada na Plataforma por desenho com mouse, dedo ou caneta, vinculada à sessão autenticada, versão do documento, data e hora do servidor, identificador da conta, hashes de integridade e evidências técnicas disponíveis. O usuário concorda com o armazenamento dessas evidências e reconhece que elas poderão ser apresentadas para comprovar autoria, integridade, aceite e exercício regular de direitos.

## 17. Alterações e novo aceite
Os Termos podem ser atualizados para refletir mudanças legais, técnicas ou comerciais. Alterações materiais gerarão nova versão e poderão exigir novo aceite antes da continuidade do uso. A versão aceita permanece vinculada à respectiva evidência.

## 18. Rescisão e sobrevivência
O usuário pode deixar de utilizar a Plataforma, observadas obrigações contratuais e financeiras existentes. Permanecem após o término as cláusulas de confidencialidade, propriedade intelectual, restrições contra cópia e uso indevido, proteção de dados, retenção de evidências, responsabilidade e solução de controvérsias.

## 19. Legislação e solução de controvérsias
Aplicam-se as leis da República Federativa do Brasil. As partes buscarão solução de boa-fé antes de medida judicial. Fica eleito o foro do domicílio do Fornecedor acima identificado, salvo competência legal obrigatória, especialmente em relações de consumo.

## 20. Feedback, sugestões e melhorias
Ao enviar voluntariamente sugestão, ideia, correção, melhoria, feedback ou proposta relacionada à Plataforma, o usuário autoriza o Fornecedor, na máxima extensão permitida pela lei, a usar, avaliar, adaptar, desenvolver, incorporar, reproduzir, licenciar e explorar esse conteúdo livremente, sem obrigação de remuneração, reconhecimento, licença adicional ou atribuição ao usuário. Essa autorização é gratuita, mundial, por prazo indeterminado, não exclusiva, transferível e sublicenciável, e não alcança dados pessoais, informações confidenciais do usuário nem materiais preexistentes de terceiros além do necessário à finalidade autorizada.

## 21. Inteligência artificial, banco de dados, UX/UI e terceiros
Integram a propriedade intelectual e os ativos tecnológicos da Plataforma, conforme sua natureza e titularidade, os modelos e recursos de inteligência artificial, prompts, instruções de sistema, configurações, embeddings, agentes, fluxos de decisão, parâmetros, avaliações, automações, métricas e demais tecnologias utilizadas ou desenvolvidas, ainda que operem com serviços de terceiros.

Também são protegidos a estrutura, modelagem, organização, relacionamentos, índices, arquitetura, consultas e demais elementos técnicos do banco de dados, bem como a experiência do usuário (UX), identidade visual, interface (UI), navegação, disposição funcional, hierarquia de informações, fluxos operacionais e elementos de interação da Plataforma.

A Plataforma poderá utilizar bibliotecas, componentes, APIs, modelos, serviços e softwares licenciados por terceiros. Os respectivos direitos permanecem com seus titulares, e estes Termos não concedem ao usuário direitos além daqueles necessários ao uso regular da Plataforma.

## 22. APIs, automações, benchmarking e captura de interface
Sem autorização expressa do Fornecedor, é proibido utilizar APIs, integrações, automações, robôs, scripts, crawlers, técnicas de scraping ou outros mecanismos destinados à coleta massiva de informações, reprodução, extração, contorno de controles, engenharia reversa ou replicação total ou parcial da Plataforma, ressalvadas hipóteses legais que não possam ser afastadas.

O usuário não poderá utilizar o acesso para realizar testes comparativos, benchmarking técnico ou comercial, medição sistemática ou análise destinada ao desenvolvimento, treinamento, validação ou promoção de produto concorrente com base em elementos não públicos da Plataforma.

É vedada a gravação ou captura sistemática de telas, documentação técnica, mapeamento de fluxos ou reprodução da interface quando destinada à engenharia reversa, cópia ou desenvolvimento de solução concorrente. Permanecem permitidas capturas pontuais necessárias ao uso interno autorizado, suporte, treinamento da própria equipe ou exercício regular de direitos.

## 23. Segredos comerciais, auditoria e preservação de evidências
Consideram-se Segredos Comerciais, entre outros elementos não públicos, algoritmos, código, arquitetura, fluxos internos, modelos de dados, documentação, integrações, automações, métricas, estratégias, métodos operacionais, processos de desenvolvimento, configurações técnicas, credenciais, mecanismos de segurança e demais informações confidenciais relacionadas à Plataforma.

Havendo necessidade de segurança, prevenção a fraude, suporte, auditoria, investigação de incidente ou apuração de possível violação destes Termos, o Fornecedor poderá registrar e preservar logs, eventos, identificadores, trilhas técnicas e evidências pertinentes, observando finalidade, necessidade, acesso restrito, prazos aplicáveis e a legislação de proteção de dados.

## 24. Força maior e evolução da Plataforma
Na medida permitida pela lei, o Fornecedor não responderá por atraso ou indisponibilidade comprovadamente decorrente de caso fortuito ou força maior, falhas externas de energia, telecomunicações ou internet, indisponibilidade de provedores e serviços em nuvem, ataques generalizados, eventos naturais, conflitos, greves, atos de autoridade ou outros eventos inevitáveis fora de seu controle razoável. Essa previsão não exclui deveres legais obrigatórios nem a adoção de medidas razoáveis para reduzir impactos e restabelecer o serviço.

O Fornecedor poderá alterar, adicionar, remover, reorganizar ou substituir funcionalidades para evolução técnica, segurança, desempenho, conformidade legal ou melhoria da Plataforma, preservados os direitos dos usuários, a boa-fé e as obrigações legais e contratuais aplicáveis. Mudanças materiais poderão ser comunicadas e exigir novo aceite.

## 25. Interpretação restrita da não concorrência
A cláusula 10 não estabelece exclusividade, reserva de mercado ou proibição geral de trabalhar, empreender, prestar serviços ou desenvolver produto concorrente. Sua finalidade exclusiva é impedir o aproveitamento comprovado de Segredos Comerciais, acesso privilegiado, material confidencial e conhecimento não público obtido por meio da Plataforma para copiar ou reproduzir elemento substancial protegido.

O prazo de 24 (vinte e quatro) meses aplica-se somente a essa obrigação específica de não utilização indevida, sem limitar obrigações de confidencialidade, propriedade intelectual e proteção de segredos que, por sua natureza ou por lei, devam subsistir por período distinto. Permanecem permitidos desenvolvimento comprovadamente independente, conhecimento geral, informações públicas, experiência profissional legítima e concorrência baseada em recursos próprios e lícitos.

## 26. Declarações finais
Ao marcar as confirmações e assinar, o usuário declara que: leu integralmente estes Termos; recebeu oportunidade de esclarecer dúvidas; possui autorização para representar a organização; fornecerá dados verdadeiros; manterá credenciais seguras; respeitará a LGPD e os direitos dos titulares; não compartilhará o acesso; não copiará nem auxiliará cópia da Plataforma; e aceita a política de retenção e exportação descrita acima.
  $terms$, 'UTF8'), 'sha256'), 'hex'),
  now(),
  true
)
on conflict (version) do update set
  title = excluded.title,
  content = excluded.content,
  content_hash = excluded.content_hash,
  effective_at = excluded.effective_at,
  is_active = true;

create or replace function app_private.session_user_unchecked(p_session_token text)
returns table (
  user_id uuid,
  admin_user_id uuid,
  user_role public.app_user_role,
  user_store_id uuid
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_token_hash text;
begin
  if coalesce(p_session_token, '') = '' then
    raise exception 'Sessao obrigatoria.' using errcode = '28000';
  end if;

  v_token_hash := encode(digest(p_session_token, 'sha256'), 'hex');

  return query
  select u.id, coalesce(u.admin_user_id, u.id), u.role, u.store_id
  from public.app_sessions s
  join public.app_users u on u.id = s.user_id
  left join public.stores st on st.id = u.store_id
  where s.token_hash = v_token_hash
    and s.revoked_at is null
    and s.expires_at > now()
    and u.is_active = true
    and (u.role in ('admin', 'technician') or (st.id is not null and st.is_active = true))
  limit 1;

  if not found then
    raise exception 'Sessao invalida ou expirada.' using errcode = '28000';
  end if;

  update public.app_sessions set last_seen_at = now() where token_hash = v_token_hash;
end;
$$;

create or replace function app_private.legal_terms_satisfied(p_user_id uuid, p_user_role public.app_user_role)
returns boolean
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  select exists (
    select 1
    from public.legal_term_acceptances a
    join public.system_legal_terms t on t.id = a.terms_id and t.is_active = true
    where a.accepting_user_id = p_user_id
  );
$$;

create or replace function app_private.is_valid_cpf(p_cpf text)
returns boolean
language plpgsql
immutable
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_cpf text := regexp_replace(coalesce(p_cpf, ''), '[^0-9]', '', 'g');
  v_sum integer;
  v_digit integer;
  v_index integer;
begin
  if length(v_cpf) <> 11 or v_cpf ~ '^([0-9])\1{10}$' then
    return false;
  end if;

  v_sum := 0;
  for v_index in 1..9 loop
    v_sum := v_sum + substr(v_cpf, v_index, 1)::integer * (11 - v_index);
  end loop;
  v_digit := 11 - (v_sum % 11);
  if v_digit >= 10 then v_digit := 0; end if;
  if v_digit <> substr(v_cpf, 10, 1)::integer then return false; end if;

  v_sum := 0;
  for v_index in 1..10 loop
    v_sum := v_sum + substr(v_cpf, v_index, 1)::integer * (12 - v_index);
  end loop;
  v_digit := 11 - (v_sum % 11);
  if v_digit >= 10 then v_digit := 0; end if;
  return v_digit = substr(v_cpf, 11, 1)::integer;
end;
$$;

create or replace function app_private.session_user(p_session_token text)
returns table (
  user_id uuid,
  admin_user_id uuid,
  user_role public.app_user_role,
  user_store_id uuid
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user_unchecked(p_session_token);

  if coalesce(current_setting('app.legal_gate_bypass', true), '') <> 'on'
     and not app_private.legal_terms_satisfied(v_session.user_id, v_session.user_role) then
    raise exception 'TERMOS_DE_USO_PENDENTES: leia e assine a versao vigente para continuar.';
  end if;

  return query select
    v_session.user_id::uuid,
    v_session.admin_user_id::uuid,
    v_session.user_role::public.app_user_role,
    v_session.user_store_id::uuid;
end;
$$;

-- Permite reduzir a franquia mesmo quando existem mais acessos ativos que o
-- novo limite. Nessa situação, a agência continua podendo desativar qualquer
-- cliente, enquanto o trigger de cota impede somente novas ativações.
create or replace function app_private.rpc_set_technician_prospection_limit(
  p_session_token text,
  p_technician_id uuid,
  p_limit integer
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_limit integer;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode alterar o limite de Prospeccoes.';
  end if;
  if coalesce(p_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de Prospeccoes entre 0 e 9999.';
  end if;

  select u.store_limit into v_store_limit
  from public.app_users u
  where u.id = p_technician_id
    and u.admin_user_id = v_session.admin_user_id
    and u.role::text = 'technician'
    and u.is_active = true
  for update;

  if not found then raise exception 'Agencia nao encontrada.'; end if;
  if p_limit > v_store_limit then
    raise exception 'O limite de Prospeccoes nao pode superar o limite total de % clientes.', v_store_limit;
  end if;

  update public.app_users
  set prospection_store_limit = p_limit
  where id = p_technician_id;

  return true;
end;
$$;

-- O perfil precisa ser restaurado antes da abertura do modal obrigatório.
create or replace function app_private.profile_result(p_session_token text)
returns table (
  user_id uuid,
  admin_id uuid,
  nick text,
  full_name text,
  role public.app_user_role,
  store_id uuid,
  store_name text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  perform set_config('app.legal_gate_bypass', 'on', true);
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select u.id, v_session.admin_user_id, u.nick_key, u.full_name, u.role, u.store_id, st.name
  from public.app_users u
  left join public.stores st on st.id = u.store_id
  where u.id = v_session.user_id;
end;
$$;

create or replace function app_private.rpc_get_required_legal_terms(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_terms record;
  v_acceptance record;
begin
  select * into v_session from app_private.session_user_unchecked(p_session_token);
  select * into v_terms from public.system_legal_terms where is_active = true limit 1;

  if not found then
    raise exception 'TERMOS_DE_USO_INDISPONIVEIS: nenhum documento ativo foi configurado.';
  end if;

  select a.id, a.accepted_at, a.evidence_hash
  into v_acceptance
  from public.legal_term_acceptances a
  where a.terms_id = v_terms.id and a.accepting_user_id = v_session.user_id
  limit 1;

  return jsonb_build_object(
    'required', v_acceptance.id is null,
    'terms', jsonb_build_object(
      'id', v_terms.id,
      'version', v_terms.version,
      'title', v_terms.title,
      'content', v_terms.content,
      'content_hash', v_terms.content_hash,
      'effective_at', v_terms.effective_at
    ),
    'acceptance', case when v_acceptance.id is null then null else jsonb_build_object(
      'id', v_acceptance.id,
      'accepted_at', v_acceptance.accepted_at,
      'evidence_hash', v_acceptance.evidence_hash
    ) end
  );
end;
$$;

create or replace function app_private.rpc_accept_legal_terms(
  p_session_token text,
  p_signer_name text,
  p_signer_role text,
  p_signer_cpf text,
  p_signature_data_url text,
  p_user_agent text default null,
  p_client_timezone text default null,
  p_client_timestamp timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_terms record;
  v_user record;
  v_cpf text;
  v_cpf_hash text;
  v_signature_hash text;
  v_headers jsonb := '{}'::jsonb;
  v_ip text;
  v_user_agent text;
  v_accepted_at timestamptz := clock_timestamp();
  v_acceptance_id uuid;
begin
  select * into v_session from app_private.session_user_unchecked(p_session_token);

  select * into v_terms from public.system_legal_terms where is_active = true limit 1;
  if not found then raise exception 'Nenhum Termo de Uso ativo foi encontrado.'; end if;

  select a.id into v_acceptance_id
  from public.legal_term_acceptances a
  where a.terms_id = v_terms.id and a.accepting_user_id = v_session.user_id;
  if found then return v_acceptance_id; end if;

  if length(btrim(coalesce(p_signer_name, ''))) < 3 then raise exception 'Informe o nome completo do responsável.'; end if;
  if length(btrim(coalesce(p_signer_role, ''))) < 2 then raise exception 'Informe o cargo ou função do responsável.'; end if;

  v_cpf := regexp_replace(coalesce(p_signer_cpf, ''), '[^0-9]', '', 'g');
  if not app_private.is_valid_cpf(v_cpf) then raise exception 'Informe um CPF válido.'; end if;

  if coalesce(p_signature_data_url, '') not like 'data:image/png;base64,%'
     or length(p_signature_data_url) < 300
     or length(p_signature_data_url) > 600000 then
    raise exception 'Faça a assinatura no campo indicado.';
  end if;

  begin
    v_headers := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  exception when others then
    v_headers := '{}'::jsonb;
  end;

  v_ip := coalesce(
    nullif(v_headers->>'cf-connecting-ip', ''),
    nullif(split_part(coalesce(v_headers->>'x-forwarded-for', ''), ',', 1), ''),
    nullif(v_headers->>'x-real-ip', ''),
    'não disponível'
  );
  v_user_agent := left(coalesce(nullif(p_user_agent, ''), nullif(v_headers->>'user-agent', ''), 'não disponível'), 1000);
  v_cpf_hash := encode(digest(v_cpf, 'sha256'), 'hex');
  v_signature_hash := encode(digest(convert_to(p_signature_data_url, 'UTF8'), 'sha256'), 'hex');

  select
    u.full_name,
    u.nick_key,
    coalesce(st.name, u.full_name) as account_name,
    case when u.role::text = 'technician' then u.full_name else tech.full_name end as agency_name,
    st.name as store_name
  into v_user
  from public.app_users u
  left join public.stores st on st.id = u.store_id
  left join public.app_users tech on tech.id = st.technician_user_id
  where u.id = v_session.user_id;

  insert into public.legal_term_acceptances (
    terms_id, terms_version, terms_title, terms_snapshot, terms_hash,
    admin_user_id, accepting_user_id, account_role, account_name_snapshot,
    agency_name_snapshot, store_name_snapshot, signer_name, signer_role,
    signer_cpf_hash, signer_cpf_last4, signature_data_url, signature_hash,
    confirmations, ip_address, user_agent, client_timezone, client_timestamp,
    accepted_at, evidence_hash
  ) values (
    v_terms.id, v_terms.version, v_terms.title, v_terms.content, v_terms.content_hash,
    v_session.admin_user_id, v_session.user_id, v_session.user_role, v_user.account_name,
    v_user.agency_name, v_user.store_name, btrim(p_signer_name), btrim(p_signer_role),
    v_cpf_hash, right(v_cpf, 4), p_signature_data_url, v_signature_hash,
    jsonb_build_array(
      'Li e aceito integralmente os Termos de Uso e Privacidade.',
      'Declaro possuir autorização para representar esta conta e organização.',
      'Reconheço a assinatura eletrônica, a política de dados e a retenção de dois anos.'
    ),
    v_ip, v_user_agent, left(coalesce(p_client_timezone, ''), 120), p_client_timestamp,
    v_accepted_at,
    encode(digest(concat_ws('|', v_terms.content_hash, v_session.user_id::text, v_cpf_hash, v_signature_hash, v_ip, v_user_agent, v_accepted_at::text), 'sha256'), 'hex')
  ) returning id into v_acceptance_id;

  return v_acceptance_id;
end;
$$;

create or replace function app_private.rpc_list_legal_acceptances(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text <> 'admin' then raise exception 'Apenas o Admin pode consultar os termos assinados.'; end if;

  with active_terms as (
    select id, version from public.system_legal_terms where is_active = true limit 1
  ), account_rows as (
    select
      u.id as user_id,
      u.role::text as account_role,
      coalesce(st.name, u.full_name) as account_name,
      case when u.role::text = 'technician' then u.full_name when u.role::text = 'store' then tech.full_name else null end as agency_name,
      st.name as store_name,
      u.nick_key as login,
      u.created_at as account_created_at,
      la.id as acceptance_id,
      la.terms_id,
      la.terms_version,
      la.signer_name,
      la.signer_role,
      la.signer_cpf_last4,
      la.accepted_at,
      la.evidence_hash,
      (la.id is not null and la.terms_id = at.id) as accepted_current,
      (la.id is not null and la.terms_id <> at.id) as outdated
    from public.app_users u
    cross join active_terms at
    left join public.stores st on st.id = u.store_id
    left join public.app_users tech on tech.id = st.technician_user_id
    left join lateral (
      select a.* from public.legal_term_acceptances a
      where a.accepting_user_id = u.id
      order by a.accepted_at desc
      limit 1
    ) la on true
    where (u.id = v_session.admin_user_id or u.admin_user_id = v_session.admin_user_id)
      and u.role::text in ('admin', 'technician', 'store')
      and u.is_active = true
  )
  select jsonb_build_object(
    'active_version', coalesce((select version from active_terms), ''),
    'total', count(*),
    'accepted', count(*) filter (where accepted_current),
    'pending', count(*) filter (where not accepted_current),
    'accounts', coalesce(jsonb_agg(jsonb_build_object(
      'user_id', user_id,
      'account_role', account_role,
      'account_name', account_name,
      'agency_name', agency_name,
      'store_name', store_name,
      'login', login,
      'account_created_at', account_created_at,
      'acceptance_id', acceptance_id,
      'terms_version', terms_version,
      'signer_name', signer_name,
      'signer_role', signer_role,
      'signer_cpf_last4', signer_cpf_last4,
      'accepted_at', accepted_at,
      'evidence_hash', evidence_hash,
      'status', case when accepted_current then 'accepted' when outdated then 'outdated' else 'pending' end
    ) order by accepted_current, account_role, account_name), '[]'::jsonb)
  ) into v_result
  from account_rows;

  return coalesce(v_result, jsonb_build_object('active_version', '', 'total', 0, 'accepted', 0, 'pending', 0, 'accounts', '[]'::jsonb));
end;
$$;

create or replace function app_private.rpc_get_legal_acceptance_document(p_session_token text, p_acceptance_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text <> 'admin' then raise exception 'Apenas o Admin pode abrir este documento.'; end if;

  select jsonb_build_object(
    'id', a.id,
    'terms_version', a.terms_version,
    'terms_title', a.terms_title,
    'terms_snapshot', a.terms_snapshot,
    'terms_hash', a.terms_hash,
    'account_role', a.account_role,
    'account_name', a.account_name_snapshot,
    'agency_name', a.agency_name_snapshot,
    'store_name', a.store_name_snapshot,
    'signer_name', a.signer_name,
    'signer_role', a.signer_role,
    'signer_cpf_last4', a.signer_cpf_last4,
    'signature_data_url', a.signature_data_url,
    'signature_hash', a.signature_hash,
    'confirmations', a.confirmations,
    'ip_address', a.ip_address,
    'user_agent', a.user_agent,
    'client_timezone', a.client_timezone,
    'client_timestamp', a.client_timestamp,
    'accepted_at', a.accepted_at,
    'evidence_hash', a.evidence_hash
  ) into v_result
  from public.legal_term_acceptances a
  where a.id = p_acceptance_id and a.admin_user_id = v_session.admin_user_id;

  if v_result is null then raise exception 'Documento assinado não encontrado.'; end if;
  return v_result;
end;
$$;

create or replace function public.lc_get_required_legal_terms(p_session_token text)
returns jsonb language sql security invoker
as $$ select app_private.rpc_get_required_legal_terms(p_session_token); $$;

create or replace function public.lc_accept_legal_terms(
  p_session_token text,
  p_signer_name text,
  p_signer_role text,
  p_signer_cpf text,
  p_signature_data_url text,
  p_user_agent text default null,
  p_client_timezone text default null,
  p_client_timestamp timestamptz default null
)
returns uuid language sql security invoker
as $$ select app_private.rpc_accept_legal_terms(p_session_token, p_signer_name, p_signer_role, p_signer_cpf, p_signature_data_url, p_user_agent, p_client_timezone, p_client_timestamp); $$;

create or replace function public.lc_list_legal_acceptances(p_session_token text)
returns jsonb language sql security invoker
as $$ select app_private.rpc_list_legal_acceptances(p_session_token); $$;

create or replace function public.lc_get_legal_acceptance_document(p_session_token text, p_acceptance_id uuid)
returns jsonb language sql security invoker
as $$ select app_private.rpc_get_legal_acceptance_document(p_session_token, p_acceptance_id); $$;

-- --------------------------------------------------------------------------
-- EXPORTAÇÃO DE PROSPECÇÕES MESMO APÓS O DOWNGRADE
-- --------------------------------------------------------------------------

create or replace function app_private.rpc_export_prospections(p_session_token text, p_store_id uuid default null)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  technician_id uuid,
  name text,
  phone text,
  cpf text,
  notes text,
  probability text,
  tags text[],
  professional_id uuid,
  professional_name text,
  returned_at timestamptz,
  purchased_at timestamptz,
  purchase_amount numeric,
  purchase_order text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_requested_store uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  perform app_private.purge_expired_prospections();
  v_requested_store := case when v_session.user_role::text = 'store' then v_session.user_store_id else p_store_id end;

  return query
  select
    pr.id, pr.store_id, st.name, st.technician_user_id, pr.name, pr.phone, pr.cpf,
    pr.notes, pr.probability, pr.tags, pr.professional_id,
    coalesce(pp.name, pr.professional_name_snapshot), pr.returned_at, pr.purchased_at,
    pr.purchase_amount, pr.purchase_order, pr.created_at, pr.updated_at
  from public.prospections pr
  join public.stores st on st.id = pr.store_id and st.admin_user_id = pr.admin_user_id
  left join public.prospection_professionals pp on pp.id = pr.professional_id
  where pr.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and pr.created_at >= now() - interval '2 years'
    and (v_requested_store is null or pr.store_id = v_requested_store)
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
    )
  order by pr.created_at desc;
end;
$$;

create or replace function public.lc_export_prospections(p_session_token text, p_store_id uuid default null)
returns table (
  id uuid, store_id uuid, store_name text, technician_id uuid, name text,
  phone text, cpf text, notes text, probability text, tags text[],
  professional_id uuid, professional_name text, returned_at timestamptz,
  purchased_at timestamptz, purchase_amount numeric, purchase_order text,
  created_at timestamptz, updated_at timestamptz
)
language sql security invoker
as $$ select * from app_private.rpc_export_prospections(p_session_token, p_store_id); $$;

-- --------------------------------------------------------------------------
-- RETENÇÃO MÓVEL DE DOIS ANOS PARA REGISTROS DE PROSPECÇÕES
-- --------------------------------------------------------------------------

create index if not exists prospections_retention_created_idx
  on public.prospections (created_at);

create or replace function app_private.purge_expired_prospections()
returns integer
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_deleted integer;
begin
  delete from public.prospections
  where created_at < now() - interval '2 years';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

-- O filtro também é aplicado na leitura. Assim, mesmo sem pg_cron habilitado,
-- um registro vencido nunca volta para a interface; a própria consulta remove
-- fisicamente os vencidos antes de retornar a janela válida.
create or replace function app_private.rpc_list_prospections(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  technician_id uuid,
  name text,
  phone text,
  cpf text,
  notes text,
  probability text,
  tags text[],
  professional_id uuid,
  professional_name text,
  returned_at timestamptz,
  purchased_at timestamptz,
  purchase_amount numeric,
  purchase_order text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  perform app_private.purge_expired_prospections();

  return query
  select
    pr.id, pr.store_id, st.name, st.technician_user_id, pr.name, pr.phone, pr.cpf,
    pr.notes, pr.probability, pr.tags, pr.professional_id,
    coalesce(pp.name, pr.professional_name_snapshot), pr.returned_at, pr.purchased_at,
    pr.purchase_amount, pr.purchase_order, pr.created_at, pr.updated_at
  from public.prospections pr
  join public.stores st on st.id = pr.store_id and st.admin_user_id = pr.admin_user_id
  left join public.prospection_professionals pp on pp.id = pr.professional_id
  where pr.admin_user_id = v_session.admin_user_id
    and pr.created_at >= now() - interval '2 years'
    and app_private.prospection_store_allowed(
      v_session.admin_user_id,
      v_session.user_id,
      v_session.user_role,
      v_session.user_store_id,
      pr.store_id,
      false
    )
  order by pr.created_at desc;
end;
$$;

create or replace function app_private.trigger_purge_expired_prospections()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
begin
  perform app_private.purge_expired_prospections();
  return null;
end;
$$;

drop trigger if exists prospections_enforce_two_year_retention on public.prospections;
create trigger prospections_enforce_two_year_retention
after insert on public.prospections
for each statement execute function app_private.trigger_purge_expired_prospections();

-- Limpeza inicial. Registros com mais de dois anos serão removidos ao rodar
-- esta migração; exporte-os antes caso precise manter arquivo próprio.
select app_private.purge_expired_prospections();

-- Se pg_cron já estiver habilitado no Supabase, agenda a limpeza diária.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'lead-control-prospections-retention') then
      perform cron.schedule(
        'lead-control-prospections-retention',
        '17 3 * * *',
        'select app_private.purge_expired_prospections();'
      );
    end if;
  end if;
exception when others then
  raise notice 'Agendamento pg_cron não criado; o trigger de inserção continuará aplicando a retenção.';
end $$;

-- --------------------------------------------------------------------------
-- PERMISSÕES
-- --------------------------------------------------------------------------

revoke all on table public.system_legal_terms from public, anon, authenticated;
revoke all on table public.legal_term_acceptances from public, anon, authenticated;
grant select, insert, update, delete on table public.system_legal_terms to service_role;
grant select, insert, update, delete on table public.legal_term_acceptances to service_role;

revoke all on function app_private.session_user_unchecked(text) from public, anon, authenticated;
revoke all on function app_private.legal_terms_satisfied(uuid, public.app_user_role) from public, anon, authenticated;
revoke all on function app_private.is_valid_cpf(text) from public, anon, authenticated;
revoke all on function app_private.rpc_set_technician_prospection_limit(text, uuid, integer) from public, anon, authenticated;
revoke all on function app_private.rpc_get_required_legal_terms(text) from public, anon, authenticated;
revoke all on function app_private.rpc_accept_legal_terms(text, text, text, text, text, text, text, timestamptz) from public, anon, authenticated;
revoke all on function app_private.rpc_list_legal_acceptances(text) from public, anon, authenticated;
revoke all on function app_private.rpc_get_legal_acceptance_document(text, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_export_prospections(text, uuid) from public, anon, authenticated;
revoke all on function app_private.purge_expired_prospections() from public, anon, authenticated;
revoke all on function app_private.trigger_purge_expired_prospections() from public, anon, authenticated;

grant execute on function app_private.rpc_get_required_legal_terms(text) to anon, authenticated;
grant execute on function app_private.rpc_set_technician_prospection_limit(text, uuid, integer) to anon, authenticated;
grant execute on function app_private.rpc_accept_legal_terms(text, text, text, text, text, text, text, timestamptz) to anon, authenticated;
grant execute on function app_private.rpc_list_legal_acceptances(text) to anon, authenticated;
grant execute on function app_private.rpc_get_legal_acceptance_document(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_export_prospections(text, uuid) to anon, authenticated;

revoke all on function public.lc_get_required_legal_terms(text) from public;
revoke all on function public.lc_accept_legal_terms(text, text, text, text, text, text, text, timestamptz) from public;
revoke all on function public.lc_list_legal_acceptances(text) from public;
revoke all on function public.lc_get_legal_acceptance_document(text, uuid) from public;
revoke all on function public.lc_export_prospections(text, uuid) from public;

grant execute on function public.lc_get_required_legal_terms(text) to anon, authenticated;
grant execute on function public.lc_accept_legal_terms(text, text, text, text, text, text, text, timestamptz) to anon, authenticated;
grant execute on function public.lc_list_legal_acceptances(text) to anon, authenticated;
grant execute on function public.lc_get_legal_acceptance_document(text, uuid) to anon, authenticated;
grant execute on function public.lc_export_prospections(text, uuid) to anon, authenticated;

notify pgrst, 'reload schema';

commit;


-- CONSOLIDACAO DO BANCO COMPLETO | ETAPA 0
-- Fonte integrada: custom_categories_update.sql
-- Rode este arquivo no SQL Editor do Supabase para habilitar
-- categorias adicionais personalizadas nos leads, filtros e metricas.

set search_path = public, extensions;

alter table public.leads
  add column if not exists inspected boolean not null default false;

create index if not exists leads_admin_inspected_created_idx
  on public.leads (admin_user_id, inspected, created_at desc);

create table if not exists public.lead_custom_categories (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.lead_custom_options (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  category_id uuid not null references public.lead_custom_categories(id) on delete cascade,
  value text not null check (length(btrim(value)) > 0),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.lead_custom_values (
  lead_id uuid not null references public.leads(id) on delete cascade,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  category_id uuid not null references public.lead_custom_categories(id) on delete cascade,
  value text not null check (length(btrim(value)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (lead_id, category_id)
);

create unique index if not exists lead_custom_categories_unique_name_idx
  on public.lead_custom_categories (admin_user_id, lower(name))
  where is_active;

create unique index if not exists lead_custom_options_unique_value_idx
  on public.lead_custom_options (category_id, lower(value))
  where is_active;

create index if not exists lead_custom_categories_admin_sort_idx
  on public.lead_custom_categories (admin_user_id, sort_order, created_at);

create index if not exists lead_custom_options_category_sort_idx
  on public.lead_custom_options (category_id, sort_order, created_at);

create index if not exists lead_custom_values_admin_category_idx
  on public.lead_custom_values (admin_user_id, category_id, value);

drop trigger if exists lead_custom_categories_set_updated_at on public.lead_custom_categories;
create trigger lead_custom_categories_set_updated_at
before update on public.lead_custom_categories
for each row execute function app_private.set_updated_at();

drop trigger if exists lead_custom_options_set_updated_at on public.lead_custom_options;
create trigger lead_custom_options_set_updated_at
before update on public.lead_custom_options
for each row execute function app_private.set_updated_at();

drop trigger if exists lead_custom_values_set_updated_at on public.lead_custom_values;
create trigger lead_custom_values_set_updated_at
before update on public.lead_custom_values
for each row execute function app_private.set_updated_at();

alter table public.lead_custom_categories enable row level security;
alter table public.lead_custom_options enable row level security;
alter table public.lead_custom_values enable row level security;

create or replace function app_private.next_custom_category_name(p_admin_user_id uuid)
returns text
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_base text := 'Categoria adicional';
  v_name text := 'Categoria adicional';
  v_counter integer := 2;
begin
  while exists (
    select 1
    from public.lead_custom_categories
    where admin_user_id = p_admin_user_id
      and lower(name) = lower(v_name)
      and is_active = true
  ) loop
    v_name := v_base || ' ' || v_counter;
    v_counter := v_counter + 1;
  end loop;

  return v_name;
end;
$$;

create or replace function app_private.next_custom_option_label(
  p_admin_user_id uuid,
  p_category_id uuid
)
returns text
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_base text := 'Nova opcao';
  v_label text := 'Nova opcao';
  v_counter integer := 2;
begin
  while exists (
    select 1
    from public.lead_custom_options
    where admin_user_id = p_admin_user_id
      and category_id = p_category_id
      and lower(value) = lower(v_label)
      and is_active = true
  ) loop
    v_label := v_base || ' ' || v_counter;
    v_counter := v_counter + 1;
  end loop;

  return v_label;
end;
$$;

create or replace function app_private.rpc_list_custom_categories(p_session_token text)
returns table (
  id uuid,
  name text,
  sort_order integer,
  options jsonb
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select
    c.id,
    c.name,
    c.sort_order,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', o.id,
          'category_id', o.category_id,
          'value', o.value,
          'sort_order', o.sort_order
        )
        order by o.sort_order, o.created_at
      ) filter (where o.id is not null),
      '[]'::jsonb
    ) as options
  from public.lead_custom_categories c
  left join public.lead_custom_options o
    on o.category_id = c.id
   and o.admin_user_id = c.admin_user_id
   and o.is_active = true
  where c.admin_user_id = v_session.admin_user_id
    and c.is_active = true
  group by c.id
  order by c.sort_order, c.created_at;
end;
$$;

create or replace function app_private.rpc_add_custom_category(
  p_session_token text,
  p_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_name text;
  v_category_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar categorias.';
  end if;

  v_name := coalesce(
    nullif(btrim(coalesce(p_name, '')), ''),
    app_private.next_custom_category_name(v_session.admin_user_id)
  );

  insert into public.lead_custom_categories (admin_user_id, name, sort_order)
  values (
    v_session.admin_user_id,
    v_name,
    coalesce((
      select max(sort_order) + 10
      from public.lead_custom_categories
      where admin_user_id = v_session.admin_user_id
    ), 10)
  )
  returning id into v_category_id;

  return v_category_id;
end;
$$;

create or replace function app_private.rpc_update_custom_category(
  p_session_token text,
  p_category_id uuid,
  p_name text
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar categorias.';
  end if;

  update public.lead_custom_categories
  set name = btrim(p_name)
  where id = p_category_id
    and admin_user_id = v_session.admin_user_id
    and is_active = true
    and length(btrim(coalesce(p_name, ''))) > 0;

  if not found then
    raise exception 'Categoria nao encontrada ou vazia.';
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_delete_custom_category(
  p_session_token text,
  p_category_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar categorias.';
  end if;

  update public.lead_custom_categories
  set is_active = false
  where id = p_category_id
    and admin_user_id = v_session.admin_user_id
    and is_active = true;

  if not found then
    raise exception 'Categoria nao encontrada.';
  end if;

  update public.lead_custom_options
  set is_active = false
  where category_id = p_category_id
    and admin_user_id = v_session.admin_user_id
    and is_active = true;

  return true;
end;
$$;

create or replace function app_private.rpc_add_custom_option(
  p_session_token text,
  p_category_id uuid,
  p_value text default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_value text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar categorias.';
  end if;

  if not exists (
    select 1
    from public.lead_custom_categories
    where id = p_category_id
      and admin_user_id = v_session.admin_user_id
      and is_active = true
  ) then
    raise exception 'Categoria nao encontrada.';
  end if;

  v_value := coalesce(
    nullif(btrim(coalesce(p_value, '')), ''),
    app_private.next_custom_option_label(v_session.admin_user_id, p_category_id)
  );

  insert into public.lead_custom_options (admin_user_id, category_id, value, sort_order)
  values (
    v_session.admin_user_id,
    p_category_id,
    v_value,
    coalesce((
      select max(sort_order) + 10
      from public.lead_custom_options
      where admin_user_id = v_session.admin_user_id
        and category_id = p_category_id
    ), 10)
  );

  return true;
end;
$$;

create or replace function app_private.rpc_update_custom_option(
  p_session_token text,
  p_option_id uuid,
  p_value text
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar categorias.';
  end if;

  update public.lead_custom_options
  set value = btrim(p_value)
  where id = p_option_id
    and admin_user_id = v_session.admin_user_id
    and is_active = true
    and length(btrim(coalesce(p_value, ''))) > 0;

  if not found then
    raise exception 'Opcao nao encontrada ou vazia.';
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_delete_custom_option(
  p_session_token text,
  p_option_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar categorias.';
  end if;

  update public.lead_custom_options
  set is_active = false
  where id = p_option_id
    and admin_user_id = v_session.admin_user_id
    and is_active = true;

  if not found then
    raise exception 'Opcao nao encontrada.';
  end if;

  return true;
end;
$$;

drop function if exists public.lc_list_leads(text);
drop function if exists app_private.rpc_list_leads(text);

create or replace function app_private.rpc_list_leads(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  inspected boolean,
  custom_values jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select
    l.id,
    l.store_id,
    st.name as store_name,
    l.name,
    l.phone,
    l.channel,
    l.campaign,
    l.conversation_start,
    l.conclusion,
    l.visited,
    l.bought,
    l.purchase_amount,
    l.service_order,
    l.notes,
    l.inspected,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'category_id', c.id,
          'category_name', c.name,
          'value', v.value
        )
        order by c.sort_order, c.created_at
      )
      from public.lead_custom_values v
      join public.lead_custom_categories c
        on c.id = v.category_id
       and c.admin_user_id = v.admin_user_id
       and c.is_active = true
      where v.lead_id = l.id
        and v.admin_user_id = l.admin_user_id
    ), '[]'::jsonb) as custom_values,
    l.created_at,
    l.updated_at
  from public.leads l
  join public.stores st on st.id = l.store_id
  where l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role = 'admin'
      or l.store_id = v_session.user_store_id
    )
  order by l.created_at desc;
end;
$$;

drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, jsonb, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, jsonb, uuid);

create or replace function app_private.rpc_upsert_lead(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_custom_values jsonb default '[]'::jsonb,
  p_store_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_lead_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if length(btrim(coalesce(p_name, ''))) = 0 or length(btrim(coalesce(p_phone, ''))) = 0 then
    raise exception 'Preencha nome e telefone.';
  end if;

  if jsonb_typeof(coalesce(p_custom_values, '[]'::jsonb)) <> 'array' then
    raise exception 'Categorias adicionais invalidas.';
  end if;

  if nullif(btrim(coalesce(p_visited, '')), '') = 'Sim'
     and nullif(btrim(coalesce(p_bought, '')), '') is null then
    raise exception 'Informe se o lead comprou ou nao.';
  end if;

  if nullif(btrim(coalesce(p_bought, '')), '') = 'Sim'
     and (p_purchase_amount is null or p_purchase_amount <= 0 or nullif(btrim(coalesce(p_service_order, '')), '') is null) then
    raise exception 'Informe o valor da compra e a OS.';
  end if;

  if v_session.user_role = 'store' then
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if p_lead_id is not null and v_store_id is null then
    select store_id
    into v_store_id
    from public.leads
    where id = p_lead_id
      and admin_user_id = v_session.admin_user_id;
  end if;

  if v_store_id is null then
    raise exception 'Loja obrigatoria para cadastrar lead.';
  end if;

  if not exists (
    select 1
    from public.stores
    where id = v_store_id
      and admin_user_id = v_session.admin_user_id
      and is_active = true
  ) then
    raise exception 'Loja nao encontrada ou sem permissao.';
  end if;

  if p_lead_id is null then
    insert into public.leads (
      admin_user_id,
      store_id,
      name,
      phone,
      channel,
      campaign,
      conversation_start,
      conclusion,
      visited,
      bought,
      purchase_amount,
      service_order,
      notes,
      created_by,
      updated_by
    )
    values (
      v_session.admin_user_id,
      v_store_id,
      btrim(p_name),
      btrim(p_phone),
      nullif(btrim(coalesce(p_channel, '')), ''),
      nullif(btrim(coalesce(p_campaign, '')), ''),
      nullif(btrim(coalesce(p_conversation_start, '')), ''),
      nullif(btrim(coalesce(p_conclusion, '')), ''),
      nullif(btrim(coalesce(p_visited, '')), ''),
      nullif(btrim(coalesce(p_bought, '')), ''),
      case when nullif(btrim(coalesce(p_bought, '')), '') = 'Sim' then p_purchase_amount else null end,
      case when nullif(btrim(coalesce(p_bought, '')), '') = 'Sim' then nullif(btrim(coalesce(p_service_order, '')), '') else null end,
      nullif(btrim(coalesce(p_notes, '')), ''),
      v_session.user_id,
      v_session.user_id
    )
    returning id into v_lead_id;
  else
    update public.leads
    set
      store_id = v_store_id,
      name = btrim(p_name),
      phone = btrim(p_phone),
      channel = nullif(btrim(coalesce(p_channel, '')), ''),
      campaign = nullif(btrim(coalesce(p_campaign, '')), ''),
      conversation_start = nullif(btrim(coalesce(p_conversation_start, '')), ''),
      conclusion = nullif(btrim(coalesce(p_conclusion, '')), ''),
      visited = nullif(btrim(coalesce(p_visited, '')), ''),
      bought = nullif(btrim(coalesce(p_bought, '')), ''),
      purchase_amount = case when nullif(btrim(coalesce(p_bought, '')), '') = 'Sim' then p_purchase_amount else null end,
      service_order = case when nullif(btrim(coalesce(p_bought, '')), '') = 'Sim' then nullif(btrim(coalesce(p_service_order, '')), '') else null end,
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      updated_by = v_session.user_id
    where id = p_lead_id
      and admin_user_id = v_session.admin_user_id
      and (
        v_session.user_role = 'admin'
        or store_id = v_session.user_store_id
      )
    returning id into v_lead_id;

    if not found then
      raise exception 'Lead nao encontrado ou sem permissao.';
    end if;
  end if;

  delete from public.lead_custom_values
  where lead_id = v_lead_id
    and admin_user_id = v_session.admin_user_id;

  insert into public.lead_custom_values (admin_user_id, lead_id, category_id, value)
  select
    v_session.admin_user_id,
    v_lead_id,
    c.id,
    o.value
  from jsonb_array_elements(coalesce(p_custom_values, '[]'::jsonb)) as item(value)
  join public.lead_custom_categories c
    on c.id = nullif(item.value->>'category_id', '')::uuid
   and c.admin_user_id = v_session.admin_user_id
   and c.is_active = true
  join public.lead_custom_options o
    on o.category_id = c.id
   and o.admin_user_id = v_session.admin_user_id
   and o.is_active = true
   and lower(o.value) = lower(nullif(btrim(coalesce(item.value->>'value', '')), ''))
  where nullif(btrim(coalesce(item.value->>'value', '')), '') is not null
  on conflict (lead_id, category_id) do update
  set
    value = excluded.value,
    updated_at = now();

  return v_lead_id;
end;
$$;

create or replace function public.lc_list_custom_categories(p_session_token text)
returns table (
  id uuid,
  name text,
  sort_order integer,
  options jsonb
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_custom_categories(p_session_token);
$$;

create or replace function public.lc_add_custom_category(
  p_session_token text,
  p_name text default null
)
returns uuid
language sql
security invoker
as $$
  select app_private.rpc_add_custom_category(p_session_token, p_name);
$$;

create or replace function public.lc_update_custom_category(
  p_session_token text,
  p_category_id uuid,
  p_name text
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_update_custom_category(p_session_token, p_category_id, p_name);
$$;

create or replace function public.lc_delete_custom_category(
  p_session_token text,
  p_category_id uuid
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_custom_category(p_session_token, p_category_id);
$$;

create or replace function public.lc_add_custom_option(
  p_session_token text,
  p_category_id uuid,
  p_value text default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_add_custom_option(p_session_token, p_category_id, p_value);
$$;

create or replace function public.lc_update_custom_option(
  p_session_token text,
  p_option_id uuid,
  p_value text
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_update_custom_option(p_session_token, p_option_id, p_value);
$$;

create or replace function public.lc_delete_custom_option(
  p_session_token text,
  p_option_id uuid
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_custom_option(p_session_token, p_option_id);
$$;

create or replace function public.lc_list_leads(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  inspected boolean,
  custom_values jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_leads(p_session_token);
$$;

create or replace function public.lc_upsert_lead(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_custom_values jsonb default '[]'::jsonb,
  p_store_id uuid default null
)
returns uuid
language sql
security invoker
as $$
  select app_private.rpc_upsert_lead(
    p_session_token,
    p_lead_id,
    p_name,
    p_phone,
    p_channel,
    p_campaign,
    p_conversation_start,
    p_conclusion,
    p_visited,
    p_bought,
    p_purchase_amount,
    p_service_order,
    p_notes,
    p_custom_values,
    p_store_id
  );
$$;

revoke all on table public.lead_custom_categories from anon, authenticated;
revoke all on table public.lead_custom_options from anon, authenticated;
revoke all on table public.lead_custom_values from anon, authenticated;

grant select, insert, update, delete on table public.lead_custom_categories to service_role;
grant select, insert, update, delete on table public.lead_custom_options to service_role;
grant select, insert, update, delete on table public.lead_custom_values to service_role;

grant usage on schema app_private to anon, authenticated;

grant execute on function app_private.rpc_list_custom_categories(text) to anon, authenticated;
grant execute on function app_private.rpc_add_custom_category(text, text) to anon, authenticated;
grant execute on function app_private.rpc_update_custom_category(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_custom_category(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_add_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_update_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_custom_option(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_list_leads(text) to anon, authenticated;
grant execute on function app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, jsonb, uuid) to anon, authenticated;

grant execute on function public.lc_list_custom_categories(text) to anon, authenticated;
grant execute on function public.lc_add_custom_category(text, text) to anon, authenticated;
grant execute on function public.lc_update_custom_category(text, uuid, text) to anon, authenticated;
grant execute on function public.lc_delete_custom_category(text, uuid) to anon, authenticated;
grant execute on function public.lc_add_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function public.lc_update_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function public.lc_delete_custom_option(text, uuid) to anon, authenticated;
grant execute on function public.lc_list_leads(text) to anon, authenticated;
grant execute on function public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, jsonb, uuid) to anon, authenticated;

-- CONSOLIDACAO DO BANCO COMPLETO | ETAPA 1
-- Fonte integrada: lead_contact_date_update.sql
-- Rode este arquivo no SQL Editor do Supabase para adicionar
-- a data em que o lead entrou em contato.
-- O campo nao e obrigatorio: quando vier vazio, o banco usa o dia atual.

set search_path = public, extensions;

alter table public.leads
  add column if not exists contact_date date;

update public.leads
set contact_date = coalesce(
  contact_date,
  (timezone('America/Sao_Paulo', created_at))::date,
  (timezone('America/Sao_Paulo', now()))::date
)
where contact_date is null;

alter table public.leads
  alter column contact_date set default ((timezone('America/Sao_Paulo', now()))::date);

alter table public.leads
  alter column contact_date set not null;

create index if not exists leads_admin_contact_date_idx
  on public.leads (admin_user_id, contact_date desc, created_at desc);

create index if not exists leads_store_contact_date_idx
  on public.leads (store_id, contact_date desc, created_at desc);

drop function if exists public.lc_list_leads(text);
drop function if exists app_private.rpc_list_leads(text);

create or replace function app_private.rpc_list_leads(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  contact_date date,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  scheduled text,
  scheduled_visit_date date,
  scheduled_visit_time time,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  inspected boolean,
  custom_values jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select
    l.id,
    l.store_id,
    st.name as store_name,
    l.name,
    l.phone,
    l.contact_date,
    l.channel,
    l.campaign,
    l.conversation_start,
    l.conclusion,
    l.scheduled,
    l.scheduled_visit_date,
    l.scheduled_visit_time,
    l.visited,
    l.bought,
    l.purchase_amount,
    l.service_order,
    l.notes,
    l.inspected,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'category_id', c.id,
          'category_name', c.name,
          'value', v.value
        )
        order by c.sort_order, c.created_at
      )
      from public.lead_custom_values v
      join public.lead_custom_categories c
        on c.id = v.category_id
       and c.admin_user_id = v.admin_user_id
       and c.is_active = true
      where v.lead_id = l.id
        and v.admin_user_id = l.admin_user_id
    ), '[]'::jsonb) as custom_values,
    l.created_at,
    l.updated_at
  from public.leads l
  join public.stores st on st.id = l.store_id
  where l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text in ('admin', 'technician')
      or l.store_id = v_session.user_store_id
    )
  order by l.created_at desc;
end;
$$;

create or replace function public.lc_list_leads(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  contact_date date,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  scheduled text,
  scheduled_visit_date date,
  scheduled_visit_time time,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  inspected boolean,
  custom_values jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_leads(p_session_token);
$$;

drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, jsonb, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, jsonb, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid);

create or replace function app_private.rpc_upsert_lead(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_scheduled text default null,
  p_scheduled_visit_date date default null,
  p_scheduled_visit_time time default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_custom_values jsonb default '[]'::jsonb,
  p_store_id uuid default null,
  p_contact_date date default null
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_lead_id uuid;
  v_contact_date date;
  v_scheduled text;
  v_visited text;
  v_bought text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  v_contact_date := coalesce(p_contact_date, (timezone('America/Sao_Paulo', now()))::date);
  v_scheduled := nullif(btrim(coalesce(p_scheduled, '')), '');
  v_visited := nullif(btrim(coalesce(p_visited, '')), '');
  v_bought := nullif(btrim(coalesce(p_bought, '')), '');

  if length(btrim(coalesce(p_name, ''))) = 0 or length(btrim(coalesce(p_phone, ''))) = 0 then
    raise exception 'Preencha nome e telefone.';
  end if;

  if jsonb_typeof(coalesce(p_custom_values, '[]'::jsonb)) <> 'array' then
    raise exception 'Categorias adicionais invalidas.';
  end if;

  if v_scheduled is null then
    raise exception 'Informe se o lead agendou visita ou nao.';
  end if;

  if v_scheduled not in ('Sim', 'Não') then
    raise exception 'Agendamento invalido.';
  end if;

  if v_scheduled = 'Sim' and p_scheduled_visit_date is null then
    raise exception 'Informe a data da visita agendada.';
  end if;

  if v_visited = 'Sim' and v_bought is null then
    raise exception 'Informe se o lead comprou ou nao.';
  end if;

  if v_bought = 'Sim'
     and (p_purchase_amount is null or p_purchase_amount <= 0 or nullif(btrim(coalesce(p_service_order, '')), '') is null) then
    raise exception 'Informe o valor da compra e a OS.';
  end if;

  if v_session.user_role::text = 'store' then
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if p_lead_id is not null and v_store_id is null then
    select store_id
    into v_store_id
    from public.leads
    where id = p_lead_id
      and admin_user_id = v_session.admin_user_id;
  end if;

  if v_store_id is null then
    raise exception 'Loja obrigatoria para cadastrar lead.';
  end if;

  if not exists (
    select 1
    from public.stores
    where id = v_store_id
      and admin_user_id = v_session.admin_user_id
      and is_active = true
  ) then
    raise exception 'Loja nao encontrada ou sem permissao.';
  end if;

  if p_lead_id is null then
    insert into public.leads (
      admin_user_id,
      store_id,
      name,
      phone,
      contact_date,
      channel,
      campaign,
      conversation_start,
      conclusion,
      scheduled,
      scheduled_visit_date,
      scheduled_visit_time,
      visited,
      bought,
      purchase_amount,
      service_order,
      notes,
      created_by,
      updated_by
    )
    values (
      v_session.admin_user_id,
      v_store_id,
      btrim(p_name),
      btrim(p_phone),
      v_contact_date,
      nullif(btrim(coalesce(p_channel, '')), ''),
      nullif(btrim(coalesce(p_campaign, '')), ''),
      nullif(btrim(coalesce(p_conversation_start, '')), ''),
      nullif(btrim(coalesce(p_conclusion, '')), ''),
      v_scheduled,
      case when v_scheduled = 'Sim' then p_scheduled_visit_date else null end,
      case when v_scheduled = 'Sim' then p_scheduled_visit_time else null end,
      v_visited,
      v_bought,
      case when v_bought = 'Sim' then p_purchase_amount else null end,
      case when v_bought = 'Sim' then nullif(btrim(coalesce(p_service_order, '')), '') else null end,
      nullif(btrim(coalesce(p_notes, '')), ''),
      v_session.user_id,
      v_session.user_id
    )
    returning id into v_lead_id;
  else
    update public.leads
    set
      store_id = v_store_id,
      name = btrim(p_name),
      phone = btrim(p_phone),
      contact_date = v_contact_date,
      channel = nullif(btrim(coalesce(p_channel, '')), ''),
      campaign = nullif(btrim(coalesce(p_campaign, '')), ''),
      conversation_start = nullif(btrim(coalesce(p_conversation_start, '')), ''),
      conclusion = nullif(btrim(coalesce(p_conclusion, '')), ''),
      scheduled = v_scheduled,
      scheduled_visit_date = case when v_scheduled = 'Sim' then p_scheduled_visit_date else null end,
      scheduled_visit_time = case when v_scheduled = 'Sim' then p_scheduled_visit_time else null end,
      visited = v_visited,
      bought = v_bought,
      purchase_amount = case when v_bought = 'Sim' then p_purchase_amount else null end,
      service_order = case when v_bought = 'Sim' then nullif(btrim(coalesce(p_service_order, '')), '') else null end,
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      updated_by = v_session.user_id
    where id = p_lead_id
      and admin_user_id = v_session.admin_user_id
      and (
        v_session.user_role::text = 'admin'
        or store_id = v_session.user_store_id
      )
    returning id into v_lead_id;

    if not found then
      raise exception 'Lead nao encontrado ou sem permissao.';
    end if;
  end if;

  delete from public.lead_custom_values
  where lead_id = v_lead_id
    and admin_user_id = v_session.admin_user_id;

  insert into public.lead_custom_values (admin_user_id, lead_id, category_id, value)
  select
    v_session.admin_user_id,
    v_lead_id,
    c.id,
    o.value
  from jsonb_array_elements(coalesce(p_custom_values, '[]'::jsonb)) as item(value)
  join public.lead_custom_categories c
    on c.id = nullif(item.value->>'category_id', '')::uuid
   and c.admin_user_id = v_session.admin_user_id
   and c.is_active = true
  join public.lead_custom_options o
    on o.category_id = c.id
   and o.admin_user_id = v_session.admin_user_id
   and o.is_active = true
   and lower(o.value) = lower(nullif(btrim(coalesce(item.value->>'value', '')), ''))
  where nullif(btrim(coalesce(item.value->>'value', '')), '') is not null
  on conflict (lead_id, category_id) do update
  set
    value = excluded.value,
    updated_at = now();

  return v_lead_id;
end;
$$;

create or replace function public.lc_upsert_lead(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_scheduled text default null,
  p_scheduled_visit_date date default null,
  p_scheduled_visit_time time default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_custom_values jsonb default '[]'::jsonb,
  p_store_id uuid default null,
  p_contact_date date default null
)
returns uuid
language sql
security invoker
as $$
  select app_private.rpc_upsert_lead(
    p_session_token,
    p_lead_id,
    p_name,
    p_phone,
    p_channel,
    p_campaign,
    p_conversation_start,
    p_conclusion,
    p_scheduled,
    p_scheduled_visit_date,
    p_scheduled_visit_time,
    p_visited,
    p_bought,
    p_purchase_amount,
    p_service_order,
    p_notes,
    p_custom_values,
    p_store_id,
    p_contact_date
  );
$$;

grant execute on function app_private.rpc_list_leads(text) to anon, authenticated;
grant execute on function public.lc_list_leads(text) to anon, authenticated;
grant execute on function app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date) to anon, authenticated;
grant execute on function public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date) to anon, authenticated;

notify pgrst, 'reload schema';

-- Verificacao do Realtime no projeto. Se leads_in_realtime vier false,
-- a tabela public.leads ainda nao esta publicada para Postgres Changes.
-- Para habilitar depois, rode:
-- alter publication supabase_realtime add table public.leads;
with realtime_tables as (
  select schemaname, tablename
  from pg_publication_tables
  where pubname = 'supabase_realtime'
)
select
  exists (
    select 1
    from pg_publication
    where pubname = 'supabase_realtime'
  ) as realtime_publication_exists,
  exists (
    select 1
    from realtime_tables
    where schemaname = 'public'
      and tablename = 'leads'
  ) as leads_in_realtime,
  coalesce((
    select jsonb_agg(format('%I.%I', schemaname, tablename) order by schemaname, tablename)
    from realtime_tables
  ), '[]'::jsonb) as realtime_tables;

-- CONSOLIDACAO DO BANCO COMPLETO | ETAPA 2
-- Fonte integrada: b2b_client_hierarchy_update.sql
-- Hierarquia B2B: admin -> empresa de trafego (technician) -> lojas.
-- Rode este arquivo no SQL Editor do Supabase depois das migracoes existentes.

begin;

set search_path = public, extensions;

alter table public.app_users
  add column if not exists store_limit integer not null default 5;

update public.app_users
set store_limit = 0
where role::text <> 'technician'
  and store_limit <> 0;

alter table public.app_users
  alter column store_limit set default 0;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'app_users_store_limit_check'
      and conrelid = 'public.app_users'::regclass
  ) then
    alter table public.app_users
      add constraint app_users_store_limit_check
      check (store_limit between 0 and 9999);
  end if;
end;
$$;

alter table public.stores
  add column if not exists technician_user_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'stores_technician_user_fk'
      and conrelid = 'public.stores'::regclass
  ) then
    alter table public.stores
      add constraint stores_technician_user_fk
      foreign key (technician_user_id)
      references public.app_users(id)
      on delete set null;
  end if;
end;
$$;

-- Preserva instalacoes antigas: quando um admin tem uma unica empresa,
-- associa automaticamente a ela as lojas que ainda nao tinham responsavel.
with single_technician as (
  select admin_user_id, min(id::text)::uuid as technician_user_id
  from public.app_users
  where role::text = 'technician'
    and is_active = true
  group by admin_user_id
  having count(*) = 1
)
update public.stores st
set technician_user_id = single_technician.technician_user_id
from single_technician
where st.admin_user_id = single_technician.admin_user_id
  and st.technician_user_id is null;

create index if not exists stores_technician_active_created_idx
  on public.stores (technician_user_id, is_active, created_at desc);

create or replace function app_private.technician_can_access_store(
  p_admin_user_id uuid,
  p_technician_user_id uuid,
  p_store_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  select exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = p_admin_user_id
      and st.technician_user_id = p_technician_user_id
      and st.is_active = true
  );
$$;

-- Criacao de empresas com limite definido pelo admin.
drop function if exists public.lc_create_technician(text, text, text, text);
drop function if exists app_private.rpc_create_technician(text, text, text, text);

create or replace function app_private.rpc_create_technician(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer default 5
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_user_id uuid;
  v_nick_key text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o admin pode criar uma empresa.';
  end if;

  if length(btrim(coalesce(p_full_name, ''))) = 0 then
    raise exception 'Digite o nome da empresa.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para a empresa.';
  end if;

  if length(coalesce(p_password, '')) < 6 then
    raise exception 'A senha da empresa precisa ter pelo menos 6 caracteres.';
  end if;

  if coalesce(p_store_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de clientes entre 0 e 9999.';
  end if;

  if exists (select 1 from public.app_users au where au.nick_key = v_nick_key) then
    raise exception 'Esse login ja existe.';
  end if;

  insert into public.app_users as new_user (
    nick,
    password_hash,
    full_name,
    role,
    admin_user_id,
    store_id,
    store_limit
  )
  values (
    v_nick_key,
    crypt(p_password, gen_salt('bf')),
    btrim(p_full_name),
    'technician',
    v_session.admin_user_id,
    null,
    p_store_limit
  )
  returning new_user.id into v_user_id;

  return query
  select
    u.id,
    u.nick_key,
    u.full_name,
    u.is_active,
    u.created_at,
    u.store_limit,
    0::bigint
  from public.app_users u
  where u.id = v_user_id;
end;
$$;

create or replace function public.lc_create_technician(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer default 5
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_create_technician(
    p_session_token,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit
  );
$$;

-- Listagem das empresas com consumo atual da franquia.
drop function if exists public.lc_list_technicians(text);
drop function if exists app_private.rpc_list_technicians(text);

create or replace function app_private.rpc_list_technicians(p_session_token text)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o admin pode listar empresas.';
  end if;

  return query
  select
    u.id,
    u.nick_key,
    u.full_name,
    u.is_active,
    u.created_at,
    u.store_limit,
    count(st.id) filter (where st.is_active = true) as store_count
  from public.app_users u
  left join public.stores st on st.technician_user_id = u.id
  where u.admin_user_id = v_session.admin_user_id
    and u.role::text = 'technician'
  group by u.id
  order by u.created_at desc;
end;
$$;

create or replace function public.lc_list_technicians(p_session_token text)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_technicians(p_session_token);
$$;

-- Alteracao de credenciais e limite da empresa.
drop function if exists public.lc_update_technician_account(text, uuid, text, text, text);
drop function if exists app_private.rpc_update_technician_account(text, uuid, text, text, text);

create or replace function app_private.rpc_update_technician_account(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_nick_key text;
  v_password text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o admin pode editar uma empresa.';
  end if;

  if length(btrim(coalesce(p_full_name, ''))) = 0 then
    raise exception 'Digite o nome da empresa.';
  end if;

  if coalesce(p_store_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de clientes entre 0 e 9999.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para a empresa.';
  end if;

  v_password := nullif(coalesce(p_password, ''), '');
  if v_password is not null and length(v_password) < 6 then
    raise exception 'A nova senha precisa ter pelo menos 6 caracteres.';
  end if;

  if not exists (
    select 1
    from public.app_users au
    where au.id = p_technician_id
      and au.admin_user_id = v_session.admin_user_id
      and au.role::text = 'technician'
      and au.is_active = true
  ) then
    raise exception 'Empresa nao encontrada.';
  end if;

  if exists (
    select 1
    from public.app_users au
    where au.nick_key = v_nick_key
      and au.id <> p_technician_id
  ) then
    raise exception 'Esse login ja existe.';
  end if;

  update public.app_users au
  set
    nick = v_nick_key,
    full_name = btrim(p_full_name),
    store_limit = p_store_limit,
    password_hash = case
      when v_password is null then au.password_hash
      else crypt(v_password, gen_salt('bf'))
    end
  where au.id = p_technician_id
    and au.admin_user_id = v_session.admin_user_id
    and au.role::text = 'technician';

  return query
  select
    au.id,
    au.nick_key,
    au.full_name,
    au.is_active,
    au.created_at,
    au.store_limit,
    count(st.id) filter (where st.is_active = true) as store_count
  from public.app_users au
  left join public.stores st on st.technician_user_id = au.id
  where au.id = p_technician_id
  group by au.id;
end;
$$;

create or replace function public.lc_update_technician_account(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_update_technician_account(
    p_session_token,
    p_technician_id,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit
  );
$$;

-- Criacao de loja pela propria empresa, com bloqueio concorrente do limite.
drop function if exists public.lc_create_store(text, text, text, text);
drop function if exists app_private.rpc_create_store(text, text, text, text);

create or replace function app_private.rpc_create_store(
  p_session_token text,
  p_name text,
  p_nick text,
  p_password text,
  p_technician_id uuid default null
)
returns table (
  store_id uuid,
  store_name text,
  store_nick text,
  user_id uuid,
  user_nick text,
  technician_id uuid
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_user_id uuid;
  v_nick_key text;
  v_technician_id uuid;
  v_store_limit integer;
  v_store_count bigint;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'technician' then
    v_technician_id := v_session.user_id;
    if p_technician_id is not null and p_technician_id <> v_session.user_id then
      raise exception 'Empresa sem permissao para criar esta loja.';
    end if;
  elsif v_session.user_role::text = 'admin' then
    v_technician_id := p_technician_id;
  else
    raise exception 'Apenas o admin ou a empresa podem criar lojas.';
  end if;

  if v_technician_id is null then
    raise exception 'Selecione a empresa responsavel pela loja.';
  end if;

  -- O lock impede que cadastros simultaneos ultrapassem a franquia.
  select au.store_limit
  into v_store_limit
  from public.app_users au
  where au.id = v_technician_id
    and au.admin_user_id = v_session.admin_user_id
    and au.role::text = 'technician'
    and au.is_active = true
  for update;

  if not found then
    raise exception 'Empresa nao encontrada ou inativa.';
  end if;

  select count(*)
  into v_store_count
  from public.stores st
  where st.technician_user_id = v_technician_id
    and st.is_active = true;

  if v_store_count >= v_store_limit then
    raise exception 'Limite de clientes atingido (% de %).', v_store_count, v_store_limit;
  end if;

  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'Digite o nome da loja.';
  end if;

  if length(coalesce(p_password, '')) < 6 then
    raise exception 'A senha da loja precisa ter pelo menos 6 caracteres.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para a loja.';
  end if;

  if exists (select 1 from public.app_users au where au.nick_key = v_nick_key) then
    raise exception 'Esse login ja existe.';
  end if;

  insert into public.stores (admin_user_id, technician_user_id, name, nick)
  values (v_session.admin_user_id, v_technician_id, btrim(p_name), v_nick_key)
  returning id into v_store_id;

  insert into public.app_users (nick, password_hash, full_name, role, admin_user_id, store_id, store_limit)
  values (
    v_nick_key,
    crypt(p_password, gen_salt('bf')),
    btrim(p_name),
    'store',
    v_session.admin_user_id,
    v_store_id,
    0
  )
  returning id into v_user_id;

  return query
  select st.id, st.name, st.nick_key, u.id, u.nick_key, st.technician_user_id
  from public.stores st
  join public.app_users u on u.store_id = st.id and u.role::text = 'store'
  where st.id = v_store_id;
end;
$$;

create or replace function public.lc_create_store(
  p_session_token text,
  p_name text,
  p_nick text,
  p_password text,
  p_technician_id uuid default null
)
returns table (
  store_id uuid,
  store_name text,
  store_nick text,
  user_id uuid,
  user_nick text,
  technician_id uuid
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_create_store(
    p_session_token,
    p_name,
    p_nick,
    p_password,
    p_technician_id
  );
$$;

-- Cada papel ve apenas as lojas do seu escopo.
drop function if exists public.lc_list_stores(text);
drop function if exists app_private.rpc_list_stores(text);

create or replace function app_private.rpc_list_stores(p_session_token text)
returns table (
  id uuid,
  name text,
  nick text,
  created_at timestamptz,
  leads_count bigint,
  sales_count bigint,
  technician_id uuid,
  technician_name text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select
    st.id,
    st.name,
    st.nick_key,
    st.created_at,
    count(l.id) as leads_count,
    count(l.id) filter (where l.bought = 'Sim') as sales_count,
    st.technician_user_id,
    tech.full_name
  from public.stores st
  left join public.app_users tech on tech.id = st.technician_user_id
  left join public.leads l on l.store_id = st.id and l.admin_user_id = st.admin_user_id
  where st.is_active = true
    and st.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
    )
  group by st.id, tech.full_name
  order by st.created_at desc;
end;
$$;

create or replace function public.lc_list_stores(p_session_token text)
returns table (
  id uuid,
  name text,
  nick text,
  created_at timestamptz,
  leads_count bigint,
  sales_count bigint,
  technician_id uuid,
  technician_name text
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_stores(p_session_token);
$$;

-- A empresa pode trocar nome/login/senha apenas das lojas da propria carteira.
drop function if exists public.lc_update_store_account(text, uuid, text, text, text);
drop function if exists public.lc_update_store_account(text, uuid, text, text, text, uuid);
drop function if exists app_private.rpc_update_store_account(text, uuid, text, text, text);
drop function if exists app_private.rpc_update_store_account(text, uuid, text, text, text, uuid);

create or replace function app_private.rpc_update_store_account(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null
)
returns table (
  id uuid,
  name text,
  nick text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_nick_key text;
  v_password text;
  v_technician_id uuid;
  v_current_technician_id uuid;
  v_store_limit integer;
  v_store_count bigint;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Sem permissao para editar esta loja.';
  end if;

  if v_session.user_role::text = 'technician' then
    v_technician_id := v_session.user_id;
    if p_technician_id is not null and p_technician_id <> v_session.user_id then
      raise exception 'Empresa sem permissao para transferir esta loja.';
    end if;
  else
    v_technician_id := p_technician_id;
  end if;

  if v_technician_id is null then
    raise exception 'Selecione a empresa responsavel pela loja.';
  end if;

  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'Digite o nome da loja.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para a loja.';
  end if;

  v_password := nullif(coalesce(p_password, ''), '');
  if v_password is not null and length(v_password) < 6 then
    raise exception 'A nova senha precisa ter pelo menos 6 caracteres.';
  end if;

  select st.technician_user_id
  into v_current_technician_id
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true
      and (
        v_session.user_role::text = 'admin'
        or st.technician_user_id = v_session.user_id
      );

  if not found then
    raise exception 'Loja nao encontrada ou sem permissao.';
  end if;

  select au.store_limit
  into v_store_limit
  from public.app_users au
  where au.id = v_technician_id
    and au.admin_user_id = v_session.admin_user_id
    and au.role::text = 'technician'
    and au.is_active = true
  for update;

  if not found then
    raise exception 'Empresa nao encontrada ou inativa.';
  end if;

  if v_current_technician_id is distinct from v_technician_id then
    select count(*)
    into v_store_count
    from public.stores st
    where st.technician_user_id = v_technician_id
      and st.is_active = true;

    if v_store_count >= v_store_limit then
      raise exception 'Limite de clientes da empresa de destino atingido (% de %).', v_store_count, v_store_limit;
    end if;
  end if;

  if exists (
    select 1
    from public.app_users au
    where au.nick_key = v_nick_key
      and not (au.role::text = 'store' and au.store_id = p_store_id)
  ) or exists (
    select 1
    from public.stores st
    where st.nick_key = v_nick_key
      and st.id <> p_store_id
  ) then
    raise exception 'Esse login ja existe.';
  end if;

  update public.stores st
  set
    name = btrim(p_name),
    nick = v_nick_key,
    technician_user_id = v_technician_id
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id;

  update public.app_users au
  set
    nick = v_nick_key,
    full_name = btrim(p_name),
    password_hash = case
      when v_password is null then au.password_hash
      else crypt(v_password, gen_salt('bf'))
    end
  where au.role::text = 'store'
    and au.store_id = p_store_id
    and au.admin_user_id = v_session.admin_user_id
    and au.is_active = true;

  if not found then
    raise exception 'Usuario da loja nao encontrado.';
  end if;

  return query
  select st.id, st.name, st.nick_key
  from public.stores st
  where st.id = p_store_id;
end;
$$;

create or replace function public.lc_update_store_account(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null
)
returns table (
  id uuid,
  name text,
  nick text
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_update_store_account(
    p_session_token,
    p_store_id,
    p_name,
    p_nick,
    p_password,
    p_technician_id
  );
$$;

-- Indicador da franquia para o painel da empresa.
create or replace function app_private.rpc_account_usage(p_session_token text)
returns table (
  technician_id uuid,
  store_limit integer,
  store_count bigint
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'technician' then
    raise exception 'Indicador disponivel apenas para empresas.';
  end if;

  return query
  select
    u.id,
    u.store_limit,
    count(st.id) filter (where st.is_active = true) as store_count
  from public.app_users u
  left join public.stores st on st.technician_user_id = u.id
  where u.id = v_session.user_id
  group by u.id;
end;
$$;

create or replace function public.lc_account_usage(p_session_token text)
returns table (
  technician_id uuid,
  store_limit integer,
  store_count bigint
)
language sql
security invoker
as $$
  select * from app_private.rpc_account_usage(p_session_token);
$$;

-- Leitura dos leads isolada por empresa em uma funcao nova. O nome separado
-- torna a migracao compativel com as duas versoes antigas de contact_date.
create or replace function app_private.rpc_list_leads_b2b(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  contact_date date,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  scheduled text,
  scheduled_visit_date date,
  scheduled_visit_time time,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  inspected boolean,
  custom_values jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select
    l.id,
    l.store_id,
    st.name,
    l.name,
    l.phone,
    l.contact_date,
    l.channel,
    l.campaign,
    l.conversation_start,
    l.conclusion,
    l.scheduled,
    l.scheduled_visit_date,
    l.scheduled_visit_time,
    l.visited,
    l.bought,
    l.purchase_amount,
    l.service_order,
    l.notes,
    l.inspected,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'category_id', c.id,
          'category_name', c.name,
          'value', v.value
        )
        order by c.sort_order, c.created_at
      )
      from public.lead_custom_values v
      join public.lead_custom_categories c
        on c.id = v.category_id
       and c.admin_user_id = v.admin_user_id
       and c.is_active = true
      where v.lead_id = l.id
        and v.admin_user_id = l.admin_user_id
    ), '[]'::jsonb),
    l.created_at,
    l.updated_at
  from public.leads l
  join public.stores st on st.id = l.store_id
  where l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
    )
  order by l.created_at desc;
end;
$$;

drop function if exists public.lc_list_leads(text);

create or replace function public.lc_list_leads(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  contact_date date,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  scheduled text,
  scheduled_visit_date date,
  scheduled_visit_time time,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  inspected boolean,
  custom_values jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_leads_b2b(p_session_token);
$$;

-- A API publica valida a carteira antes de encaminhar qualquer gravacao.
-- Isso impede que uma empresa use manualmente o RPC para gravar em outra loja.
create or replace function public.lc_upsert_lead(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_scheduled text default null,
  p_scheduled_visit_date date default null,
  p_scheduled_visit_time time default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_custom_values jsonb default '[]'::jsonb,
  p_store_id uuid default null,
  p_contact_date date default null
)
returns uuid
language plpgsql
security invoker
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_lead_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := p_store_id;

  if v_store_id is null and p_lead_id is not null then
    select l.store_id
    into v_store_id
    from public.leads l
    where l.id = p_lead_id
      and l.admin_user_id = v_session.admin_user_id;
  end if;

  if v_session.user_role::text = 'technician'
     and not app_private.technician_can_access_store(
       v_session.admin_user_id,
       v_session.user_id,
       v_store_id
     ) then
    raise exception 'Loja nao encontrada ou sem permissao.';
  end if;

  v_lead_id := app_private.rpc_upsert_lead(
    p_session_token,
    p_lead_id,
    p_name,
    p_phone,
    p_channel,
    p_campaign,
    p_conversation_start,
    p_conclusion,
    p_scheduled,
    p_scheduled_visit_date,
    p_scheduled_visit_time,
    p_visited,
    p_bought,
    p_purchase_amount,
    p_service_order,
    p_notes,
    p_custom_values,
    p_store_id
  );

  perform app_private.rpc_set_lead_contact_date(
    p_session_token,
    v_lead_id,
    p_contact_date
  );

  return v_lead_id;
end;
$$;

create or replace function app_private.rpc_set_lead_inspected(
  p_session_token text,
  p_lead_id uuid,
  p_inspected boolean
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  update public.leads l
  set
    inspected = coalesce(p_inspected, false),
    updated_by = v_session.user_id
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          l.store_id
        )
      )
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_set_lead_contact_date(
  p_session_token text,
  p_lead_id uuid,
  p_contact_date date default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  update public.leads l
  set
    contact_date = coalesce(p_contact_date, l.contact_date, (timezone('America/Sao_Paulo', now()))::date),
    updated_by = v_session.user_id
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          l.store_id
        )
      )
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_delete_lead(
  p_session_token text,
  p_lead_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  delete from public.leads l
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          l.store_id
        )
      )
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

-- Mantem os grants das funcoes substituidas e registra as novas assinaturas.
grant execute on function app_private.technician_can_access_store(uuid, uuid, uuid) to anon, authenticated;
grant execute on function app_private.rpc_create_technician(text, text, text, text, integer) to anon, authenticated;
grant execute on function public.lc_create_technician(text, text, text, text, integer) to anon, authenticated;
grant execute on function app_private.rpc_list_technicians(text) to anon, authenticated;
grant execute on function public.lc_list_technicians(text) to anon, authenticated;
grant execute on function app_private.rpc_update_technician_account(text, uuid, text, text, text, integer) to anon, authenticated;
grant execute on function public.lc_update_technician_account(text, uuid, text, text, text, integer) to anon, authenticated;
grant execute on function app_private.rpc_create_store(text, text, text, text, uuid) to anon, authenticated;
grant execute on function public.lc_create_store(text, text, text, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_list_stores(text) to anon, authenticated;
grant execute on function public.lc_list_stores(text) to anon, authenticated;
grant execute on function app_private.rpc_update_store_account(text, uuid, text, text, text, uuid) to anon, authenticated;
grant execute on function public.lc_update_store_account(text, uuid, text, text, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_account_usage(text) to anon, authenticated;
grant execute on function public.lc_account_usage(text) to anon, authenticated;
grant execute on function app_private.rpc_list_leads_b2b(text) to anon, authenticated;
grant execute on function public.lc_list_leads(text) to anon, authenticated;
grant execute on function app_private.rpc_set_lead_inspected(text, uuid, boolean) to anon, authenticated;
grant execute on function app_private.rpc_set_lead_contact_date(text, uuid, date) to anon, authenticated;
grant execute on function app_private.rpc_delete_lead(text, uuid) to anon, authenticated;
grant execute on function public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date) to anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- CONSOLIDACAO DO BANCO COMPLETO | ETAPA 3
-- Fonte integrada: client_scoped_configuration_update.sql
-- Configuracoes individuais por loja e imagens de perfil.
-- Rode depois de b2b_client_hierarchy_update.sql.

begin;

set search_path = public, extensions;

alter table public.app_users
  add column if not exists avatar_url text;

alter table public.stores
  add column if not exists avatar_url text;

alter table public.lead_options
  add column if not exists store_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'lead_options_store_fk'
      and conrelid = 'public.lead_options'::regclass
  ) then
    alter table public.lead_options
      add constraint lead_options_store_fk
      foreign key (store_id) references public.stores(id) on delete cascade;
  end if;
end;
$$;

alter table public.lead_options
  drop constraint if exists lead_options_unique_value;

create unique index if not exists lead_options_store_group_value_idx
  on public.lead_options (store_id, group_key, value)
  where store_id is not null;

create index if not exists lead_options_store_group_sort_idx
  on public.lead_options (store_id, group_key, sort_order)
  where store_id is not null and is_active = true;

-- Copia configuracoes antigas para lojas existentes. Lojas novas permanecem vazias.
insert into public.lead_options (
  admin_user_id,
  store_id,
  group_key,
  value,
  sort_order,
  fixed,
  is_active
)
select
  old_option.admin_user_id,
  st.id,
  old_option.group_key,
  old_option.value,
  old_option.sort_order,
  (old_option.group_key in ('scheduled', 'visited', 'bought')),
  old_option.is_active
from public.lead_options old_option
join public.stores st on st.admin_user_id = old_option.admin_user_id
where old_option.store_id is null
  and not exists (
    select 1
    from public.lead_options scoped
    where scoped.store_id = st.id
      and scoped.group_key = old_option.group_key
      and scoped.value = old_option.value
  );

-- Plataformas, campanhas e demais configuracoes sao totalmente editaveis
-- dentro de cada loja, inclusive valores que eram fixos no modelo antigo.
update public.lead_options
set fixed = false
where store_id is not null
  and group_key not in ('scheduled', 'visited', 'bought')
  and fixed = true;

-- O modelo novo nao possui opcoes globais do admin. Mantemos a assinatura
-- porque a criacao de admin existente chama esta rotina, mas novos cadastros
-- nao recebem campanhas, plataformas ou conclusoes predefinidas.
create or replace function app_private.seed_default_options(p_admin_user_id uuid)
returns void
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
begin
  return;
end;
$$;

alter table public.lead_custom_categories
  add column if not exists store_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'lead_custom_categories_store_fk'
      and conrelid = 'public.lead_custom_categories'::regclass
  ) then
    alter table public.lead_custom_categories
      add constraint lead_custom_categories_store_fk
      foreign key (store_id) references public.stores(id) on delete cascade;
  end if;
end;
$$;

drop index if exists public.lead_custom_categories_unique_name_idx;

create unique index if not exists lead_custom_categories_store_unique_name_idx
  on public.lead_custom_categories (store_id, lower(name))
  where store_id is not null and is_active = true;

create index if not exists lead_custom_categories_store_sort_idx
  on public.lead_custom_categories (store_id, sort_order, created_at)
  where store_id is not null and is_active = true;

-- Clona categorias/opcoes antigas por loja e preserva os valores dos leads.
do $$
declare
  v_scope record;
  v_new_category_id uuid;
begin
  for v_scope in
    select
      old_category.id as old_category_id,
      old_category.admin_user_id,
      old_category.name,
      old_category.sort_order,
      old_category.is_active,
      st.id as store_id
    from public.lead_custom_categories old_category
    join public.stores st on st.admin_user_id = old_category.admin_user_id
    where old_category.store_id is null
  loop
    select scoped.id
    into v_new_category_id
    from public.lead_custom_categories scoped
    where scoped.store_id = v_scope.store_id
      and lower(scoped.name) = lower(v_scope.name)
    limit 1;

    if v_new_category_id is null then
      insert into public.lead_custom_categories (
        admin_user_id,
        store_id,
        name,
        sort_order,
        is_active
      )
      values (
        v_scope.admin_user_id,
        v_scope.store_id,
        v_scope.name,
        v_scope.sort_order,
        v_scope.is_active
      )
      returning id into v_new_category_id;
    end if;

    insert into public.lead_custom_options (
      admin_user_id,
      category_id,
      value,
      sort_order,
      is_active
    )
    select
      old_option.admin_user_id,
      v_new_category_id,
      old_option.value,
      old_option.sort_order,
      old_option.is_active
    from public.lead_custom_options old_option
    where old_option.category_id = v_scope.old_category_id
      and not exists (
        select 1
        from public.lead_custom_options scoped_option
        where scoped_option.category_id = v_new_category_id
          and lower(scoped_option.value) = lower(old_option.value)
      );

    update public.lead_custom_values custom_value
    set category_id = v_new_category_id
    where custom_value.category_id = v_scope.old_category_id
      and exists (
        select 1
        from public.leads l
        where l.id = custom_value.lead_id
          and l.store_id = v_scope.store_id
      );
  end loop;
end;
$$;

create or replace function app_private.resolve_configuration_store(
  p_session_token text,
  p_store_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := case
    when v_session.user_role::text = 'store' then v_session.user_store_id
    else p_store_id
  end;

  if v_store_id is null then
    raise exception 'Selecione uma loja.';
  end if;

  if not exists (
    select 1
    from public.stores st
    where st.id = v_store_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true
      and (
        v_session.user_role::text = 'admin'
        or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
        or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
      )
  ) then
    raise exception 'Loja nao encontrada ou sem permissao.';
  end if;

  return v_store_id;
end;
$$;

create or replace function app_private.next_store_option_label(
  p_store_id uuid,
  p_group_key public.lead_option_group
)
returns text
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_base text := 'Nova opcao';
  v_label text := 'Nova opcao';
  v_counter integer := 2;
begin
  while exists (
    select 1 from public.lead_options
    where store_id = p_store_id
      and group_key = p_group_key
      and lower(value) = lower(v_label)
      and is_active = true
  ) loop
    v_label := v_base || ' ' || v_counter;
    v_counter := v_counter + 1;
  end loop;
  return v_label;
end;
$$;

drop function if exists public.lc_list_options(text);
drop function if exists app_private.rpc_list_options(text);

create or replace function app_private.rpc_list_options(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  id uuid,
  group_key public.lead_option_group,
  value text,
  sort_order integer,
  fixed boolean
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  return query
  select o.id, o.group_key, o.value, o.sort_order, o.fixed
  from public.lead_options o
  where o.store_id = v_store_id
    and o.is_active = true
  order by o.group_key, o.sort_order, o.created_at;
end;
$$;

create or replace function public.lc_list_options(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  id uuid,
  group_key public.lead_option_group,
  value text,
  sort_order integer,
  fixed boolean
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_options(p_session_token, p_store_id);
$$;

drop function if exists public.lc_add_option(text, public.lead_option_group, text);
drop function if exists app_private.rpc_add_option(text, public.lead_option_group, text);

create or replace function app_private.rpc_add_option(
  p_session_token text,
  p_group_key public.lead_option_group,
  p_value text default null,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_value text;
  v_sort_order integer;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);

  if p_group_key in ('scheduled', 'visited', 'bought') then
    raise exception 'Este grupo de opcoes e fixo.';
  end if;

  v_value := coalesce(
    nullif(btrim(coalesce(p_value, '')), ''),
    app_private.next_store_option_label(v_store_id, p_group_key)
  );
  v_sort_order := coalesce((
    select max(o.sort_order) + 10
    from public.lead_options o
    where o.store_id = v_store_id
      and o.group_key = p_group_key
      and o.is_active = true
  ), 10);

  update public.lead_options o
  set is_active = true, sort_order = v_sort_order
  where o.store_id = v_store_id
    and o.group_key = p_group_key
    and lower(o.value) = lower(v_value)
    and o.is_active = false;

  if not found then
    insert into public.lead_options (
      admin_user_id, store_id, group_key, value, sort_order, fixed
    ) values (
      v_session.admin_user_id, v_store_id, p_group_key, v_value, v_sort_order, false
    );
  end if;

  return true;
end;
$$;

create or replace function public.lc_add_option(
  p_session_token text,
  p_group_key public.lead_option_group,
  p_value text default null,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_add_option(p_session_token, p_group_key, p_value, p_store_id);
$$;

drop function if exists public.lc_update_option(text, uuid, text);
drop function if exists app_private.rpc_update_option(text, uuid, text);

create or replace function app_private.rpc_update_option(
  p_session_token text,
  p_option_id uuid,
  p_value text,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
  v_value text;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  v_value := btrim(coalesce(p_value, ''));
  if v_value = '' then raise exception 'Digite um valor.'; end if;

  update public.lead_options o
  set value = v_value
  where o.id = p_option_id
    and o.store_id = v_store_id
    and o.fixed = false
    and o.is_active = true;

  if not found then raise exception 'Opcao nao encontrada.'; end if;
  return true;
end;
$$;

create or replace function public.lc_update_option(
  p_session_token text,
  p_option_id uuid,
  p_value text,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_update_option(p_session_token, p_option_id, p_value, p_store_id);
$$;

drop function if exists public.lc_delete_option(text, uuid);
drop function if exists app_private.rpc_delete_option(text, uuid);

create or replace function app_private.rpc_delete_option(
  p_session_token text,
  p_option_id uuid,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  update public.lead_options o
  set is_active = false
  where o.id = p_option_id
    and o.store_id = v_store_id
    and o.fixed = false
    and o.is_active = true;
  if not found then raise exception 'Opcao nao encontrada.'; end if;
  return true;
end;
$$;

create or replace function public.lc_delete_option(
  p_session_token text,
  p_option_id uuid,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_option(p_session_token, p_option_id, p_store_id);
$$;

create or replace function app_private.next_store_custom_category_name(p_store_id uuid)
returns text
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_base text := 'Categoria adicional';
  v_name text := 'Categoria adicional';
  v_counter integer := 2;
begin
  while exists (
    select 1 from public.lead_custom_categories c
    where c.store_id = p_store_id
      and lower(c.name) = lower(v_name)
      and c.is_active = true
  ) loop
    v_name := v_base || ' ' || v_counter;
    v_counter := v_counter + 1;
  end loop;
  return v_name;
end;
$$;

drop function if exists public.lc_list_custom_categories(text);
drop function if exists app_private.rpc_list_custom_categories(text);

create or replace function app_private.rpc_list_custom_categories(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  id uuid,
  name text,
  sort_order integer,
  options jsonb
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  return query
  select
    c.id,
    c.name,
    c.sort_order,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', o.id,
          'category_id', o.category_id,
          'value', o.value,
          'sort_order', o.sort_order
        ) order by o.sort_order, o.created_at
      ) filter (where o.id is not null),
      '[]'::jsonb
    )
  from public.lead_custom_categories c
  left join public.lead_custom_options o
    on o.category_id = c.id and o.is_active = true
  where c.store_id = v_store_id
    and c.is_active = true
  group by c.id
  order by c.sort_order, c.created_at;
end;
$$;

create or replace function public.lc_list_custom_categories(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  id uuid,
  name text,
  sort_order integer,
  options jsonb
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_custom_categories(p_session_token, p_store_id);
$$;

drop function if exists public.lc_add_custom_category(text, text);
drop function if exists app_private.rpc_add_custom_category(text, text);

create or replace function app_private.rpc_add_custom_category(
  p_session_token text,
  p_name text default null,
  p_store_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_name text;
  v_category_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  v_name := coalesce(
    nullif(btrim(coalesce(p_name, '')), ''),
    app_private.next_store_custom_category_name(v_store_id)
  );

  insert into public.lead_custom_categories (
    admin_user_id, store_id, name, sort_order
  ) values (
    v_session.admin_user_id,
    v_store_id,
    v_name,
    coalesce((select max(c.sort_order) + 10 from public.lead_custom_categories c where c.store_id = v_store_id), 10)
  ) returning id into v_category_id;
  return v_category_id;
end;
$$;

create or replace function public.lc_add_custom_category(
  p_session_token text,
  p_name text default null,
  p_store_id uuid default null
)
returns uuid
language sql
security invoker
as $$
  select app_private.rpc_add_custom_category(p_session_token, p_name, p_store_id);
$$;

drop function if exists public.lc_update_custom_category(text, uuid, text);
drop function if exists app_private.rpc_update_custom_category(text, uuid, text);

create or replace function app_private.rpc_update_custom_category(
  p_session_token text,
  p_category_id uuid,
  p_name text,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  update public.lead_custom_categories c
  set name = btrim(p_name)
  where c.id = p_category_id
    and c.store_id = v_store_id
    and c.is_active = true
    and length(btrim(coalesce(p_name, ''))) > 0;
  if not found then raise exception 'Categoria nao encontrada ou vazia.'; end if;
  return true;
end;
$$;

create or replace function public.lc_update_custom_category(
  p_session_token text,
  p_category_id uuid,
  p_name text,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_update_custom_category(p_session_token, p_category_id, p_name, p_store_id);
$$;

drop function if exists public.lc_delete_custom_category(text, uuid);
drop function if exists app_private.rpc_delete_custom_category(text, uuid);

create or replace function app_private.rpc_delete_custom_category(
  p_session_token text,
  p_category_id uuid,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  update public.lead_custom_categories c
  set is_active = false
  where c.id = p_category_id and c.store_id = v_store_id and c.is_active = true;
  if not found then raise exception 'Categoria nao encontrada.'; end if;
  update public.lead_custom_options set is_active = false where category_id = p_category_id and is_active = true;
  return true;
end;
$$;

create or replace function public.lc_delete_custom_category(
  p_session_token text,
  p_category_id uuid,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_custom_category(p_session_token, p_category_id, p_store_id);
$$;

drop function if exists public.lc_add_custom_option(text, uuid, text);
drop function if exists app_private.rpc_add_custom_option(text, uuid, text);

create or replace function app_private.rpc_add_custom_option(
  p_session_token text,
  p_category_id uuid,
  p_value text default null,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_value text;
  v_counter integer := 2;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  if not exists (
    select 1 from public.lead_custom_categories c
    where c.id = p_category_id and c.store_id = v_store_id and c.is_active = true
  ) then raise exception 'Categoria nao encontrada.'; end if;

  v_value := nullif(btrim(coalesce(p_value, '')), '');
  if v_value is null then
    v_value := 'Nova opcao';
    while exists (
      select 1 from public.lead_custom_options o
      where o.category_id = p_category_id and lower(o.value) = lower(v_value) and o.is_active = true
    ) loop
      v_value := 'Nova opcao ' || v_counter;
      v_counter := v_counter + 1;
    end loop;
  end if;

  insert into public.lead_custom_options (
    admin_user_id, category_id, value, sort_order
  ) values (
    v_session.admin_user_id,
    p_category_id,
    v_value,
    coalesce((select max(o.sort_order) + 10 from public.lead_custom_options o where o.category_id = p_category_id), 10)
  );
  return true;
end;
$$;

create or replace function public.lc_add_custom_option(
  p_session_token text,
  p_category_id uuid,
  p_value text default null,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_add_custom_option(p_session_token, p_category_id, p_value, p_store_id);
$$;

drop function if exists public.lc_update_custom_option(text, uuid, text);
drop function if exists app_private.rpc_update_custom_option(text, uuid, text);

create or replace function app_private.rpc_update_custom_option(
  p_session_token text,
  p_option_id uuid,
  p_value text,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  update public.lead_custom_options o
  set value = btrim(p_value)
  from public.lead_custom_categories c
  where o.id = p_option_id
    and c.id = o.category_id
    and c.store_id = v_store_id
    and o.is_active = true
    and length(btrim(coalesce(p_value, ''))) > 0;
  if not found then raise exception 'Opcao nao encontrada ou vazia.'; end if;
  return true;
end;
$$;

create or replace function public.lc_update_custom_option(
  p_session_token text,
  p_option_id uuid,
  p_value text,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_update_custom_option(p_session_token, p_option_id, p_value, p_store_id);
$$;

drop function if exists public.lc_delete_custom_option(text, uuid);
drop function if exists app_private.rpc_delete_custom_option(text, uuid);

create or replace function app_private.rpc_delete_custom_option(
  p_session_token text,
  p_option_id uuid,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  update public.lead_custom_options o
  set is_active = false
  from public.lead_custom_categories c
  where o.id = p_option_id
    and c.id = o.category_id
    and c.store_id = v_store_id
    and o.is_active = true;
  if not found then raise exception 'Opcao nao encontrada.'; end if;
  return true;
end;
$$;

create or replace function public.lc_delete_custom_option(
  p_session_token text,
  p_option_id uuid,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_custom_option(p_session_token, p_option_id, p_store_id);
$$;

create or replace function app_private.enforce_custom_value_store()
returns trigger
language plpgsql
set search_path = app_private, public, extensions
as $$
declare
  v_lead_store_id uuid;
  v_category_store_id uuid;
begin
  select l.store_id into v_lead_store_id from public.leads l where l.id = new.lead_id;
  select c.store_id into v_category_store_id from public.lead_custom_categories c where c.id = new.category_id;
  if v_lead_store_id is null or v_category_store_id is null or v_lead_store_id <> v_category_store_id then
    raise exception 'Categoria nao pertence a loja deste lead.';
  end if;
  return new;
end;
$$;

drop trigger if exists lead_custom_values_store_guard on public.lead_custom_values;
create trigger lead_custom_values_store_guard
before insert or update of category_id, lead_id on public.lead_custom_values
for each row execute function app_private.enforce_custom_value_store();

-- Atualiza a leitura dos leads para exibir apenas categorias da propria loja.
create or replace function app_private.rpc_list_leads_b2b(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  contact_date date,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  scheduled text,
  scheduled_visit_date date,
  scheduled_visit_time time,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  inspected boolean,
  custom_values jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  return query
  select
    l.id, l.store_id, st.name, l.name, l.phone, l.contact_date,
    l.channel, l.campaign, l.conversation_start, l.conclusion,
    l.scheduled, l.scheduled_visit_date, l.scheduled_visit_time,
    l.visited, l.bought, l.purchase_amount, l.service_order, l.notes, l.inspected,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'category_id', c.id,
          'category_name', c.name,
          'value', v.value
        ) order by c.sort_order, c.created_at
      )
      from public.lead_custom_values v
      join public.lead_custom_categories c
        on c.id = v.category_id
       and c.store_id = l.store_id
       and c.is_active = true
      where v.lead_id = l.id
        and v.admin_user_id = l.admin_user_id
    ), '[]'::jsonb),
    l.created_at,
    l.updated_at
  from public.leads l
  join public.stores st on st.id = l.store_id
  where l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
    )
  order by l.created_at desc;
end;
$$;

create or replace function app_private.rpc_list_profile_avatars(p_session_token text)
returns table (
  account_type text,
  account_id uuid,
  avatar_url text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  return query
  select 'technician'::text, u.id, u.avatar_url
  from public.app_users u
  where u.role::text = 'technician'
    and u.is_active = true
    and u.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and u.id = v_session.user_id)
    )
  union all
  select 'store'::text, st.id, st.avatar_url
  from public.stores st
  where st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
    );
end;
$$;

create or replace function public.lc_list_profile_avatars(p_session_token text)
returns table (
  account_type text,
  account_id uuid,
  avatar_url text
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_profile_avatars(p_session_token);
$$;

create or replace function app_private.rpc_set_profile_avatar(
  p_session_token text,
  p_account_type text,
  p_account_id uuid,
  p_avatar_url text
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_avatar_url text;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_avatar_url := nullif(coalesce(p_avatar_url, ''), '');

  if v_avatar_url is not null and (
    length(v_avatar_url) > 750000
    or v_avatar_url !~ '^data:image/(png|jpeg|webp);base64,'
  ) then
    raise exception 'Imagem de perfil invalida ou muito grande.';
  end if;

  if p_account_type = 'technician' then
    update public.app_users u
    set avatar_url = v_avatar_url
    where u.id = p_account_id
      and u.role::text = 'technician'
      and u.admin_user_id = v_session.admin_user_id
      and (
        v_session.user_role::text = 'admin'
        or (v_session.user_role::text = 'technician' and u.id = v_session.user_id)
      );
  elsif p_account_type = 'store' then
    update public.stores st
    set avatar_url = v_avatar_url
    where st.id = p_account_id
      and st.admin_user_id = v_session.admin_user_id
      and (
        v_session.user_role::text = 'admin'
        or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
        or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
      );
  else
    raise exception 'Tipo de perfil invalido.';
  end if;

  if not found then raise exception 'Perfil nao encontrado ou sem permissao.'; end if;
  return true;
end;
$$;

create or replace function public.lc_set_profile_avatar(
  p_session_token text,
  p_account_type text,
  p_account_id uuid,
  p_avatar_url text
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_set_profile_avatar(p_session_token, p_account_type, p_account_id, p_avatar_url);
$$;

grant execute on function app_private.resolve_configuration_store(text, uuid) to anon, authenticated;
grant execute on function app_private.next_store_option_label(uuid, public.lead_option_group) to anon, authenticated;
grant execute on function app_private.rpc_list_options(text, uuid) to anon, authenticated;
grant execute on function public.lc_list_options(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_add_option(text, public.lead_option_group, text, uuid) to anon, authenticated;
grant execute on function public.lc_add_option(text, public.lead_option_group, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_update_option(text, uuid, text, uuid) to anon, authenticated;
grant execute on function public.lc_update_option(text, uuid, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_delete_option(text, uuid, uuid) to anon, authenticated;
grant execute on function public.lc_delete_option(text, uuid, uuid) to anon, authenticated;
grant execute on function app_private.next_store_custom_category_name(uuid) to anon, authenticated;
grant execute on function app_private.rpc_list_custom_categories(text, uuid) to anon, authenticated;
grant execute on function public.lc_list_custom_categories(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_add_custom_category(text, text, uuid) to anon, authenticated;
grant execute on function public.lc_add_custom_category(text, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_update_custom_category(text, uuid, text, uuid) to anon, authenticated;
grant execute on function public.lc_update_custom_category(text, uuid, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_delete_custom_category(text, uuid, uuid) to anon, authenticated;
grant execute on function public.lc_delete_custom_category(text, uuid, uuid) to anon, authenticated;
grant execute on function app_private.rpc_add_custom_option(text, uuid, text, uuid) to anon, authenticated;
grant execute on function public.lc_add_custom_option(text, uuid, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_update_custom_option(text, uuid, text, uuid) to anon, authenticated;
grant execute on function public.lc_update_custom_option(text, uuid, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_delete_custom_option(text, uuid, uuid) to anon, authenticated;
grant execute on function public.lc_delete_custom_option(text, uuid, uuid) to anon, authenticated;
grant execute on function app_private.rpc_list_leads_b2b(text) to anon, authenticated;
grant execute on function app_private.rpc_list_profile_avatars(text) to anon, authenticated;
grant execute on function public.lc_list_profile_avatars(text) to anon, authenticated;
grant execute on function app_private.rpc_set_profile_avatar(text, text, uuid, text) to anon, authenticated;
grant execute on function public.lc_set_profile_avatar(text, text, uuid, text) to anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- CONSOLIDACAO DO BANCO COMPLETO | ETAPA 4
-- Fonte integrada: agency_store_configuration_editor_update.sql
-- Editor completo de categorias e cards por loja.
-- Execute depois de client_scoped_configuration_update.sql.

begin;

create table if not exists public.store_configuration_labels (
  store_id uuid not null references public.stores(id) on delete cascade,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  group_key public.lead_option_group not null,
  label text not null check (length(btrim(label)) between 1 and 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (store_id, group_key)
);

create index if not exists store_configuration_labels_admin_idx
  on public.store_configuration_labels (admin_user_id, store_id);

alter table public.store_configuration_labels enable row level security;

revoke all on table public.store_configuration_labels from anon, authenticated;
grant select, insert, update, delete on table public.store_configuration_labels to service_role;

create or replace function app_private.rpc_list_configuration_labels(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  group_key public.lead_option_group,
  label text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);

  return query
  select configuration.group_key, configuration.label
  from public.store_configuration_labels configuration
  where configuration.store_id = v_store_id
  order by configuration.group_key::text;
end;
$$;

create or replace function public.lc_list_configuration_labels(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  group_key public.lead_option_group,
  label text
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_configuration_labels(p_session_token, p_store_id);
$$;

create or replace function app_private.rpc_update_configuration_label(
  p_session_token text,
  p_group_key public.lead_option_group,
  p_label text,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_label text;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  v_label := btrim(coalesce(p_label, ''));

  if length(v_label) < 1 or length(v_label) > 80 then
    raise exception 'O nome da categoria deve ter entre 1 e 80 caracteres.';
  end if;

  if exists (
    select 1
    from public.store_configuration_labels configuration
    where configuration.store_id = v_store_id
      and configuration.group_key <> p_group_key
      and lower(configuration.label) = lower(v_label)
  ) then
    raise exception 'Ja existe uma categoria com esse nome.';
  end if;

  insert into public.store_configuration_labels (
    store_id,
    admin_user_id,
    group_key,
    label
  ) values (
    v_store_id,
    v_session.admin_user_id,
    p_group_key,
    v_label
  )
  on conflict (store_id, group_key)
  do update set
    label = excluded.label,
    updated_at = now();

  return true;
end;
$$;

create or replace function public.lc_update_configuration_label(
  p_session_token text,
  p_group_key public.lead_option_group,
  p_label text,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_update_configuration_label(
    p_session_token,
    p_group_key,
    p_label,
    p_store_id
  );
$$;

create or replace function app_private.rpc_reorder_options(
  p_session_token text,
  p_group_key public.lead_option_group,
  p_option_ids uuid[],
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
  v_expected_count integer;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);

  select count(*)::integer
  into v_expected_count
  from public.lead_options option_row
  where option_row.store_id = v_store_id
    and option_row.group_key = p_group_key
    and option_row.is_active = true
    and option_row.fixed = false;

  if coalesce(cardinality(p_option_ids), 0) <> v_expected_count
    or coalesce((select count(distinct requested.option_id) from unnest(p_option_ids) as requested(option_id)), 0) <> v_expected_count
    or exists (
      select 1
      from unnest(p_option_ids) as requested(option_id)
      where not exists (
        select 1
        from public.lead_options option_row
        where option_row.id = requested.option_id
          and option_row.store_id = v_store_id
          and option_row.group_key = p_group_key
          and option_row.is_active = true
          and option_row.fixed = false
      )
    )
  then
    raise exception 'A lista de cards nao corresponde a configuracao atual.';
  end if;

  update public.lead_options option_row
  set sort_order = (ordered.position * 10)::integer
  from unnest(p_option_ids) with ordinality as ordered(option_id, position)
  where option_row.id = ordered.option_id
    and option_row.store_id = v_store_id
    and option_row.group_key = p_group_key;

  return true;
end;
$$;

create or replace function public.lc_reorder_options(
  p_session_token text,
  p_group_key public.lead_option_group,
  p_option_ids uuid[],
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_reorder_options(
    p_session_token,
    p_group_key,
    p_option_ids,
    p_store_id
  );
$$;

create or replace function app_private.rpc_reorder_custom_categories(
  p_session_token text,
  p_category_ids uuid[],
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
  v_expected_count integer;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);

  select count(*)::integer
  into v_expected_count
  from public.lead_custom_categories category
  where category.store_id = v_store_id
    and category.is_active = true;

  if coalesce(cardinality(p_category_ids), 0) <> v_expected_count
    or coalesce((select count(distinct requested.category_id) from unnest(p_category_ids) as requested(category_id)), 0) <> v_expected_count
    or exists (
      select 1
      from unnest(p_category_ids) as requested(category_id)
      where not exists (
        select 1
        from public.lead_custom_categories category
        where category.id = requested.category_id
          and category.store_id = v_store_id
          and category.is_active = true
      )
    )
  then
    raise exception 'A lista de categorias nao corresponde a configuracao atual.';
  end if;

  update public.lead_custom_categories category
  set sort_order = (ordered.position * 10)::integer
  from unnest(p_category_ids) with ordinality as ordered(category_id, position)
  where category.id = ordered.category_id
    and category.store_id = v_store_id;

  return true;
end;
$$;

create or replace function public.lc_reorder_custom_categories(
  p_session_token text,
  p_category_ids uuid[],
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_reorder_custom_categories(
    p_session_token,
    p_category_ids,
    p_store_id
  );
$$;

create or replace function app_private.rpc_reorder_custom_options(
  p_session_token text,
  p_category_id uuid,
  p_option_ids uuid[],
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
  v_expected_count integer;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);

  if not exists (
    select 1
    from public.lead_custom_categories category
    where category.id = p_category_id
      and category.store_id = v_store_id
      and category.is_active = true
  ) then
    raise exception 'Categoria nao encontrada.';
  end if;

  select count(*)::integer
  into v_expected_count
  from public.lead_custom_options option_row
  where option_row.category_id = p_category_id
    and option_row.is_active = true;

  if coalesce(cardinality(p_option_ids), 0) <> v_expected_count
    or coalesce((select count(distinct requested.option_id) from unnest(p_option_ids) as requested(option_id)), 0) <> v_expected_count
    or exists (
      select 1
      from unnest(p_option_ids) as requested(option_id)
      where not exists (
        select 1
        from public.lead_custom_options option_row
        where option_row.id = requested.option_id
          and option_row.category_id = p_category_id
          and option_row.is_active = true
      )
    )
  then
    raise exception 'A lista de cards nao corresponde a categoria atual.';
  end if;

  update public.lead_custom_options option_row
  set sort_order = (ordered.position * 10)::integer
  from unnest(p_option_ids) with ordinality as ordered(option_id, position)
  where option_row.id = ordered.option_id
    and option_row.category_id = p_category_id;

  return true;
end;
$$;

create or replace function public.lc_reorder_custom_options(
  p_session_token text,
  p_category_id uuid,
  p_option_ids uuid[],
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_reorder_custom_options(
    p_session_token,
    p_category_id,
    p_option_ids,
    p_store_id
  );
$$;

revoke all on function app_private.rpc_list_configuration_labels(text, uuid) from public;
revoke all on function app_private.rpc_update_configuration_label(text, public.lead_option_group, text, uuid) from public;
revoke all on function app_private.rpc_reorder_options(text, public.lead_option_group, uuid[], uuid) from public;
revoke all on function app_private.rpc_reorder_custom_categories(text, uuid[], uuid) from public;
revoke all on function app_private.rpc_reorder_custom_options(text, uuid, uuid[], uuid) from public;

grant execute on function app_private.rpc_list_configuration_labels(text, uuid) to anon, authenticated;
grant execute on function public.lc_list_configuration_labels(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_update_configuration_label(text, public.lead_option_group, text, uuid) to anon, authenticated;
grant execute on function public.lc_update_configuration_label(text, public.lead_option_group, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_reorder_options(text, public.lead_option_group, uuid[], uuid) to anon, authenticated;
grant execute on function public.lc_reorder_options(text, public.lead_option_group, uuid[], uuid) to anon, authenticated;
grant execute on function app_private.rpc_reorder_custom_categories(text, uuid[], uuid) to anon, authenticated;
grant execute on function public.lc_reorder_custom_categories(text, uuid[], uuid) to anon, authenticated;
grant execute on function app_private.rpc_reorder_custom_options(text, uuid, uuid[], uuid) to anon, authenticated;
grant execute on function public.lc_reorder_custom_options(text, uuid, uuid[], uuid) to anon, authenticated;

commit;

-- CONSOLIDACAO DO BANCO COMPLETO | ETAPA 5
-- Fonte integrada: central_ai_configuration_update.sql
-- Configuracao central de IA: o admin salva uma unica chave e as empresas B2B
-- carregam essa configuracao no login para chamar o provedor diretamente.
-- Rode depois de b2b_client_hierarchy_update.sql e client_scoped_configuration_update.sql.

begin;

set search_path = public, extensions;

create table if not exists public.ai_settings (
  admin_user_id uuid primary key references public.app_users(id) on delete cascade,
  provider text not null default 'deepseek',
  model text not null default 'deepseek-chat',
  api_key text not null default '',
  system_prompt text not null default '',
  updated_by_user_id uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ai_settings_provider_check check (provider in ('deepseek', 'gemini')),
  constraint ai_settings_model_check check (length(btrim(model)) between 1 and 160)
);

alter table public.ai_settings enable row level security;

drop trigger if exists ai_settings_set_updated_at on public.ai_settings;
create trigger ai_settings_set_updated_at
before update on public.ai_settings
for each row execute function app_private.set_updated_at();

drop function if exists public.lc_save_ai_settings(text, text, text, text, text);
drop function if exists app_private.rpc_save_ai_settings(text, text, text, text, text);
drop function if exists public.lc_get_ai_settings(text);
drop function if exists app_private.rpc_get_ai_settings(text);
drop function if exists public.lc_ai_runtime_config(text);

create or replace function app_private.rpc_get_ai_settings(p_session_token text)
returns table (
  provider text,
  model text,
  api_key text,
  system_prompt text,
  has_api_key boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'A IA esta disponivel somente para admin e empresas B2B.';
  end if;

  return query
  select
    coalesce(s.provider, 'deepseek'),
    coalesce(s.model, 'deepseek-chat'),
    coalesce(s.api_key, ''),
    coalesce(nullif(btrim(s.system_prompt), ''),
      'Voce e uma IA especialista em analise comercial de leads para oticas. Responda somente ao que o usuario perguntou. Cada conversa recebe dados de uma unica loja selecionada. Nunca combine ou compare dados de lojas diferentes. Use somente os leads fornecidos no contexto e priorize recomendacoes praticas.'),
    coalesce(length(btrim(s.api_key)) > 0, false),
    s.updated_at
  from (select 1) seed
  left join public.ai_settings s
    on s.admin_user_id = v_session.admin_user_id;
end;
$$;

create or replace function public.lc_get_ai_settings(p_session_token text)
returns table (
  provider text,
  model text,
  api_key text,
  system_prompt text,
  has_api_key boolean,
  updated_at timestamptz
)
language sql
security invoker
as $$
  select * from app_private.rpc_get_ai_settings(p_session_token);
$$;

create or replace function app_private.rpc_save_ai_settings(
  p_session_token text,
  p_provider text,
  p_model text,
  p_api_key text default null,
  p_system_prompt text default null
)
returns table (
  provider text,
  model text,
  api_key text,
  system_prompt text,
  has_api_key boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_provider text := lower(btrim(coalesce(p_provider, '')));
  v_model text := btrim(coalesce(p_model, ''));
  v_api_key text := nullif(btrim(coalesce(p_api_key, '')), '');
  v_prompt text := nullif(btrim(coalesce(p_system_prompt, '')), '');
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o admin pode alterar a configuracao central da IA.';
  end if;

  if v_provider not in ('deepseek', 'gemini') then
    raise exception 'Provedor de IA invalido.';
  end if;

  if length(v_model) = 0 or length(v_model) > 160 then
    raise exception 'Informe um modelo de IA valido.';
  end if;

  if v_api_key is null and not exists (
    select 1
    from public.ai_settings s
    where s.admin_user_id = v_session.admin_user_id
      and length(btrim(s.api_key)) > 0
  ) then
    raise exception 'Informe a chave da API antes de salvar.';
  end if;

  insert into public.ai_settings (
    admin_user_id,
    provider,
    model,
    api_key,
    system_prompt,
    updated_by_user_id
  )
  values (
    v_session.admin_user_id,
    v_provider,
    v_model,
    coalesce(v_api_key, ''),
    coalesce(v_prompt, ''),
    v_session.user_id
  )
  on conflict (admin_user_id) do update
  set
    provider = excluded.provider,
    model = excluded.model,
    api_key = coalesce(v_api_key, public.ai_settings.api_key),
    system_prompt = coalesce(v_prompt, public.ai_settings.system_prompt),
    updated_by_user_id = v_session.user_id;

  return query
  select * from app_private.rpc_get_ai_settings(p_session_token);
end;
$$;

create or replace function public.lc_save_ai_settings(
  p_session_token text,
  p_provider text,
  p_model text,
  p_api_key text default null,
  p_system_prompt text default null
)
returns table (
  provider text,
  model text,
  api_key text,
  system_prompt text,
  has_api_key boolean,
  updated_at timestamptz
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_save_ai_settings(
    p_session_token,
    p_provider,
    p_model,
    p_api_key,
    p_system_prompt
  );
$$;

revoke all on table public.ai_settings from public, anon, authenticated;
revoke execute on function app_private.rpc_get_ai_settings(text) from public;
revoke execute on function app_private.rpc_save_ai_settings(text, text, text, text, text) from public;

revoke execute on function public.lc_get_ai_settings(text) from public;
revoke execute on function public.lc_save_ai_settings(text, text, text, text, text) from public;

grant execute on function app_private.rpc_get_ai_settings(text) to anon, authenticated;
grant execute on function app_private.rpc_save_ai_settings(text, text, text, text, text) to anon, authenticated;
grant execute on function public.lc_get_ai_settings(text) to anon, authenticated;
grant execute on function public.lc_save_ai_settings(text, text, text, text, text) to anon, authenticated;

commit;

-- CONSOLIDACAO DO BANCO COMPLETO | ETAPA 6
-- Fonte integrada: marketing_intelligence_update.sql
-- Inteligencia comercial, atribuicao e integracoes de marketing.
-- Rode depois de agency_store_configuration_editor_update.sql e
-- central_ai_configuration_update.sql.

begin;

set search_path = public, extensions;

create table if not exists public.lead_intelligence (
  lead_id uuid primary key references public.leads(id) on delete cascade,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  lifecycle_status text not null default 'new',
  qualified boolean not null default false,
  loss_reason text,
  owner_name text,
  email text,
  first_response_at timestamptz,
  qualified_at timestamptz,
  lost_at timestamptz,
  purchased_at timestamptz,
  utm_source text,
  utm_medium text,
  utm_campaign text,
  utm_content text,
  utm_term text,
  campaign_external_id text,
  adset_external_id text,
  ad_external_id text,
  creative_external_id text,
  gclid text,
  gbraid text,
  wbraid text,
  fbclid text,
  fbc text,
  fbp text,
  landing_page_url text,
  external_lead_id text,
  marketing_consent boolean not null default false,
  consent_at timestamptz,
  returning_customer boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lead_intelligence_status_check
    check (lifecycle_status in ('new', 'contacted', 'qualified', 'scheduled', 'visited', 'won', 'lost')),
  constraint lead_intelligence_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

create index if not exists lead_intelligence_store_status_idx
  on public.lead_intelligence (store_id, lifecycle_status, updated_at desc);

create table if not exists public.lead_events (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  lead_id uuid not null references public.leads(id) on delete cascade,
  event_type text not null,
  event_at timestamptz not null default now(),
  actor_user_id uuid references public.app_users(id) on delete set null,
  source text not null default 'app',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint lead_events_type_check check (
    event_type in (
      'lead_created', 'contacted', 'qualified', 'scheduled', 'visited',
      'purchased', 'lost', 'reopened', 'attribution_updated'
    )
  ),
  constraint lead_events_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

create index if not exists lead_events_store_date_idx
  on public.lead_events (store_id, event_at desc);
create index if not exists lead_events_lead_date_idx
  on public.lead_events (lead_id, event_at desc);

create table if not exists public.ad_daily_metrics (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  metric_date date not null,
  platform text not null,
  account_external_id text not null default '',
  campaign_external_id text not null default '',
  campaign_name text not null default '',
  adset_external_id text not null default '',
  adset_name text not null default '',
  ad_external_id text not null default '',
  ad_name text not null default '',
  creative_external_id text not null default '',
  spend numeric(14,2) not null default 0 check (spend >= 0),
  impressions bigint not null default 0 check (impressions >= 0),
  reach bigint not null default 0 check (reach >= 0),
  clicks bigint not null default 0 check (clicks >= 0),
  platform_leads bigint not null default 0 check (platform_leads >= 0),
  platform_conversions bigint not null default 0 check (platform_conversions >= 0),
  currency text not null default 'BRL',
  source text not null default 'manual',
  raw_metrics jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ad_daily_metrics_platform_check check (platform in ('meta', 'google', 'other')),
  constraint ad_daily_metrics_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint ad_daily_metrics_unique_row unique (
    store_id, metric_date, platform, account_external_id,
    campaign_external_id, adset_external_id, ad_external_id
  )
);

create index if not exists ad_daily_metrics_store_date_idx
  on public.ad_daily_metrics (store_id, metric_date desc);

create table if not exists public.store_marketing_targets (
  store_id uuid primary key,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  monthly_budget numeric(14,2) check (monthly_budget is null or monthly_budget >= 0),
  lead_goal integer check (lead_goal is null or lead_goal >= 0),
  qualified_goal integer check (qualified_goal is null or qualified_goal >= 0),
  sales_goal integer check (sales_goal is null or sales_goal >= 0),
  revenue_goal numeric(14,2) check (revenue_goal is null or revenue_goal >= 0),
  target_cpl numeric(14,2) check (target_cpl is null or target_cpl >= 0),
  target_cac numeric(14,2) check (target_cac is null or target_cac >= 0),
  target_roas numeric(10,2) check (target_roas is null or target_roas >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint store_marketing_targets_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

create table if not exists public.marketing_connections (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  provider text not null,
  status text not null default 'disconnected',
  account_external_id text,
  account_name text,
  public_config jsonb not null default '{}'::jsonb,
  secret_config jsonb not null default '{}'::jsonb,
  last_sync_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint marketing_connections_provider_check check (provider in ('meta', 'google')),
  constraint marketing_connections_status_check check (status in ('disconnected', 'pending', 'active', 'error')),
  constraint marketing_connections_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint marketing_connections_store_provider_key unique (store_id, provider)
);

create table if not exists public.marketing_conversion_queue (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  lead_id uuid not null references public.leads(id) on delete cascade,
  provider text not null,
  event_name text not null,
  event_at timestamptz not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending',
  attempt_count integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  processed_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint marketing_conversion_queue_provider_check check (provider in ('meta', 'google')),
  constraint marketing_conversion_queue_status_check check (status in ('pending', 'processing', 'sent', 'failed')),
  constraint marketing_conversion_queue_unique_event unique (lead_id, provider, event_name, event_at),
  constraint marketing_conversion_queue_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

create index if not exists marketing_conversion_queue_status_idx
  on public.marketing_conversion_queue (status, next_attempt_at);

create table if not exists public.ai_usage (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  user_id uuid references public.app_users(id) on delete set null,
  store_id uuid references public.stores(id) on delete set null,
  provider text not null,
  model text not null,
  request_kind text not null default 'chat',
  input_tokens integer,
  output_tokens integer,
  latency_ms integer,
  status text not null default 'success',
  created_at timestamptz not null default now()
);

create index if not exists ai_usage_admin_date_idx
  on public.ai_usage (admin_user_id, created_at desc);

alter table public.lead_intelligence enable row level security;
alter table public.lead_events enable row level security;
alter table public.ad_daily_metrics enable row level security;
alter table public.store_marketing_targets enable row level security;
alter table public.marketing_connections enable row level security;
alter table public.marketing_conversion_queue enable row level security;
alter table public.ai_usage enable row level security;

drop trigger if exists lead_intelligence_set_updated_at on public.lead_intelligence;
create trigger lead_intelligence_set_updated_at
before update on public.lead_intelligence
for each row execute function app_private.set_updated_at();

drop trigger if exists ad_daily_metrics_set_updated_at on public.ad_daily_metrics;
create trigger ad_daily_metrics_set_updated_at
before update on public.ad_daily_metrics
for each row execute function app_private.set_updated_at();

drop trigger if exists store_marketing_targets_set_updated_at on public.store_marketing_targets;
create trigger store_marketing_targets_set_updated_at
before update on public.store_marketing_targets
for each row execute function app_private.set_updated_at();

drop trigger if exists marketing_connections_set_updated_at on public.marketing_connections;
create trigger marketing_connections_set_updated_at
before update on public.marketing_connections
for each row execute function app_private.set_updated_at();

drop trigger if exists marketing_conversion_queue_set_updated_at on public.marketing_conversion_queue;
create trigger marketing_conversion_queue_set_updated_at
before update on public.marketing_conversion_queue
for each row execute function app_private.set_updated_at();

insert into public.lead_intelligence (
  lead_id, admin_user_id, store_id, lifecycle_status, qualified, purchased_at
)
select
  l.id,
  l.admin_user_id,
  l.store_id,
  case
    when l.bought = 'Sim' then 'won'
    when l.visited = 'Sim' then 'visited'
    when l.scheduled = 'Sim' then 'scheduled'
    else 'new'
  end,
  false,
  case when l.bought = 'Sim' then coalesce(l.updated_at, l.created_at) else null end
from public.leads l
on conflict (lead_id) do nothing;

create or replace function app_private.capture_lead_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_event_at timestamptz := now();
begin
  insert into public.lead_intelligence (lead_id, admin_user_id, store_id, lifecycle_status)
  values (
    new.id,
    new.admin_user_id,
    new.store_id,
    case
      when new.bought = 'Sim' then 'won'
      when new.visited = 'Sim' then 'visited'
      when new.scheduled = 'Sim' then 'scheduled'
      else 'new'
    end
  )
  on conflict (lead_id) do update
  set store_id = excluded.store_id,
      admin_user_id = excluded.admin_user_id;

  if tg_op = 'INSERT' then
    insert into public.lead_events (
      admin_user_id, store_id, lead_id, event_type, event_at, actor_user_id, metadata
    ) values (
      new.admin_user_id, new.store_id, new.id, 'lead_created', coalesce(new.created_at, v_event_at),
      new.created_by, jsonb_build_object('channel', new.channel, 'campaign', new.campaign)
    );
  end if;

  if new.scheduled = 'Sim' and (tg_op = 'INSERT' or old.scheduled is distinct from 'Sim') then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, event_at, actor_user_id, metadata)
    values (
      new.admin_user_id, new.store_id, new.id, 'scheduled', v_event_at, new.updated_by,
      jsonb_build_object('visit_date', new.scheduled_visit_date, 'visit_time', new.scheduled_visit_time)
    );
    update public.lead_intelligence
    set lifecycle_status = case when lifecycle_status in ('won', 'lost') then lifecycle_status else 'scheduled' end
    where lead_id = new.id;
  end if;

  if new.visited = 'Sim' and (tg_op = 'INSERT' or old.visited is distinct from 'Sim') then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, event_at, actor_user_id)
    values (new.admin_user_id, new.store_id, new.id, 'visited', v_event_at, new.updated_by);
    update public.lead_intelligence
    set lifecycle_status = case when lifecycle_status in ('won', 'lost') then lifecycle_status else 'visited' end
    where lead_id = new.id;
  end if;

  if new.bought = 'Sim' and (tg_op = 'INSERT' or old.bought is distinct from 'Sim') then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, event_at, actor_user_id, metadata)
    values (
      new.admin_user_id, new.store_id, new.id, 'purchased', v_event_at, new.updated_by,
      jsonb_build_object('value', new.purchase_amount, 'order_id', new.service_order)
    );
    update public.lead_intelligence
    set lifecycle_status = 'won', purchased_at = coalesce(purchased_at, v_event_at)
    where lead_id = new.id;

    insert into public.marketing_conversion_queue (
      admin_user_id, store_id, lead_id, provider, event_name, event_at, payload
    )
    select
      new.admin_user_id,
      new.store_id,
      new.id,
      c.provider,
      'Purchase',
      v_event_at,
      jsonb_build_object(
        'value', new.purchase_amount,
        'currency', 'BRL',
        'order_id', new.service_order,
        'phone', new.phone,
        'email', li.email,
        'gclid', li.gclid,
        'gbraid', li.gbraid,
        'wbraid', li.wbraid,
        'fbc', li.fbc,
        'fbp', li.fbp,
        'marketing_consent', li.marketing_consent
      )
    from public.marketing_connections c
    join public.lead_intelligence li on li.lead_id = new.id
    where c.store_id = new.store_id
      and c.status = 'active'
    on conflict (lead_id, provider, event_name, event_at) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists leads_capture_lifecycle on public.leads;
create trigger leads_capture_lifecycle
after insert or update of store_id, scheduled, scheduled_visit_date, scheduled_visit_time, visited, bought, purchase_amount, service_order
on public.leads
for each row execute function app_private.capture_lead_lifecycle();

create or replace function app_private.rpc_list_lead_intelligence(p_session_token text)
returns table (
  lead_id uuid,
  lifecycle_status text,
  qualified boolean,
  loss_reason text,
  owner_name text,
  email text,
  first_response_at timestamptz,
  qualified_at timestamptz,
  lost_at timestamptz,
  purchased_at timestamptz,
  utm_source text,
  utm_medium text,
  utm_campaign text,
  utm_content text,
  utm_term text,
  campaign_external_id text,
  adset_external_id text,
  ad_external_id text,
  creative_external_id text,
  gclid text,
  gbraid text,
  wbraid text,
  fbclid text,
  fbc text,
  fbp text,
  landing_page_url text,
  external_lead_id text,
  marketing_consent boolean,
  consent_at timestamptz,
  returning_customer boolean
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select
    li.lead_id, li.lifecycle_status, li.qualified, li.loss_reason, li.owner_name, li.email,
    li.first_response_at, li.qualified_at, li.lost_at, li.purchased_at,
    li.utm_source, li.utm_medium, li.utm_campaign, li.utm_content, li.utm_term,
    li.campaign_external_id, li.adset_external_id, li.ad_external_id, li.creative_external_id,
    li.gclid, li.gbraid, li.wbraid, li.fbclid, li.fbc, li.fbp,
    li.landing_page_url, li.external_lead_id, li.marketing_consent, li.consent_at,
    li.returning_customer
  from public.lead_intelligence li
  join public.stores st on st.id = li.store_id
  where li.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and li.store_id = v_session.user_store_id)
    );
end;
$$;

create or replace function public.lc_list_lead_intelligence(p_session_token text)
returns table (
  lead_id uuid,
  lifecycle_status text,
  qualified boolean,
  loss_reason text,
  owner_name text,
  email text,
  first_response_at timestamptz,
  qualified_at timestamptz,
  lost_at timestamptz,
  purchased_at timestamptz,
  utm_source text,
  utm_medium text,
  utm_campaign text,
  utm_content text,
  utm_term text,
  campaign_external_id text,
  adset_external_id text,
  ad_external_id text,
  creative_external_id text,
  gclid text,
  gbraid text,
  wbraid text,
  fbclid text,
  fbc text,
  fbp text,
  landing_page_url text,
  external_lead_id text,
  marketing_consent boolean,
  consent_at timestamptz,
  returning_customer boolean
)
language sql
security invoker
as $$ select * from app_private.rpc_list_lead_intelligence(p_session_token); $$;

create or replace function app_private.rpc_save_lead_intelligence(
  p_session_token text,
  p_lead_id uuid,
  p_payload jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_lead record;
  v_before record;
  v_status text;
  v_qualified boolean;
  v_loss_reason text;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select l.* into v_lead
  from public.leads l
  join public.stores st on st.id = l.store_id
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
    );
  if not found then raise exception 'Lead nao encontrado ou sem permissao.'; end if;

  insert into public.lead_intelligence (lead_id, admin_user_id, store_id)
  values (v_lead.id, v_lead.admin_user_id, v_lead.store_id)
  on conflict (lead_id) do nothing;

  select * into v_before from public.lead_intelligence where lead_id = p_lead_id;
  v_status := coalesce(nullif(btrim(p_payload->>'lifecycle_status'), ''), v_before.lifecycle_status);
  if v_status not in ('new', 'contacted', 'qualified', 'scheduled', 'visited', 'won', 'lost') then
    raise exception 'Etapa comercial invalida.';
  end if;
  v_qualified := case
    when p_payload ? 'qualified' then lower(coalesce(p_payload->>'qualified', 'false')) in ('true', '1', 'sim')
    else v_before.qualified
  end;
  v_loss_reason := case
    when p_payload ? 'loss_reason' then nullif(btrim(p_payload->>'loss_reason'), '')
    else v_before.loss_reason
  end;
  if v_status = 'lost' and v_loss_reason is null then
    raise exception 'Informe o motivo da perda.';
  end if;

  update public.lead_intelligence
  set
    lifecycle_status = v_status,
    qualified = v_qualified,
    loss_reason = case when v_status = 'lost' then v_loss_reason else null end,
    owner_name = case when p_payload ? 'owner_name' then nullif(left(btrim(p_payload->>'owner_name'), 160), '') else owner_name end,
    email = case when p_payload ? 'email' then nullif(left(lower(btrim(p_payload->>'email')), 320), '') else email end,
    first_response_at = case when p_payload ? 'first_response_at' then nullif(p_payload->>'first_response_at', '')::timestamptz else first_response_at end,
    qualified_at = case when v_qualified then coalesce(qualified_at, now()) else null end,
    lost_at = case when v_status = 'lost' then coalesce(lost_at, now()) else null end,
    purchased_at = case when v_status = 'won' then coalesce(purchased_at, now()) else purchased_at end,
    utm_source = case when p_payload ? 'utm_source' then nullif(left(btrim(p_payload->>'utm_source'), 500), '') else utm_source end,
    utm_medium = case when p_payload ? 'utm_medium' then nullif(left(btrim(p_payload->>'utm_medium'), 500), '') else utm_medium end,
    utm_campaign = case when p_payload ? 'utm_campaign' then nullif(left(btrim(p_payload->>'utm_campaign'), 500), '') else utm_campaign end,
    utm_content = case when p_payload ? 'utm_content' then nullif(left(btrim(p_payload->>'utm_content'), 500), '') else utm_content end,
    utm_term = case when p_payload ? 'utm_term' then nullif(left(btrim(p_payload->>'utm_term'), 500), '') else utm_term end,
    campaign_external_id = case when p_payload ? 'campaign_external_id' then nullif(left(btrim(p_payload->>'campaign_external_id'), 500), '') else campaign_external_id end,
    adset_external_id = case when p_payload ? 'adset_external_id' then nullif(left(btrim(p_payload->>'adset_external_id'), 500), '') else adset_external_id end,
    ad_external_id = case when p_payload ? 'ad_external_id' then nullif(left(btrim(p_payload->>'ad_external_id'), 500), '') else ad_external_id end,
    creative_external_id = case when p_payload ? 'creative_external_id' then nullif(left(btrim(p_payload->>'creative_external_id'), 500), '') else creative_external_id end,
    gclid = case when p_payload ? 'gclid' then nullif(left(btrim(p_payload->>'gclid'), 500), '') else gclid end,
    gbraid = case when p_payload ? 'gbraid' then nullif(left(btrim(p_payload->>'gbraid'), 500), '') else gbraid end,
    wbraid = case when p_payload ? 'wbraid' then nullif(left(btrim(p_payload->>'wbraid'), 500), '') else wbraid end,
    fbclid = case when p_payload ? 'fbclid' then nullif(left(btrim(p_payload->>'fbclid'), 500), '') else fbclid end,
    fbc = case when p_payload ? 'fbc' then nullif(left(btrim(p_payload->>'fbc'), 500), '') else fbc end,
    fbp = case when p_payload ? 'fbp' then nullif(left(btrim(p_payload->>'fbp'), 500), '') else fbp end,
    landing_page_url = case when p_payload ? 'landing_page_url' then nullif(left(btrim(p_payload->>'landing_page_url'), 2000), '') else landing_page_url end,
    external_lead_id = case when p_payload ? 'external_lead_id' then nullif(left(btrim(p_payload->>'external_lead_id'), 500), '') else external_lead_id end,
    marketing_consent = case when p_payload ? 'marketing_consent' then lower(coalesce(p_payload->>'marketing_consent', 'false')) in ('true', '1', 'sim') else marketing_consent end,
    consent_at = case
      when p_payload ? 'marketing_consent' and lower(coalesce(p_payload->>'marketing_consent', 'false')) in ('true', '1', 'sim') then coalesce(consent_at, now())
      when p_payload ? 'marketing_consent' then null
      else consent_at
    end,
    returning_customer = case when p_payload ? 'returning_customer' then lower(coalesce(p_payload->>'returning_customer', 'false')) in ('true', '1', 'sim') else returning_customer end
  where lead_id = p_lead_id;

  if v_qualified and not v_before.qualified then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, actor_user_id)
    values (v_lead.admin_user_id, v_lead.store_id, v_lead.id, 'qualified', v_session.user_id);
  end if;
  if v_status = 'lost' and v_before.lifecycle_status is distinct from 'lost' then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, actor_user_id, metadata)
    values (v_lead.admin_user_id, v_lead.store_id, v_lead.id, 'lost', v_session.user_id, jsonb_build_object('reason', v_loss_reason));
  elsif v_before.lifecycle_status = 'lost' and v_status <> 'lost' then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, actor_user_id)
    values (v_lead.admin_user_id, v_lead.store_id, v_lead.id, 'reopened', v_session.user_id);
  end if;

  if (p_payload ? 'utm_source') or (p_payload ? 'gclid') or (p_payload ? 'fbclid') or (p_payload ? 'ad_external_id') then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, actor_user_id)
    values (v_lead.admin_user_id, v_lead.store_id, v_lead.id, 'attribution_updated', v_session.user_id);
  end if;
  return true;
end;
$$;

create or replace function public.lc_save_lead_intelligence(
  p_session_token text,
  p_lead_id uuid,
  p_payload jsonb default '{}'::jsonb
)
returns boolean
language sql
security invoker
as $$ select app_private.rpc_save_lead_intelligence(p_session_token, p_lead_id, p_payload); $$;

create or replace function public.lc_upsert_lead_with_intelligence(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_scheduled text default null,
  p_scheduled_visit_date date default null,
  p_scheduled_visit_time time default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_custom_values jsonb default '[]'::jsonb,
  p_store_id uuid default null,
  p_contact_date date default null,
  p_intelligence jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security invoker
set search_path = app_private, public, extensions
as $$
declare v_lead_id uuid;
begin
  v_lead_id := public.lc_upsert_lead(
    p_session_token, p_lead_id, p_name, p_phone, p_channel, p_campaign,
    p_conversation_start, p_conclusion, p_scheduled, p_scheduled_visit_date,
    p_scheduled_visit_time, p_visited, p_bought, p_purchase_amount,
    p_service_order, p_notes, p_custom_values, p_store_id, p_contact_date
  );
  perform app_private.rpc_save_lead_intelligence(p_session_token, v_lead_id, p_intelligence);
  return v_lead_id;
end;
$$;

create or replace function app_private.rpc_list_ad_daily_metrics(
  p_session_token text,
  p_store_id uuid default null,
  p_start_date date default null,
  p_end_date date default null
)
returns setof public.ad_daily_metrics
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  return query
  select m.*
  from public.ad_daily_metrics m
  join public.stores st on st.id = m.store_id
  where m.admin_user_id = v_session.admin_user_id
    and (p_store_id is null or m.store_id = p_store_id)
    and (p_start_date is null or m.metric_date >= p_start_date)
    and (p_end_date is null or m.metric_date <= p_end_date)
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and m.store_id = v_session.user_store_id)
    )
  order by m.metric_date desc, m.platform, m.campaign_name;
end;
$$;

create or replace function public.lc_list_ad_daily_metrics(
  p_session_token text,
  p_store_id uuid default null,
  p_start_date date default null,
  p_end_date date default null
)
returns setof public.ad_daily_metrics
language sql
security invoker
as $$ select * from app_private.rpc_list_ad_daily_metrics(p_session_token, p_store_id, p_start_date, p_end_date); $$;

create or replace function app_private.rpc_upsert_ad_daily_metric(
  p_session_token text,
  p_payload jsonb
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid := nullif(p_payload->>'store_id', '')::uuid;
  v_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Somente admin ou empresa podem editar investimento.';
  end if;
  if not exists (
    select 1 from public.stores st
    where st.id = v_store_id and st.admin_user_id = v_session.admin_user_id and st.is_active
      and (v_session.user_role::text = 'admin' or st.technician_user_id = v_session.user_id)
  ) then raise exception 'Loja nao encontrada ou sem permissao.'; end if;

  insert into public.ad_daily_metrics (
    admin_user_id, store_id, metric_date, platform, account_external_id,
    campaign_external_id, campaign_name, adset_external_id, adset_name,
    ad_external_id, ad_name, creative_external_id, spend, impressions, reach,
    clicks, platform_leads, platform_conversions, currency, source
  ) values (
    v_session.admin_user_id, v_store_id, (p_payload->>'metric_date')::date,
    case when lower(p_payload->>'platform') in ('meta', 'google') then lower(p_payload->>'platform') else 'other' end,
    coalesce(p_payload->>'account_external_id', ''),
    coalesce(nullif(p_payload->>'campaign_external_id', ''), nullif(p_payload->>'campaign_name', ''), ''),
    coalesce(p_payload->>'campaign_name', ''),
    coalesce(p_payload->>'adset_external_id', ''), coalesce(p_payload->>'adset_name', ''),
    coalesce(p_payload->>'ad_external_id', ''), coalesce(p_payload->>'ad_name', ''), coalesce(p_payload->>'creative_external_id', ''),
    greatest(coalesce(nullif(p_payload->>'spend', '')::numeric, 0), 0),
    greatest(coalesce(nullif(p_payload->>'impressions', '')::bigint, 0), 0),
    greatest(coalesce(nullif(p_payload->>'reach', '')::bigint, 0), 0),
    greatest(coalesce(nullif(p_payload->>'clicks', '')::bigint, 0), 0),
    greatest(coalesce(nullif(p_payload->>'platform_leads', '')::bigint, 0), 0),
    greatest(coalesce(nullif(p_payload->>'platform_conversions', '')::bigint, 0), 0),
    upper(coalesce(nullif(p_payload->>'currency', ''), 'BRL')), 'manual'
  )
  on conflict (store_id, metric_date, platform, account_external_id, campaign_external_id, adset_external_id, ad_external_id)
  do update set
    campaign_name = excluded.campaign_name, adset_name = excluded.adset_name, ad_name = excluded.ad_name,
    creative_external_id = excluded.creative_external_id, spend = excluded.spend,
    impressions = excluded.impressions, reach = excluded.reach, clicks = excluded.clicks,
    platform_leads = excluded.platform_leads, platform_conversions = excluded.platform_conversions,
    currency = excluded.currency, source = 'manual'
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.lc_upsert_ad_daily_metric(p_session_token text, p_payload jsonb)
returns uuid language sql security invoker
as $$ select app_private.rpc_upsert_ad_daily_metric(p_session_token, p_payload); $$;

create or replace function app_private.rpc_list_marketing_targets(p_session_token text)
returns setof public.store_marketing_targets
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  return query
  select t.* from public.store_marketing_targets t
  join public.stores st on st.id = t.store_id
  where t.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and t.store_id = v_session.user_store_id)
    );
end;
$$;

create or replace function public.lc_list_marketing_targets(p_session_token text)
returns setof public.store_marketing_targets language sql security invoker
as $$ select * from app_private.rpc_list_marketing_targets(p_session_token); $$;

create or replace function app_private.rpc_save_marketing_targets(
  p_session_token text, p_store_id uuid, p_payload jsonb
)
returns boolean
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Somente admin ou empresa podem editar metas.';
  end if;
  if not exists (
    select 1 from public.stores st where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id and st.is_active
      and (v_session.user_role::text = 'admin' or st.technician_user_id = v_session.user_id)
  ) then raise exception 'Loja nao encontrada ou sem permissao.'; end if;

  insert into public.store_marketing_targets (
    store_id, admin_user_id, monthly_budget, lead_goal, qualified_goal,
    sales_goal, revenue_goal, target_cpl, target_cac, target_roas
  ) values (
    p_store_id, v_session.admin_user_id,
    nullif(p_payload->>'monthly_budget', '')::numeric,
    nullif(p_payload->>'lead_goal', '')::integer,
    nullif(p_payload->>'qualified_goal', '')::integer,
    nullif(p_payload->>'sales_goal', '')::integer,
    nullif(p_payload->>'revenue_goal', '')::numeric,
    nullif(p_payload->>'target_cpl', '')::numeric,
    nullif(p_payload->>'target_cac', '')::numeric,
    nullif(p_payload->>'target_roas', '')::numeric
  )
  on conflict (store_id) do update set
    monthly_budget = excluded.monthly_budget, lead_goal = excluded.lead_goal,
    qualified_goal = excluded.qualified_goal, sales_goal = excluded.sales_goal,
    revenue_goal = excluded.revenue_goal, target_cpl = excluded.target_cpl,
    target_cac = excluded.target_cac, target_roas = excluded.target_roas;
  return true;
end;
$$;

create or replace function public.lc_save_marketing_targets(
  p_session_token text, p_store_id uuid, p_payload jsonb
)
returns boolean language sql security invoker
as $$ select app_private.rpc_save_marketing_targets(p_session_token, p_store_id, p_payload); $$;

create or replace function app_private.rpc_list_marketing_connections(p_session_token text, p_store_id uuid)
returns table (
  provider text, status text, account_external_id text, account_name text,
  last_sync_at timestamptz, last_error text
)
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not exists (
    select 1 from public.stores st where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id
      and (
        v_session.user_role::text = 'admin'
        or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
        or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
      )
  ) then raise exception 'Loja nao encontrada ou sem permissao.'; end if;
  return query
  select c.provider, c.status, c.account_external_id, c.account_name, c.last_sync_at, c.last_error
  from public.marketing_connections c where c.store_id = p_store_id;
end;
$$;

create or replace function public.lc_list_marketing_connections(p_session_token text, p_store_id uuid)
returns table (
  provider text, status text, account_external_id text, account_name text,
  last_sync_at timestamptz, last_error text
)
language sql security invoker
as $$ select * from app_private.rpc_list_marketing_connections(p_session_token, p_store_id); $$;

-- A chave da IA deixa de ser devolvida ao navegador. A assinatura e mantida
-- para compatibilidade com o frontend existente.
create or replace function app_private.rpc_get_ai_settings(p_session_token text)
returns table (
  provider text, model text, api_key text, system_prompt text,
  has_api_key boolean, updated_at timestamptz
)
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'A IA esta disponivel somente para admin e empresas B2B.';
  end if;
  return query
  select
    coalesce(s.provider, 'deepseek'), coalesce(s.model, 'deepseek-chat'), ''::text,
    coalesce(nullif(btrim(s.system_prompt), ''),
      'Voce e uma IA especialista em analise comercial. Use somente os dados agregados da loja selecionada, sinalize amostras pequenas e priorize acoes mensuraveis.'),
    coalesce(length(btrim(s.api_key)) > 0, false), s.updated_at
  from (select 1) seed
  left join public.ai_settings s on s.admin_user_id = v_session.admin_user_id;
end;
$$;

create or replace function public.lc_ai_runtime_config(p_session_token text)
returns table (
  admin_user_id uuid, user_id uuid, user_role text, provider text,
  model text, api_key text, system_prompt text
)
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'A IA esta disponivel somente para admin e empresas B2B.';
  end if;
  if (select count(*) from public.ai_usage u where u.admin_user_id = v_session.admin_user_id and u.created_at > now() - interval '1 hour') >= 120 then
    raise exception 'Limite temporario de analises atingido. Tente novamente em alguns minutos.';
  end if;
  return query
  select v_session.admin_user_id, v_session.user_id, v_session.user_role::text,
    s.provider, s.model, s.api_key,
    coalesce(nullif(btrim(s.system_prompt), ''),
      'Voce e uma IA especialista em analise comercial. Use somente os dados agregados da loja selecionada, sinalize amostras pequenas e priorize acoes mensuraveis.')
  from public.ai_settings s
  where s.admin_user_id = v_session.admin_user_id and length(btrim(s.api_key)) > 0;
  if not found then raise exception 'A IA ainda nao foi configurada pelo administrador.'; end if;
end;
$$;

create or replace function public.lc_log_ai_usage(
  p_admin_user_id uuid, p_user_id uuid, p_store_id uuid, p_provider text,
  p_model text, p_request_kind text, p_input_tokens integer,
  p_output_tokens integer, p_latency_ms integer, p_status text
)
returns boolean
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
begin
  insert into public.ai_usage (
    admin_user_id, user_id, store_id, provider, model, request_kind,
    input_tokens, output_tokens, latency_ms, status
  ) values (
    p_admin_user_id, p_user_id, p_store_id, left(p_provider, 40), left(p_model, 160),
    left(coalesce(p_request_kind, 'chat'), 40), p_input_tokens, p_output_tokens,
    p_latency_ms, left(coalesce(p_status, 'success'), 40)
  );
  return true;
end;
$$;

create or replace function public.lc_marketing_connection_runtime(
  p_session_token text, p_store_id uuid, p_provider text
)
returns table (
  admin_user_id uuid, user_id uuid, provider text, account_external_id text,
  public_config jsonb, secret_config jsonb
)
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not exists (
    select 1 from public.stores st where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id
      and (
        v_session.user_role::text = 'admin'
        or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
        or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
      )
  ) then raise exception 'Loja nao encontrada ou sem permissao.'; end if;
  return query
  select v_session.admin_user_id, v_session.user_id, c.provider,
    c.account_external_id, c.public_config, c.secret_config
  from public.marketing_connections c
  where c.store_id = p_store_id and c.provider = lower(p_provider) and c.status = 'active';
end;
$$;

revoke all on table public.lead_intelligence from public, anon, authenticated;
revoke all on table public.lead_events from public, anon, authenticated;
revoke all on table public.ad_daily_metrics from public, anon, authenticated;
revoke all on table public.store_marketing_targets from public, anon, authenticated;
revoke all on table public.marketing_connections from public, anon, authenticated;
revoke all on table public.marketing_conversion_queue from public, anon, authenticated;
revoke all on table public.ai_usage from public, anon, authenticated;

revoke execute on function app_private.rpc_list_lead_intelligence(text) from public;
revoke execute on function app_private.rpc_save_lead_intelligence(text, uuid, jsonb) from public;
revoke execute on function app_private.rpc_list_ad_daily_metrics(text, uuid, date, date) from public;
revoke execute on function app_private.rpc_upsert_ad_daily_metric(text, jsonb) from public;
revoke execute on function app_private.rpc_list_marketing_targets(text) from public;
revoke execute on function app_private.rpc_save_marketing_targets(text, uuid, jsonb) from public;
revoke execute on function app_private.rpc_list_marketing_connections(text, uuid) from public;

revoke execute on function public.lc_list_lead_intelligence(text) from public;
revoke execute on function public.lc_save_lead_intelligence(text, uuid, jsonb) from public;
revoke execute on function public.lc_upsert_lead_with_intelligence(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date, jsonb) from public;
revoke execute on function public.lc_list_ad_daily_metrics(text, uuid, date, date) from public;
revoke execute on function public.lc_upsert_ad_daily_metric(text, jsonb) from public;
revoke execute on function public.lc_list_marketing_targets(text) from public;
revoke execute on function public.lc_save_marketing_targets(text, uuid, jsonb) from public;
revoke execute on function public.lc_list_marketing_connections(text, uuid) from public;

revoke execute on function public.lc_ai_runtime_config(text) from public, anon, authenticated;
revoke execute on function public.lc_log_ai_usage(uuid, uuid, uuid, text, text, text, integer, integer, integer, text) from public, anon, authenticated;
revoke execute on function public.lc_marketing_connection_runtime(text, uuid, text) from public, anon, authenticated;

grant execute on function public.lc_list_lead_intelligence(text) to anon, authenticated;
grant execute on function public.lc_save_lead_intelligence(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.lc_upsert_lead_with_intelligence(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date, jsonb) to anon, authenticated;
grant execute on function public.lc_list_ad_daily_metrics(text, uuid, date, date) to anon, authenticated;
grant execute on function public.lc_upsert_ad_daily_metric(text, jsonb) to anon, authenticated;
grant execute on function public.lc_list_marketing_targets(text) to anon, authenticated;
grant execute on function public.lc_save_marketing_targets(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.lc_list_marketing_connections(text, uuid) to anon, authenticated;

grant execute on function app_private.rpc_list_lead_intelligence(text) to anon, authenticated;
grant execute on function app_private.rpc_save_lead_intelligence(text, uuid, jsonb) to anon, authenticated;
grant execute on function app_private.rpc_list_ad_daily_metrics(text, uuid, date, date) to anon, authenticated;
grant execute on function app_private.rpc_upsert_ad_daily_metric(text, jsonb) to anon, authenticated;
grant execute on function app_private.rpc_list_marketing_targets(text) to anon, authenticated;
grant execute on function app_private.rpc_save_marketing_targets(text, uuid, jsonb) to anon, authenticated;
grant execute on function app_private.rpc_list_marketing_connections(text, uuid) to anon, authenticated;

grant execute on function public.lc_ai_runtime_config(text) to service_role;
grant execute on function public.lc_log_ai_usage(uuid, uuid, uuid, text, text, text, integer, integer, integer, text) to service_role;
grant execute on function public.lc_marketing_connection_runtime(text, uuid, text) to service_role;

commit;

notify pgrst, 'reload schema';

-- CONSOLIDACAO DO BANCO COMPLETO | ETAPA 7
-- Fonte integrada: admin_account_update.sql
-- Rode este arquivo no SQL Editor do Supabase para permitir
-- que o admin altere o proprio nick e senha exigindo a senha atual.

set search_path = public, extensions;

drop function if exists public.lc_update_admin_credentials(text, text, text, text);
drop function if exists app_private.rpc_update_admin_credentials(text, text, text, text);

create or replace function app_private.rpc_update_admin_credentials(
  p_session_token text,
  p_nick text,
  p_current_password text,
  p_new_password text default null
)
returns table (
  nick text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_user public.app_users;
  v_nick_key text;
  v_new_password text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role <> 'admin' then
    raise exception 'Apenas admin pode alterar essa conta.';
  end if;

  select *
  into v_user
  from public.app_users
  where id = v_session.user_id
    and role = 'admin'
    and is_active = true;

  if not found then
    raise exception 'Admin nao encontrado.';
  end if;

  if v_user.password_hash <> crypt(coalesce(p_current_password, ''), v_user.password_hash) then
    raise exception 'Senha atual incorreta.' using errcode = '28000';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um nick valido.';
  end if;

  if exists (
    select 1
    from public.app_users
    where nick_key = v_nick_key
      and id <> v_user.id
  ) then
    raise exception 'Esse nick ja existe.';
  end if;

  v_new_password := nullif(coalesce(p_new_password, ''), '');
  if v_new_password is not null and length(v_new_password) < 6 then
    raise exception 'A nova senha precisa ter pelo menos 6 caracteres.';
  end if;

  update public.app_users
  set
    nick = v_nick_key,
    password_hash = case
      when v_new_password is null then password_hash
      else crypt(v_new_password, gen_salt('bf'))
    end
  where id = v_user.id;

  return query
  select u.nick_key
  from public.app_users u
  where u.id = v_user.id;
end;
$$;

create or replace function public.lc_update_admin_credentials(
  p_session_token text,
  p_nick text,
  p_current_password text,
  p_new_password text default null
)
returns table (
  nick text
)
language sql
security invoker
as $$
  select * from app_private.rpc_update_admin_credentials(
    p_session_token,
    p_nick,
    p_current_password,
    p_new_password
  );
$$;

grant execute on function app_private.rpc_update_admin_credentials(text, text, text, text) to anon, authenticated;
grant execute on function public.lc_update_admin_credentials(text, text, text, text) to anon, authenticated;

-- CONSOLIDACAO DO BANCO COMPLETO | ETAPA 8

-- Wrapper publico mantido separado da implementacao B2B mais recente.
create or replace function public.lc_set_lead_inspected(
  p_session_token text,
  p_lead_id uuid,
  p_inspected boolean
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_set_lead_inspected(p_session_token, p_lead_id, p_inspected);
$$;

revoke all on function public.lc_set_lead_inspected(text, uuid, boolean) from public;
grant execute on function public.lc_set_lead_inspected(text, uuid, boolean) to anon, authenticated;

-- Consistencia final entre a franquia geral e o adicional de Prospeccoes.
update public.app_users
set store_limit = greatest(store_limit, prospection_store_limit)
where role::text = 'technician';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'app_users_prospection_within_store_limit_check'
      and conrelid = 'public.app_users'::regclass
  ) then
    alter table public.app_users
      add constraint app_users_prospection_within_store_limit_check
      check (role::text <> 'technician' or prospection_store_limit <= store_limit);
  end if;
end $$;

notify pgrst, 'reload schema';
