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
