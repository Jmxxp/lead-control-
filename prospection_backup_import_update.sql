-- Controle de Leads | Importacao segura de backups do Prospec
-- Atualizacao incremental. Pode ser executada isoladamente no SQL Editor.

begin;

-- --------------------------------------------------------------------------
-- Compatibilidade da configuracao por categorias
-- --------------------------------------------------------------------------

alter table public.prospection_store_settings
  add column if not exists logo_background_color text not null default '#ffffff';

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

drop trigger if exists prospection_tag_categories_updated_at on public.prospection_tag_categories;
create trigger prospection_tag_categories_updated_at
before update on public.prospection_tag_categories
for each row execute function app_private.set_updated_at();

alter table public.prospection_tag_categories enable row level security;
revoke all on table public.prospection_tag_categories from public, anon, authenticated;
grant select, insert, update, delete on table public.prospection_tag_categories to service_role;

-- --------------------------------------------------------------------------
-- Proveniencia e auditoria (o JSON bruto/PII nao e duplicado no log)
-- --------------------------------------------------------------------------

create table if not exists public.prospection_import_batches (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  imported_by uuid references public.app_users(id) on delete set null,
  source_format text not null,
  schema_version integer not null,
  source_store_id text not null,
  payload_sha256 text not null check (payload_sha256 ~ '^[0-9a-f]{64}$'),
  exported_at timestamptz,
  summary jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint prospection_import_batches_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint prospection_import_batches_store_payload_uidx
    unique (store_id, payload_sha256)
);

create index if not exists prospection_import_batches_store_created_idx
  on public.prospection_import_batches (store_id, created_at desc);

alter table public.prospections
  add column if not exists import_source text,
  add column if not exists import_source_store_id text,
  add column if not exists import_source_id text,
  add column if not exists import_source_updated_at timestamptz,
  add column if not exists import_batch_id uuid,
  add column if not exists imported_at timestamptz;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'prospections_import_batch_fk'
      and conrelid = 'public.prospections'::regclass
  ) then
    alter table public.prospections
      add constraint prospections_import_batch_fk
      foreign key (import_batch_id)
      references public.prospection_import_batches(id)
      on delete set null;
  end if;
end $$;

create unique index if not exists prospections_import_identity_uidx
  on public.prospections (
    store_id,
    import_source,
    import_source_store_id,
    import_source_id
  )
  where import_source_id is not null;

alter table public.prospection_import_batches enable row level security;
revoke all on table public.prospection_import_batches from public, anon, authenticated;
grant select, insert, update, delete on table public.prospection_import_batches to service_role;

-- --------------------------------------------------------------------------
-- Configuracao completa esperada pela interface atual
-- --------------------------------------------------------------------------

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
        'logo_background_color', coalesce(ps.logo_background_color, '#ffffff')
      ) order by st.name)
      from public.stores st
      left join public.prospection_store_settings ps on ps.store_id = st.id
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and app_private.prospection_store_allowed(
          v_session.admin_user_id, v_session.user_id, v_session.user_role,
          v_session.user_store_id, st.id, false
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
        and app_private.prospection_store_allowed(
          v_session.admin_user_id, v_session.user_id, v_session.user_role,
          v_session.user_store_id, pp.store_id, false
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
          v_session.admin_user_id, v_session.user_id, v_session.user_role,
          v_session.user_store_id, pc.store_id, false
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
          v_session.admin_user_id, v_session.user_id, v_session.user_role,
          v_session.user_store_id, pt.store_id, false
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
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, p_store_id, true
  ) then
    raise exception 'Sem permissao para configurar a identidade deste cliente.';
  end if;
  if coalesce(p_logo_background_color, '') !~ '^#[0-9a-fA-F]{6}$' then
    raise exception 'Cor de fundo da logo invalida.';
  end if;

  insert into public.prospection_store_settings (
    store_id, admin_user_id, logo_background_color
  ) values (
    p_store_id, v_session.admin_user_id, lower(p_logo_background_color)
  )
  on conflict (store_id) do update set
    logo_background_color = excluded.logo_background_color;
  return true;
end;
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
    p_session_token, p_store_id, p_logo_background_color
  );
$$;

