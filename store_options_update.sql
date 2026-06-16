-- Rode este arquivo no SQL Editor do Supabase para permitir que lojas
-- tambem editem as opcoes usadas no cadastro de leads.

set search_path = public, extensions;

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
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar opcoes.';
  end if;

  if p_group_key in ('visited', 'bought') then
    raise exception 'Este grupo de opcoes e fixo.';
  end if;

  v_value := coalesce(nullif(btrim(coalesce(p_value, '')), ''), app_private.next_option_label(v_session.admin_user_id, p_group_key));

  insert into public.lead_options (admin_user_id, group_key, value, sort_order)
  values (
    v_session.admin_user_id,
    p_group_key,
    v_value,
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

  if v_session.user_role not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar opcoes.';
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

  if v_session.user_role not in ('admin', 'technician', 'store') then
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

  if v_session.user_role not in ('admin', 'technician', 'store') then
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

  if v_session.user_role not in ('admin', 'technician', 'store') then
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

  if v_session.user_role not in ('admin', 'technician', 'store') then
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

  if v_session.user_role not in ('admin', 'technician', 'store') then
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

  if v_session.user_role not in ('admin', 'technician', 'store') then
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

  if v_session.user_role not in ('admin', 'technician', 'store') then
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

grant execute on function app_private.rpc_add_option(text, public.lead_option_group, text) to anon, authenticated;
grant execute on function app_private.rpc_update_option(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_option(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_add_custom_category(text, text) to anon, authenticated;
grant execute on function app_private.rpc_update_custom_category(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_custom_category(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_add_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_update_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_custom_option(text, uuid) to anon, authenticated;
