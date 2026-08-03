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