-- CRUD de categorias/subcategorias. O banco antigo possuia somente etiquetas
-- planas; estes wrappers sincronizam a estrutura com a interface atual.
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
  if not app_private.prospection_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, p_store_id, true
  ) then
    raise exception 'Sem permissao para configurar este cliente.';
  end if;
  if v_name = '' or length(v_name) > 60 then raise exception 'Informe um nome de categoria valido.'; end if;

  if p_category_id is null then
    select coalesce(max(pc.sort_order) + 10, 10) into v_sort_order
    from public.prospection_tag_categories pc where pc.store_id = p_store_id;
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
exception when unique_violation then
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
  if not found or not app_private.prospection_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, v_store_id, true
  ) then
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
  v_expected integer;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.prospection_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, p_store_id, true
  ) then
    raise exception 'Sem permissao para configurar este cliente.';
  end if;
  select count(*) into v_expected
  from public.prospection_tag_categories where store_id = p_store_id;
  if coalesce(cardinality(p_ordered_ids), 0) <> v_expected
     or coalesce((
       select count(distinct ordered.id)
       from unnest(p_ordered_ids) ordered(id)
       join public.prospection_tag_categories pc
         on pc.id = ordered.id
        and pc.store_id = p_store_id
        and pc.admin_user_id = v_session.admin_user_id
     ), 0) <> v_expected then
    raise exception 'A ordem das categorias esta incompleta.';
  end if;
  update public.prospection_tag_categories pc
  set sort_order = ordered.position * 10
  from unnest(p_ordered_ids) with ordinality ordered(id, position)
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
  if not app_private.prospection_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, p_store_id, true
  ) then
    raise exception 'Sem permissao para configurar este cliente.';
  end if;
  if v_label = '' or length(v_label) > 60 then raise exception 'Informe um nome de etiqueta valido.'; end if;
  if not exists (
    select 1 from public.prospection_tag_categories pc
    where pc.id = p_category_id
      and pc.store_id = p_store_id
      and pc.admin_user_id = v_session.admin_user_id
  ) then
    raise exception 'Categoria nao encontrada.';
  end if;
  select coalesce(max(pt.sort_order) + 10, 10) into v_sort_order
  from public.prospection_tags pt where pt.category_id = p_category_id;
  insert into public.prospection_tags (store_id, admin_user_id, category_id, label, sort_order)
  values (p_store_id, v_session.admin_user_id, p_category_id, v_label, v_sort_order)
  returning id into v_tag_id;
  return v_tag_id;
exception when unique_violation then
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
  where pt.id = p_tag_id and pt.admin_user_id = v_session.admin_user_id;
  if not found or not app_private.prospection_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, v_store_id, true
  ) then
    raise exception 'Etiqueta nao encontrada ou sem permissao.';
  end if;
  if v_label = '' or length(v_label) > 60 then raise exception 'Informe um nome de etiqueta valido.'; end if;
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
exception when unique_violation then
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
  v_expected integer;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select pc.store_id into v_store_id
  from public.prospection_tag_categories pc
  where pc.id = p_category_id and pc.admin_user_id = v_session.admin_user_id;
  if not found or not app_private.prospection_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, v_store_id, true
  ) then
    raise exception 'Categoria nao encontrada ou sem permissao.';
  end if;
  select count(*) into v_expected from public.prospection_tags where category_id = p_category_id;
  if coalesce(cardinality(p_ordered_ids), 0) <> v_expected
     or coalesce((
       select count(distinct ordered.id)
       from unnest(p_ordered_ids) ordered(id)
       join public.prospection_tags pt
         on pt.id = ordered.id
        and pt.category_id = p_category_id
        and pt.admin_user_id = v_session.admin_user_id
     ), 0) <> v_expected then
    raise exception 'A ordem das etiquetas esta incompleta.';
  end if;
  update public.prospection_tags pt
  set sort_order = ordered.position * 10
  from unnest(p_ordered_ids) with ordinality ordered(id, position)
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
  select pt.store_id into v_store_id
  from public.prospection_tags pt
  where pt.id = p_tag_id and pt.admin_user_id = v_session.admin_user_id;
  if not found or not app_private.prospection_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, v_store_id, true
  ) then
    raise exception 'Etiqueta nao encontrada ou sem permissao.';
  end if;
  delete from public.prospection_tags where id = p_tag_id;
  return true;
end;
$$;

drop function if exists public.lc_upsert_prospection_category(text, uuid, uuid, text);
drop function if exists public.lc_delete_prospection_category(text, uuid);
drop function if exists public.lc_reorder_prospection_categories(text, uuid, uuid[]);
drop function if exists public.lc_add_prospection_tag(text, uuid, uuid, text);
drop function if exists public.lc_update_prospection_tag(text, uuid, uuid, text);
drop function if exists public.lc_reorder_prospection_tags(text, uuid, uuid[]);
drop function if exists public.lc_delete_prospection_tag(text, uuid);

create function public.lc_upsert_prospection_category(
  p_session_token text, p_store_id uuid, p_category_id uuid, p_name text
)
returns uuid language sql security invoker
as $$ select app_private.rpc_upsert_prospection_category(p_session_token, p_store_id, p_category_id, p_name); $$;
create function public.lc_delete_prospection_category(p_session_token text, p_category_id uuid)
returns boolean language sql security invoker
as $$ select app_private.rpc_delete_prospection_category(p_session_token, p_category_id); $$;
create function public.lc_reorder_prospection_categories(
  p_session_token text, p_store_id uuid, p_ordered_ids uuid[]
)
returns boolean language sql security invoker
as $$ select app_private.rpc_reorder_prospection_categories(p_session_token, p_store_id, p_ordered_ids); $$;
create function public.lc_add_prospection_tag(
  p_session_token text, p_store_id uuid, p_category_id uuid, p_label text
)
returns uuid language sql security invoker
as $$ select app_private.rpc_add_prospection_tag(p_session_token, p_store_id, p_category_id, p_label); $$;
create function public.lc_update_prospection_tag(
  p_session_token text, p_tag_id uuid, p_category_id uuid, p_label text
)
returns boolean language sql security invoker
as $$ select app_private.rpc_update_prospection_tag(p_session_token, p_tag_id, p_category_id, p_label); $$;
create function public.lc_reorder_prospection_tags(
  p_session_token text, p_category_id uuid, p_ordered_ids uuid[]
)
returns boolean language sql security invoker
as $$ select app_private.rpc_reorder_prospection_tags(p_session_token, p_category_id, p_ordered_ids); $$;
create function public.lc_delete_prospection_tag(p_session_token text, p_tag_id uuid)
returns boolean language sql security invoker
as $$ select app_private.rpc_delete_prospection_tag(p_session_token, p_tag_id); $$;

