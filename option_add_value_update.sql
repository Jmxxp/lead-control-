-- Rode este arquivo no SQL Editor para permitir que o botão +
-- salve a opção digitada, sem criar "Nova opção" duplicada.

set search_path = public, extensions;

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
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role <> 'admin' then
    raise exception 'Apenas admin pode alterar opcoes.';
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

grant execute on function app_private.rpc_add_option(text, public.lead_option_group, text) to anon, authenticated;
grant execute on function public.lc_add_option(text, public.lead_option_group, text) to anon, authenticated;
