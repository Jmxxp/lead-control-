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
