-- Rode este arquivo no SQL Editor do Supabase para permitir adicionar
-- e editar usando uma opcao que ja foi excluida. As funcoes reativam
-- a opcao antiga em vez de bater na constraint lead_options_unique_value.

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
  v_sort_order integer;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar opcoes.';
  end if;

  if p_group_key in ('visited', 'bought') then
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

grant execute on function app_private.rpc_add_option(text, public.lead_option_group, text) to anon, authenticated;

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

grant execute on function app_private.rpc_update_option(text, uuid, text) to anon, authenticated;
