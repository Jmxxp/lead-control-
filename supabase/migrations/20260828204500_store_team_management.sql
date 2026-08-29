begin;

create or replace function app_private.store_team_management_allowed(
  p_admin_user_id uuid,
  p_user_id uuid,
  p_user_role public.app_user_role,
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
      and st.is_active = true
      and (
        p_user_role::text = 'admin'
        or (
          p_user_role::text = 'technician'
          and app_private.technician_can_access_store(
            p_admin_user_id,
            p_user_id,
            p_store_id
          )
        )
      )
  );
$$;

create or replace function app_private.rpc_list_store_team(
  p_session_token text,
  p_store_id uuid
)
returns table (
  id uuid,
  name text,
  is_active boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if not app_private.store_team_management_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    p_store_id
  ) then
    raise exception 'Sem permissao para gerenciar a equipe deste cliente.';
  end if;

  return query
  select
    professional.id,
    professional.name,
    professional.is_active,
    professional.created_at
  from public.prospection_professionals professional
  where professional.store_id = p_store_id
    and professional.admin_user_id = v_session.admin_user_id
    and professional.archived_at is null
  order by professional.is_active desc, lower(professional.name), professional.created_at;
end;
$$;

create or replace function public.lc_list_store_team(
  p_session_token text,
  p_store_id uuid
)
returns table (
  id uuid,
  name text,
  is_active boolean,
  created_at timestamptz
)
language sql
security invoker
set search_path = public, app_private, extensions
as $$
  select * from app_private.rpc_list_store_team(p_session_token, p_store_id);
$$;

create or replace function app_private.rpc_upsert_store_team_member(
  p_session_token text,
  p_store_id uuid,
  p_member_id uuid,
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
  v_member_id uuid;
  v_existing_id uuid;
  v_name text;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_name := btrim(coalesce(p_name, ''));

  if not app_private.store_team_management_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    p_store_id
  ) then
    raise exception 'Sem permissao para gerenciar a equipe deste cliente.';
  end if;

  if length(v_name) = 0 then
    raise exception 'Informe o nome da pessoa.';
  end if;

  if length(v_name) > 100 then
    raise exception 'O nome deve ter no maximo 100 caracteres.';
  end if;

  perform 1
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
  for update;

  if not found then
    raise exception 'Cliente nao encontrado.';
  end if;

  if p_member_id is null then
    select professional.id
    into v_member_id
    from public.prospection_professionals professional
    where professional.store_id = p_store_id
      and professional.admin_user_id = v_session.admin_user_id
      and lower(professional.name) = lower(v_name)
    order by (professional.archived_at is null) desc, professional.created_at
    limit 1
    for update;

    if v_member_id is null then
      insert into public.prospection_professionals (
        store_id,
        admin_user_id,
        name,
        is_active
      ) values (
        p_store_id,
        v_session.admin_user_id,
        v_name,
        coalesce(p_is_active, true)
      )
      returning public.prospection_professionals.id into v_member_id;
    else
      update public.prospection_professionals professional
      set name = v_name,
          is_active = coalesce(p_is_active, true),
          archived_at = null,
          archived_by = null,
          updated_at = now()
      where professional.id = v_member_id;
    end if;
  else
    select professional.id
    into v_existing_id
    from public.prospection_professionals professional
    where professional.store_id = p_store_id
      and professional.admin_user_id = v_session.admin_user_id
      and professional.archived_at is null
      and professional.id <> p_member_id
      and lower(professional.name) = lower(v_name)
    limit 1;

    if v_existing_id is not null then
      raise exception 'Ja existe uma pessoa com este nome na equipe.';
    end if;

    update public.prospection_professionals professional
    set name = v_name,
        is_active = coalesce(p_is_active, true),
        updated_at = now()
    where professional.id = p_member_id
      and professional.store_id = p_store_id
      and professional.admin_user_id = v_session.admin_user_id
      and professional.archived_at is null
    returning professional.id into v_member_id;

    if not found then
      raise exception 'Pessoa da equipe nao encontrada.';
    end if;
  end if;

  return v_member_id;
end;
$$;

create or replace function public.lc_upsert_store_team_member(
  p_session_token text,
  p_store_id uuid,
  p_member_id uuid,
  p_name text,
  p_is_active boolean default true
)
returns uuid
language sql
security invoker
set search_path = public, app_private, extensions
as $$
  select app_private.rpc_upsert_store_team_member(
    p_session_token,
    p_store_id,
    p_member_id,
    p_name,
    p_is_active
  );
$$;

create or replace function app_private.rpc_archive_store_team_member(
  p_session_token text,
  p_store_id uuid,
  p_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if not app_private.store_team_management_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    p_store_id
  ) then
    raise exception 'Sem permissao para gerenciar a equipe deste cliente.';
  end if;

  update public.prospection_professionals professional
  set is_active = false,
      archived_at = clock_timestamp(),
      archived_by = v_session.user_id,
      updated_at = now()
  where professional.id = p_member_id
    and professional.store_id = p_store_id
    and professional.admin_user_id = v_session.admin_user_id
    and professional.archived_at is null;

  if not found then
    raise exception 'Pessoa da equipe nao encontrada.';
  end if;
end;
$$;

create or replace function public.lc_archive_store_team_member(
  p_session_token text,
  p_store_id uuid,
  p_member_id uuid
)
returns void
language sql
security invoker
set search_path = public, app_private, extensions
as $$
  select app_private.rpc_archive_store_team_member(
    p_session_token,
    p_store_id,
    p_member_id
  );
$$;

revoke all on function app_private.store_team_management_allowed(uuid, uuid, public.app_user_role, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_list_store_team(text, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_upsert_store_team_member(text, uuid, uuid, text, boolean) from public, anon, authenticated;
revoke all on function app_private.rpc_archive_store_team_member(text, uuid, uuid) from public, anon, authenticated;

grant execute on function app_private.rpc_list_store_team(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_upsert_store_team_member(text, uuid, uuid, text, boolean) to anon, authenticated;
grant execute on function app_private.rpc_archive_store_team_member(text, uuid, uuid) to anon, authenticated;

revoke all on function public.lc_list_store_team(text, uuid) from public;
revoke all on function public.lc_upsert_store_team_member(text, uuid, uuid, text, boolean) from public;
revoke all on function public.lc_archive_store_team_member(text, uuid, uuid) from public;

grant execute on function public.lc_list_store_team(text, uuid) to anon, authenticated;
grant execute on function public.lc_upsert_store_team_member(text, uuid, uuid, text, boolean) to anon, authenticated;
grant execute on function public.lc_archive_store_team_member(text, uuid, uuid) to anon, authenticated;

commit;

notify pgrst, 'reload schema';
