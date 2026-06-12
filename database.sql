-- Controle de Leads | Otica
-- Banco alvo: Supabase/PostgreSQL.
-- Rode este arquivo no SQL Editor de um projeto Supabase novo/limpo.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
set search_path = public, extensions;

create schema if not exists app_private;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'app_user_role') then
    create type public.app_user_role as enum ('admin', 'store');
  end if;

  if not exists (select 1 from pg_type where typname = 'lead_option_group') then
    create type public.lead_option_group as enum (
      'channel',
      'campaign',
      'conversationStart',
      'conclusion',
      'visited',
      'bought'
    );
  end if;
end $$;

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
    (role = 'store' and admin_user_id is not null and store_id is not null)
  )
);

create table if not exists public.stores (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
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
    group_key not in ('visited', 'bought') or value in ('Sim', 'Não')
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
  visited text check (visited is null or visited in ('Sim', 'Não')),
  bought text check (bought is null or bought in ('Sim', 'Não')),
  purchase_amount numeric(12,2) check (purchase_amount is null or purchase_amount > 0),
  service_order text,
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

create unique index if not exists app_users_one_store_user_idx
  on public.app_users (store_id)
  where role = 'store' and is_active;

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
      u.role = 'admin'
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

create or replace function app_private.rpc_create_admin(
  p_full_name text,
  p_nick text,
  p_password text
)
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
  v_user_id uuid;
  v_nick_key text;
begin
  v_nick_key := app_private.normalize_nick(p_nick);

  if v_nick_key = '' then
    raise exception 'Digite um nick valido.';
  end if;

  if length(coalesce(p_password, '')) < 6 then
    raise exception 'A senha precisa ter pelo menos 6 caracteres.';
  end if;

  if exists (select 1 from public.app_users where nick_key = v_nick_key) then
    raise exception 'Esse nick ja existe.';
  end if;

  insert into public.app_users (nick, password_hash, full_name, role)
  values (
    p_nick,
    crypt(p_password, gen_salt('bf')),
    coalesce(nullif(btrim(p_full_name), ''), v_nick_key),
    'admin'
  )
  returning id into v_user_id;

  perform app_private.seed_default_options(v_user_id);

  return query select * from app_private.create_session_result(v_user_id);
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
      u.role = 'admin'
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

create or replace function app_private.rpc_add_option(
  p_session_token text,
  p_group_key public.lead_option_group
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

  if v_session.user_role <> 'admin' then
    raise exception 'Apenas admin pode alterar opcoes.';
  end if;

  if p_group_key in ('visited', 'bought') then
    raise exception 'Este grupo de opcoes e fixo.';
  end if;

  insert into public.lead_options (admin_user_id, group_key, value, sort_order)
  values (
    v_session.admin_user_id,
    p_group_key,
    app_private.next_option_label(v_session.admin_user_id, p_group_key),
    coalesce((
      select max(sort_order) + 10
      from public.lead_options
      where admin_user_id = v_session.admin_user_id
        and group_key = p_group_key
    ), 10)
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
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role <> 'admin' then
    raise exception 'Apenas admin pode alterar opcoes.';
  end if;

  update public.lead_options
  set value = btrim(p_value)
  where id = p_option_id
    and admin_user_id = v_session.admin_user_id
    and fixed = false
    and is_active = true
    and length(btrim(coalesce(p_value, ''))) > 0;

  if not found then
    raise exception 'Opcao nao encontrada, vazia ou fixa.';
  end if;

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

  if v_session.user_role <> 'admin' then
    raise exception 'Apenas admin pode alterar opcoes.';
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
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
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

create or replace function public.lc_create_admin(
  p_full_name text,
  p_nick text,
  p_password text
)
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
  select * from app_private.rpc_create_admin(p_full_name, p_nick, p_password);
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
  p_group_key public.lead_option_group
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_add_option(p_session_token, p_group_key);
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
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
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

grant execute on function app_private.rpc_create_admin(text, text, text) to anon, authenticated;
grant execute on function app_private.rpc_login(text, text) to anon, authenticated;
grant execute on function app_private.profile_result(text) to anon, authenticated;
grant execute on function app_private.rpc_logout(text) to anon, authenticated;
grant execute on function app_private.rpc_create_store(text, text, text, text) to anon, authenticated;
grant execute on function app_private.rpc_list_stores(text) to anon, authenticated;
grant execute on function app_private.rpc_list_options(text) to anon, authenticated;
grant execute on function app_private.rpc_add_option(text, public.lead_option_group) to anon, authenticated;
grant execute on function app_private.rpc_update_option(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_option(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_list_leads(text) to anon, authenticated;
grant execute on function app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_delete_lead(text, uuid) to anon, authenticated;

grant execute on function public.lc_create_admin(text, text, text) to anon, authenticated;
grant execute on function public.lc_login(text, text) to anon, authenticated;
grant execute on function public.lc_current_profile(text) to anon, authenticated;
grant execute on function public.lc_logout(text) to anon, authenticated;
grant execute on function public.lc_create_store(text, text, text, text) to anon, authenticated;
grant execute on function public.lc_list_stores(text) to anon, authenticated;
grant execute on function public.lc_list_options(text) to anon, authenticated;
grant execute on function public.lc_add_option(text, public.lead_option_group) to anon, authenticated;
grant execute on function public.lc_update_option(text, uuid, text) to anon, authenticated;
grant execute on function public.lc_delete_option(text, uuid) to anon, authenticated;
grant execute on function public.lc_list_leads(text) to anon, authenticated;
grant execute on function public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, uuid) to anon, authenticated;
grant execute on function public.lc_delete_lead(text, uuid) to anon, authenticated;