-- --------------------------------------------------------------------------
-- Importador atomico, validacao e merge idempotente
-- --------------------------------------------------------------------------

create or replace function app_private.prospection_import_timestamp(
  p_value text,
  p_field text
)
returns timestamptz
language plpgsql
stable
set search_path = pg_catalog
as $$
begin
  if p_value is null or btrim(p_value) = '' then
    return null;
  end if;
  if length(p_value) > 80 then
    raise exception 'Data invalida no campo %.', p_field using errcode = '22007';
  end if;
  return p_value::timestamptz;
exception
  when datetime_field_overflow or invalid_datetime_format then
    raise exception 'Data invalida no campo %.', p_field using errcode = '22007';
end;
$$;

create or replace function app_private.rpc_import_prospec_backup(
  p_session_token text,
  p_store_id uuid,
  p_payload jsonb,
  p_validate_only boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_source jsonb;
  v_item jsonb;
  v_tag_item jsonb;
  v_format text;
  v_schema_version integer;
  v_source_store_id text;
  v_payload_hash text;
  v_exported_at timestamptz;
  v_created_at timestamptz;
  v_updated_at timestamptz;
  v_returned_at timestamptz;
  v_purchased_at timestamptz;
  v_purchase_amount numeric;
  v_purchase_order text;
  v_probability text;
  v_external_id text;
  v_external_professional_id text;
  v_professional_snapshot text;
  v_professional_id uuid;
  v_professional_map jsonb := '{}'::jsonb;
  v_category_id uuid;
  v_tag_values text[];
  v_label text;
  v_name text;
  v_batch_id uuid;
  v_existing_summary jsonb;
  v_summary jsonb;
  v_inserted boolean;
  v_daily_goal integer := 15;
  v_bonus_minimum numeric := 300;
  v_bonus_amount numeric := 20;
  v_prospects_total integer := 0;
  v_prospects_eligible integer := 0;
  v_prospects_inserted integer := 0;
  v_prospects_updated integer := 0;
  v_prospects_unchanged integer := 0;
  v_prospects_expired integer := 0;
  v_professionals_total integer := 0;
  v_professionals_created integer := 0;
  v_professionals_reused integer := 0;
  v_tags_total integer := 0;
  v_tags_declared integer := 0;
  v_tags_created integer := 0;
  v_tags_reused integer := 0;
  v_tags_recovered integer := 0;
  v_missing_names integer := 0;
  v_normalized_returns integer := 0;
  v_returns integer := 0;
  v_purchases integer := 0;
  v_cutoff timestamptz := now() - interval '2 years';
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Apenas o Admin ou a Agencia podem importar dados.';
  end if;

  perform 1
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
  for update;

  if not found or not app_private.prospection_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, p_store_id, true
  ) then
    raise exception 'Cliente nao encontrado, sem licenca de Prospeccoes ou sem permissao.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('prospec-import:' || p_store_id::text, 0));

  if p_payload is null or jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception 'Selecione um arquivo JSON de backup valido.';
  end if;
  if octet_length(p_payload::text) > 10 * 1024 * 1024 then
    raise exception 'O backup excede o limite de 10 MB.';
  end if;

  v_format := btrim(coalesce(p_payload->>'format', ''));
  begin
    v_schema_version := (p_payload->>'schema_version')::integer;
  exception when others then
    raise exception 'Versao do backup invalida.';
  end;

  if v_format <> 'prospec-backup' or v_schema_version <> 1 then
    raise exception 'Formato de backup incompativel. Use um arquivo Prospec versao 1.';
  end if;
  if p_payload ? 'integrity'
     and coalesce((p_payload #>> '{integrity,import_ready}')::boolean, false) = false then
    raise exception 'O arquivo informa que nao esta pronto para importacao.';
  end if;
  if jsonb_typeof(p_payload #> '{data,stores}') is distinct from 'array'
     or jsonb_array_length(p_payload #> '{data,stores}') <> 1 then
    raise exception 'O backup deve conter exatamente uma loja de origem.';
  end if;

  v_source := p_payload #> '{data,stores,0}';
  v_source_store_id := btrim(coalesce(v_source->>'id', ''));
  if v_source_store_id = '' or length(v_source_store_id) > 200 then
    raise exception 'Identificador da loja de origem invalido.';
  end if;
  if jsonb_typeof(v_source->'professionals') is distinct from 'array'
     or jsonb_typeof(v_source->'tags') is distinct from 'array'
     or jsonb_typeof(v_source->'prospects') is distinct from 'array' then
    raise exception 'O backup nao possui listas validas de profissionais, etiquetas e prospeccoes.';
  end if;

  v_professionals_total := jsonb_array_length(v_source->'professionals');
  v_prospects_total := jsonb_array_length(v_source->'prospects');
  if v_professionals_total > 500 then raise exception 'O backup excede 500 profissionais.'; end if;
  if jsonb_array_length(v_source->'tags') > 500 then raise exception 'O backup excede 500 etiquetas.'; end if;
  if v_prospects_total > 20000 then raise exception 'O backup excede 20.000 prospeccoes.'; end if;

  if exists (
    select 1
    from jsonb_array_elements(v_source->'professionals') item
    group by btrim(coalesce(item->>'id', ''))
    having btrim(coalesce(item->>'id', '')) = '' or count(*) > 1
  ) then
    raise exception 'Existem profissionais sem identificador ou com identificador duplicado.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(v_source->'prospects') item
    group by btrim(coalesce(item->>'id', ''))
    having btrim(coalesce(item->>'id', '')) = '' or count(*) > 1
  ) then
    raise exception 'Existem prospeccoes sem identificador ou com identificador duplicado.';
  end if;

  v_payload_hash := encode(digest(convert_to(p_payload::text, 'UTF8'), 'sha256'), 'hex');
  v_exported_at := app_private.prospection_import_timestamp(p_payload->>'exported_at', 'exported_at');

  begin
    if v_source ? 'daily_goal' then v_daily_goal := (v_source->>'daily_goal')::integer; end if;
    if p_payload #>> '{application,bonus_rules,minimum_purchase_value_exclusive}' is not null then
      v_bonus_minimum := (p_payload #>> '{application,bonus_rules,minimum_purchase_value_exclusive}')::numeric;
    end if;
    if p_payload #>> '{application,bonus_rules,amount_per_sale}' is not null then
      v_bonus_amount := (p_payload #>> '{application,bonus_rules,amount_per_sale}')::numeric;
    end if;
  exception when others then
    raise exception 'A meta ou as regras de bonificacao do backup sao invalidas.';
  end;
  if v_daily_goal not between 1 and 9999 or v_bonus_minimum < 0 or v_bonus_amount < 0 then
    raise exception 'A meta ou as regras de bonificacao do backup estao fora dos limites permitidos.';
  end if;

  -- Valida profissionais sem confiar nos IDs ou na loja presentes no arquivo.
  for v_item in select value from jsonb_array_elements(v_source->'professionals') loop
    v_name := btrim(coalesce(v_item->>'name', ''));
    if v_name = '' or length(v_name) > 100 then
      raise exception 'Existe um profissional com nome invalido no backup.';
    end if;
    perform app_private.prospection_import_timestamp(v_item->>'created_at', 'professionals.created_at');
    perform app_private.prospection_import_timestamp(v_item->>'updated_at', 'professionals.updated_at');
  end loop;

  -- Valida etiquetas declaradas.
  for v_item in select value from jsonb_array_elements(v_source->'tags') loop
    v_label := btrim(coalesce(v_item->>'label', ''));
    if v_label = '' or length(v_label) > 60 then
      raise exception 'Existe uma etiqueta declarada com nome invalido.';
    end if;
  end loop;

  -- Valida todos os registros antes de qualquer escrita.
  for v_item in select value from jsonb_array_elements(v_source->'prospects') loop
    v_external_id := btrim(v_item->>'id');
    if v_item ? 'store_id' and btrim(coalesce(v_item->>'store_id', '')) <> v_source_store_id then
      raise exception 'A prospeccao % pertence a outra loja no arquivo.', v_external_id;
    end if;

    v_created_at := coalesce(
      app_private.prospection_import_timestamp(v_item->>'created_at', 'prospects.created_at'),
      v_exported_at,
      now()
    );
    v_updated_at := coalesce(
      app_private.prospection_import_timestamp(v_item->>'updated_at', 'prospects.updated_at'),
      v_created_at
    );
    if v_created_at > now() + interval '1 day' or v_updated_at > now() + interval '1 day' then
      raise exception 'A prospeccao % possui uma data futura invalida.', v_external_id;
    end if;

    v_name := btrim(coalesce(v_item->>'name', ''));
    if v_name = '' then
      v_missing_names := v_missing_names + 1;
    elsif length(v_name) > 240 then
      raise exception 'A prospeccao % possui nome muito longo.', v_external_id;
    end if;
    if length(coalesce(v_item->>'phone', '')) > 80
       or length(coalesce(v_item->>'cpf', '')) > 40
       or length(coalesce(v_item->>'notes', '')) > 20000 then
      raise exception 'A prospeccao % possui um campo de texto acima do limite.', v_external_id;
    end if;

    v_probability := coalesce(nullif(btrim(v_item->>'probability'), ''), 'blue');
    if v_probability not in ('red', 'yellow', 'blue', 'green') then
      raise exception 'Probabilidade invalida na prospeccao %.', v_external_id;
    end if;
    if jsonb_typeof(v_item->'tags') is distinct from 'array' then
      raise exception 'As etiquetas da prospeccao % nao formam uma lista.', v_external_id;
    end if;
    for v_tag_item in select value from jsonb_array_elements(v_item->'tags') loop
      if jsonb_typeof(v_tag_item) is distinct from 'string' then
        raise exception 'A prospeccao % possui uma etiqueta invalida.', v_external_id;
      end if;
      v_label := btrim(v_tag_item #>> '{}');
      if v_label = '' or length(v_label) > 60 then
        raise exception 'A prospeccao % possui uma etiqueta invalida.', v_external_id;
      end if;
    end loop;

    v_returned_at := app_private.prospection_import_timestamp(v_item->>'returned_at', 'prospects.returned_at');
    v_purchased_at := app_private.prospection_import_timestamp(v_item->>'purchased_at', 'prospects.purchased_at');
    v_purchase_order := nullif(btrim(coalesce(v_item->>'purchase_os', v_item->>'purchase_order', '')), '');
    v_purchase_amount := null;
    begin
      if coalesce(v_item->>'purchase_value', v_item->>'purchase_amount') is not null then
        v_purchase_amount := coalesce(v_item->>'purchase_value', v_item->>'purchase_amount')::numeric;
      end if;
    exception when others then
      raise exception 'Valor de compra invalido na prospeccao %.', v_external_id;
    end;
    if v_purchased_at is null and (v_purchase_amount is not null or v_purchase_order is not null) then
      raise exception 'A prospeccao % possui dados de compra sem data de compra.', v_external_id;
    end if;
    if v_purchased_at is not null and (coalesce(v_purchase_amount, 0) <= 0 or v_purchase_order is null) then
      raise exception 'A compra da prospeccao % precisa de valor e OS.', v_external_id;
    end if;
    if length(coalesce(v_purchase_order, '')) > 200 then
      raise exception 'A OS da prospeccao % excede o limite.', v_external_id;
    end if;
    if v_returned_at is not null then v_returns := v_returns + 1; end if;
    if v_purchased_at is not null then
      v_purchases := v_purchases + 1;
      if v_returned_at is null then v_normalized_returns := v_normalized_returns + 1; end if;
    end if;
    if v_created_at < v_cutoff then
      v_prospects_expired := v_prospects_expired + 1;
    else
      v_prospects_eligible := v_prospects_eligible + 1;
    end if;
  end loop;

  select count(*) into v_tags_declared
  from (
    select distinct lower(btrim(item->>'label')) as label
    from jsonb_array_elements(v_source->'tags') item
  ) declared;

  select count(*) into v_tags_total
  from (
    select distinct lower(label) as normalized_label
    from (
      select btrim(item->>'label') as label
      from jsonb_array_elements(v_source->'tags') item
      union all
      select btrim(tag_item #>> '{}') as label
      from jsonb_array_elements(v_source->'prospects') prospect
      cross join lateral jsonb_array_elements(prospect->'tags') tag_item
    ) labels
  ) unique_labels;
  v_tags_recovered := greatest(v_tags_total - v_tags_declared, 0);

  select pib.id, pib.summary into v_batch_id, v_existing_summary
  from public.prospection_import_batches pib
  where pib.store_id = p_store_id
    and pib.payload_sha256 = v_payload_hash;

  v_summary := jsonb_build_object(
    'valid', true,
    'validate_only', coalesce(p_validate_only, false),
    'already_imported', v_existing_summary is not null,
    'target_store_id', p_store_id,
    'source', jsonb_build_object(
      'format', v_format,
      'schema_version', v_schema_version,
      'exported_at', v_exported_at
    ),
    'settings', jsonb_build_object(
      'daily_goal', v_daily_goal,
      'bonus_minimum', v_bonus_minimum,
      'bonus_amount', v_bonus_amount
    ),
    'counts', jsonb_build_object(
      'prospects', jsonb_build_object(
        'total', v_prospects_total,
        'eligible', v_prospects_eligible,
        'inserted', 0,
        'updated', 0,
        'unchanged', 0,
        'skipped_expired', v_prospects_expired
      ),
      'professionals', jsonb_build_object(
        'total', v_professionals_total,
        'created', 0,
        'reused', 0
      ),
      'tags', jsonb_build_object(
        'total', v_tags_total,
        'created', 0,
        'reused', 0,
        'recovered_from_history', v_tags_recovered
      ),
      'outcomes', jsonb_build_object('returns', v_returns, 'purchases', v_purchases),
      'normalized', jsonb_build_object(
        'missing_names', v_missing_names,
        'purchases_without_return', v_normalized_returns
      )
    ),
    'warnings', jsonb_strip_nulls(jsonb_build_object(
      'missing_names', case when v_missing_names > 0 then
        v_missing_names::text || ' contato(s) sem nome receberao uma identificacao segura.' end,
      'recovered_tags', case when v_tags_recovered > 0 then
        v_tags_recovered::text || ' etiqueta(s) historica(s) serao recuperadas.' end,
      'retention', case when v_prospects_expired > 0 then
        v_prospects_expired::text || ' registro(s) anteriores a dois anos nao serao importados.' end
    ))
  );

  if coalesce(p_validate_only, false) then
    return v_summary;
  end if;

  if v_existing_summary is not null then
    v_summary := jsonb_set(v_summary, '{validate_only}', 'false'::jsonb, true);
    v_summary := jsonb_set(v_summary, '{already_imported}', 'true'::jsonb, true);
    v_summary := jsonb_set(v_summary, '{batch_id}', to_jsonb(v_batch_id), true);
    v_summary := jsonb_set(v_summary, '{counts,prospects,unchanged}', to_jsonb(v_prospects_eligible), true);
    v_summary := jsonb_set(v_summary, '{counts,professionals,reused}', to_jsonb(v_professionals_total), true);
    v_summary := jsonb_set(v_summary, '{counts,tags,reused}', to_jsonb(v_tags_total), true);
    return v_summary;
  end if;

  insert into public.prospection_import_batches (
    admin_user_id, store_id, imported_by, source_format, schema_version,
    source_store_id, payload_sha256, exported_at
  ) values (
    v_session.admin_user_id, p_store_id, v_session.user_id, v_format,
    v_schema_version, v_source_store_id, v_payload_hash, v_exported_at
  ) returning id into v_batch_id;

  -- Apenas configuracoes de uso. Nome, login, logo e identidade nunca sao alterados.
  insert into public.prospection_store_settings (
    store_id, admin_user_id, daily_goal, bonus_minimum, bonus_amount
  ) values (
    p_store_id, v_session.admin_user_id, v_daily_goal, v_bonus_minimum, v_bonus_amount
  )
  on conflict (store_id) do update set
    daily_goal = excluded.daily_goal,
    bonus_minimum = excluded.bonus_minimum,
    bonus_amount = excluded.bonus_amount;

  -- Profissionais sao mesclados por nome; os IDs externos servem apenas ao mapa.
  for v_item in select value from jsonb_array_elements(v_source->'professionals') loop
    v_external_professional_id := btrim(v_item->>'id');
    v_name := btrim(v_item->>'name');
    select pp.id into v_professional_id
    from public.prospection_professionals pp
    where pp.store_id = p_store_id
      and pp.admin_user_id = v_session.admin_user_id
      and lower(pp.name) = lower(v_name)
    limit 1;

    if v_professional_id is null then
      insert into public.prospection_professionals (
        store_id, admin_user_id, name, is_active, created_at, updated_at
      ) values (
        p_store_id,
        v_session.admin_user_id,
        v_name,
        coalesce((v_item->>'is_active')::boolean, true),
        coalesce(app_private.prospection_import_timestamp(v_item->>'created_at', 'professionals.created_at'), now()),
        coalesce(app_private.prospection_import_timestamp(v_item->>'updated_at', 'professionals.updated_at'), now())
      ) returning id into v_professional_id;
      v_professionals_created := v_professionals_created + 1;
    else
      v_professionals_reused := v_professionals_reused + 1;
    end if;
    v_professional_map := v_professional_map || jsonb_build_object(
      v_external_professional_id, v_professional_id::text
    );
  end loop;

  select pc.id into v_category_id
  from public.prospection_tag_categories pc
  where pc.store_id = p_store_id
    and pc.admin_user_id = v_session.admin_user_id
    and lower(pc.name) = lower('Etiquetas importadas')
  limit 1;
  if v_category_id is null then
    insert into public.prospection_tag_categories (store_id, admin_user_id, name, sort_order)
    values (
      p_store_id,
      v_session.admin_user_id,
      'Etiquetas importadas',
      coalesce((select max(sort_order) + 10 from public.prospection_tag_categories where store_id = p_store_id), 10)
    ) returning id into v_category_id;
  end if;

  for v_label in
    select min(label) as label
    from (
      select btrim(item->>'label') as label
      from jsonb_array_elements(v_source->'tags') item
      union all
      select btrim(tag_item #>> '{}') as label
      from jsonb_array_elements(v_source->'prospects') prospect
      cross join lateral jsonb_array_elements(prospect->'tags') tag_item
    ) labels
    group by lower(label)
    order by min(label)
  loop
    if exists (
      select 1 from public.prospection_tags pt
      where pt.store_id = p_store_id
        and pt.admin_user_id = v_session.admin_user_id
        and lower(pt.label) = lower(v_label)
    ) then
      v_tags_reused := v_tags_reused + 1;
    else
      insert into public.prospection_tags (
        store_id, admin_user_id, category_id, label, sort_order
      ) values (
        p_store_id,
        v_session.admin_user_id,
        v_category_id,
        v_label,
        coalesce((select max(sort_order) + 10 from public.prospection_tags where category_id = v_category_id), 10)
      );
      v_tags_created := v_tags_created + 1;
    end if;
  end loop;

  -- Registros sao ligados a origem; telefone/nome nunca sao usados para deduplicar.
  for v_item in select value from jsonb_array_elements(v_source->'prospects') loop
    v_external_id := btrim(v_item->>'id');
    v_created_at := coalesce(
      app_private.prospection_import_timestamp(v_item->>'created_at', 'prospects.created_at'),
      v_exported_at,
      now()
    );
    if v_created_at < v_cutoff then continue; end if;

    v_updated_at := coalesce(
      app_private.prospection_import_timestamp(v_item->>'updated_at', 'prospects.updated_at'),
      v_created_at
    );
    v_name := btrim(coalesce(v_item->>'name', ''));
    if v_name = '' then
      v_name := 'Contato importado · ' || upper(right(v_external_id, 6));
    end if;
    v_probability := coalesce(nullif(btrim(v_item->>'probability'), ''), 'blue');
    v_returned_at := app_private.prospection_import_timestamp(v_item->>'returned_at', 'prospects.returned_at');
    v_purchased_at := app_private.prospection_import_timestamp(v_item->>'purchased_at', 'prospects.purchased_at');
    if v_purchased_at is not null and v_returned_at is null then v_returned_at := v_purchased_at; end if;
    v_purchase_order := nullif(btrim(coalesce(v_item->>'purchase_os', v_item->>'purchase_order', '')), '');
    v_purchase_amount := null;
    if coalesce(v_item->>'purchase_value', v_item->>'purchase_amount') is not null then
      v_purchase_amount := coalesce(v_item->>'purchase_value', v_item->>'purchase_amount')::numeric;
    end if;

    v_external_professional_id := nullif(btrim(coalesce(v_item->>'professional_id', '')), '');
    v_professional_snapshot := nullif(btrim(coalesce(v_item->>'professional_name_snapshot', '')), '');
    v_professional_id := null;
    if v_external_professional_id is not null
       and v_professional_map ? v_external_professional_id then
      v_professional_id := (v_professional_map->>v_external_professional_id)::uuid;
    elsif v_professional_snapshot is not null then
      select pp.id into v_professional_id
      from public.prospection_professionals pp
      where pp.store_id = p_store_id
        and pp.admin_user_id = v_session.admin_user_id
        and lower(pp.name) = lower(v_professional_snapshot)
      limit 1;
    end if;

    select coalesce(array_agg(pt.label order by pt.label), '{}'::text[])
    into v_tag_values
    from public.prospection_tags pt
    where pt.store_id = p_store_id
      and pt.admin_user_id = v_session.admin_user_id
      and exists (
        select 1
        from jsonb_array_elements(v_item->'tags') source_tag
        where lower(btrim(source_tag #>> '{}')) = lower(pt.label)
      );

    v_inserted := null;
    insert into public.prospections (
      admin_user_id, store_id, name, phone, cpf, notes, probability, tags,
      professional_id, professional_name_snapshot, returned_at, purchased_at,
      purchase_amount, purchase_order, created_by, updated_by, created_at, updated_at,
      import_source, import_source_store_id, import_source_id,
      import_source_updated_at, import_batch_id, imported_at
    ) values (
      v_session.admin_user_id,
      p_store_id,
      v_name,
      nullif(btrim(coalesce(v_item->>'phone', '')), ''),
      nullif(btrim(coalesce(v_item->>'cpf', '')), ''),
      nullif(btrim(coalesce(v_item->>'notes', '')), ''),
      v_probability,
      v_tag_values,
      v_professional_id,
      coalesce((select name from public.prospection_professionals where id = v_professional_id), v_professional_snapshot),
      v_returned_at,
      v_purchased_at,
      v_purchase_amount,
      v_purchase_order,
      v_session.user_id,
      v_session.user_id,
      v_created_at,
      v_updated_at,
      'prospec-backup:v1',
      v_source_store_id,
      v_external_id,
      v_updated_at,
      v_batch_id,
      now()
    )
    on conflict (store_id, import_source, import_source_store_id, import_source_id)
      where import_source_id is not null
    do update set
      name = excluded.name,
      phone = excluded.phone,
      cpf = excluded.cpf,
      notes = excluded.notes,
      probability = excluded.probability,
      tags = excluded.tags,
      professional_id = excluded.professional_id,
      professional_name_snapshot = excluded.professional_name_snapshot,
      returned_at = excluded.returned_at,
      purchased_at = excluded.purchased_at,
      purchase_amount = excluded.purchase_amount,
      purchase_order = excluded.purchase_order,
      updated_by = excluded.updated_by,
      import_source_updated_at = excluded.import_source_updated_at,
      import_batch_id = excluded.import_batch_id,
      imported_at = excluded.imported_at
    where public.prospections.import_source_updated_at is null
       or excluded.import_source_updated_at > public.prospections.import_source_updated_at
    returning (xmax = 0) into v_inserted;

    if v_inserted is true then
      v_prospects_inserted := v_prospects_inserted + 1;
    elsif v_inserted is false then
      v_prospects_updated := v_prospects_updated + 1;
    else
      v_prospects_unchanged := v_prospects_unchanged + 1;
    end if;
  end loop;

  v_summary := jsonb_set(v_summary, '{validate_only}', 'false'::jsonb, true);
  v_summary := jsonb_set(v_summary, '{already_imported}', 'false'::jsonb, true);
  v_summary := jsonb_set(v_summary, '{batch_id}', to_jsonb(v_batch_id), true);
  v_summary := jsonb_set(v_summary, '{counts,prospects,inserted}', to_jsonb(v_prospects_inserted), true);
  v_summary := jsonb_set(v_summary, '{counts,prospects,updated}', to_jsonb(v_prospects_updated), true);
  v_summary := jsonb_set(v_summary, '{counts,prospects,unchanged}', to_jsonb(v_prospects_unchanged), true);
  v_summary := jsonb_set(v_summary, '{counts,professionals,created}', to_jsonb(v_professionals_created), true);
  v_summary := jsonb_set(v_summary, '{counts,professionals,reused}', to_jsonb(v_professionals_reused), true);
  v_summary := jsonb_set(v_summary, '{counts,tags,created}', to_jsonb(v_tags_created), true);
  v_summary := jsonb_set(v_summary, '{counts,tags,reused}', to_jsonb(v_tags_reused), true);

  update public.prospection_import_batches
  set summary = v_summary
  where id = v_batch_id;

  return v_summary;
end;
$$;

create or replace function public.lc_import_prospec_backup(
  p_session_token text,
  p_store_id uuid,
  p_payload jsonb,
  p_validate_only boolean default false
)
returns jsonb
language sql
security invoker
as $$
  select app_private.rpc_import_prospec_backup(
    p_session_token, p_store_id, p_payload, p_validate_only
  );
$$;

revoke all on function app_private.rpc_get_prospection_configuration(text) from public, anon, authenticated;
grant execute on function app_private.rpc_get_prospection_configuration(text) to anon, authenticated;
revoke all on function app_private.rpc_save_prospection_logo_background(text, uuid, text) from public, anon, authenticated;
grant execute on function app_private.rpc_save_prospection_logo_background(text, uuid, text) to anon, authenticated;
revoke all on function public.lc_save_prospection_logo_background(text, uuid, text) from public;
grant execute on function public.lc_save_prospection_logo_background(text, uuid, text) to anon, authenticated;

revoke all on function app_private.rpc_upsert_prospection_category(text, uuid, uuid, text) from public, anon, authenticated;
revoke all on function app_private.rpc_delete_prospection_category(text, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_reorder_prospection_categories(text, uuid, uuid[]) from public, anon, authenticated;
revoke all on function app_private.rpc_add_prospection_tag(text, uuid, uuid, text) from public, anon, authenticated;
revoke all on function app_private.rpc_update_prospection_tag(text, uuid, uuid, text) from public, anon, authenticated;
revoke all on function app_private.rpc_reorder_prospection_tags(text, uuid, uuid[]) from public, anon, authenticated;
revoke all on function app_private.rpc_delete_prospection_tag(text, uuid) from public, anon, authenticated;
grant execute on function app_private.rpc_upsert_prospection_category(text, uuid, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_prospection_category(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_reorder_prospection_categories(text, uuid, uuid[]) to anon, authenticated;
grant execute on function app_private.rpc_add_prospection_tag(text, uuid, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_update_prospection_tag(text, uuid, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_reorder_prospection_tags(text, uuid, uuid[]) to anon, authenticated;
grant execute on function app_private.rpc_delete_prospection_tag(text, uuid) to anon, authenticated;

revoke all on function public.lc_upsert_prospection_category(text, uuid, uuid, text) from public;
revoke all on function public.lc_delete_prospection_category(text, uuid) from public;
revoke all on function public.lc_reorder_prospection_categories(text, uuid, uuid[]) from public;
revoke all on function public.lc_add_prospection_tag(text, uuid, uuid, text) from public;
revoke all on function public.lc_update_prospection_tag(text, uuid, uuid, text) from public;
revoke all on function public.lc_reorder_prospection_tags(text, uuid, uuid[]) from public;
revoke all on function public.lc_delete_prospection_tag(text, uuid) from public;
grant execute on function public.lc_upsert_prospection_category(text, uuid, uuid, text) to anon, authenticated;
grant execute on function public.lc_delete_prospection_category(text, uuid) to anon, authenticated;
grant execute on function public.lc_reorder_prospection_categories(text, uuid, uuid[]) to anon, authenticated;
grant execute on function public.lc_add_prospection_tag(text, uuid, uuid, text) to anon, authenticated;
grant execute on function public.lc_update_prospection_tag(text, uuid, uuid, text) to anon, authenticated;
grant execute on function public.lc_reorder_prospection_tags(text, uuid, uuid[]) to anon, authenticated;
grant execute on function public.lc_delete_prospection_tag(text, uuid) to anon, authenticated;

revoke all on function app_private.prospection_import_timestamp(text, text) from public, anon, authenticated;
revoke all on function app_private.rpc_import_prospec_backup(text, uuid, jsonb, boolean) from public, anon, authenticated;
grant execute on function app_private.rpc_import_prospec_backup(text, uuid, jsonb, boolean) to anon, authenticated;
revoke all on function public.lc_import_prospec_backup(text, uuid, jsonb, boolean) from public;
grant execute on function public.lc_import_prospec_backup(text, uuid, jsonb, boolean) to anon, authenticated;

notify pgrst, 'reload schema';
commit;
