-- Rode este arquivo no SQL Editor do Supabase.
-- Corrige a criação de técnicos e habilita edição de nome, nick e senha de lojas/técnicos.

set search_path = public, extensions;

drop function if exists public.lc_create_technician(text, text, text, text);
drop function if exists app_private.rpc_create_technician(text, text, text, text);

create or replace function app_private.rpc_create_technician(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz
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

  if v_session.user_role <> 'admin' then
    raise exception 'Apenas admin pode criar tecnico.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);

  if v_nick_key = '' then
    raise exception 'Digite um nick valido para o tecnico.';
  end if;

  if length(coalesce(p_password, '')) < 6 then
    raise exception 'A senha do tecnico precisa ter pelo menos 6 caracteres.';
  end if;

  if exists (select 1 from public.app_users au where au.nick_key = v_nick_key) then
    raise exception 'Esse nick ja existe.';
  end if;

  insert into public.app_users as new_user (nick, password_hash, full_name, role, admin_user_id, store_id)
  values (
    v_nick_key,
    crypt(p_password, gen_salt('bf')),
    coalesce(nullif(btrim(p_full_name), ''), v_nick_key),
    'technician',
    v_session.admin_user_id,
    null
  )
  returning new_user.id into v_user_id;

  return query
  select u.id, u.nick_key, u.full_name, u.is_active, u.created_at
  from public.app_users u
  where u.id = v_user_id;
end;
$$;

create or replace function public.lc_create_technician(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz
)
language sql
security invoker
as $$
  select * from app_private.rpc_create_technician(p_session_token, p_full_name, p_nick, p_password);
$$;

drop function if exists public.lc_update_store_account(text, uuid, text, text, text);
drop function if exists app_private.rpc_update_store_account(text, uuid, text, text, text);

create or replace function app_private.rpc_update_store_account(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null
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
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role <> 'admin' then
    raise exception 'Apenas admin pode editar loja.';
  end if;

  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'Digite o nome da loja.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um nick valido para a loja.';
  end if;

  v_password := nullif(coalesce(p_password, ''), '');
  if v_password is not null and length(v_password) < 6 then
    raise exception 'A nova senha precisa ter pelo menos 6 caracteres.';
  end if;

  if not exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true
  ) then
    raise exception 'Loja nao encontrada.';
  end if;

  if exists (
    select 1
    from public.app_users au
    where au.nick_key = v_nick_key
      and not (au.role = 'store' and au.store_id = p_store_id)
  ) then
    raise exception 'Esse nick ja existe.';
  end if;

  if exists (
    select 1
    from public.stores st
    where st.nick_key = v_nick_key
      and st.id <> p_store_id
  ) then
    raise exception 'Esse nick ja existe.';
  end if;

  update public.stores st
  set
    name = btrim(p_name),
    nick = v_nick_key
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
  where au.role = 'store'
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
  p_password text default null
)
returns table (
  id uuid,
  name text,
  nick text
)
language sql
security invoker
as $$
  select * from app_private.rpc_update_store_account(p_session_token, p_store_id, p_name, p_nick, p_password);
$$;

drop function if exists public.lc_update_technician_account(text, uuid, text, text, text);
drop function if exists app_private.rpc_update_technician_account(text, uuid, text, text, text);

create or replace function app_private.rpc_update_technician_account(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz
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

  if v_session.user_role <> 'admin' then
    raise exception 'Apenas admin pode editar tecnico.';
  end if;

  if length(btrim(coalesce(p_full_name, ''))) = 0 then
    raise exception 'Digite o nome do tecnico.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um nick valido para o tecnico.';
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
      and au.role = 'technician'
      and au.is_active = true
  ) then
    raise exception 'Tecnico nao encontrado.';
  end if;

  if exists (
    select 1
    from public.app_users au
    where au.nick_key = v_nick_key
      and au.id <> p_technician_id
  ) then
    raise exception 'Esse nick ja existe.';
  end if;

  update public.app_users au
  set
    nick = v_nick_key,
    full_name = btrim(p_full_name),
    password_hash = case
      when v_password is null then au.password_hash
      else crypt(v_password, gen_salt('bf'))
    end
  where au.id = p_technician_id
    and au.admin_user_id = v_session.admin_user_id
    and au.role = 'technician'
    and au.is_active = true;

  return query
  select au.id, au.nick_key, au.full_name, au.is_active, au.created_at
  from public.app_users au
  where au.id = p_technician_id;
end;
$$;

create or replace function public.lc_update_technician_account(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz
)
language sql
security invoker
as $$
  select * from app_private.rpc_update_technician_account(p_session_token, p_technician_id, p_full_name, p_nick, p_password);
$$;

grant execute on function app_private.rpc_create_technician(text, text, text, text) to anon, authenticated;
grant execute on function public.lc_create_technician(text, text, text, text) to anon, authenticated;
grant execute on function app_private.rpc_update_store_account(text, uuid, text, text, text) to anon, authenticated;
grant execute on function public.lc_update_store_account(text, uuid, text, text, text) to anon, authenticated;
grant execute on function app_private.rpc_update_technician_account(text, uuid, text, text, text) to anon, authenticated;
grant execute on function public.lc_update_technician_account(text, uuid, text, text, text) to anon, authenticated;
