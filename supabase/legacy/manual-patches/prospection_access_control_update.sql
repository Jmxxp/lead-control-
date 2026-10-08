-- Controle de Leads | Licencas separadas de Prospeccoes
-- Atualizacao incremental segura para bancos existentes.
-- Pode ser executada novamente: nao altera o tipo de retorno de funcoes existentes.

set search_path = public, extensions;

alter table public.app_users
  add column if not exists prospection_store_limit integer not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'app_users_prospection_store_limit_check'
      and conrelid = 'public.app_users'::regclass
  ) then
    alter table public.app_users
      add constraint app_users_prospection_store_limit_check
      check (prospection_store_limit between 0 and 9999);
  end if;
end $$;

-- O default TRUE desta primeira inclusao preserva o acesso dos clientes que ja
-- utilizavam Prospeccoes. Novos clientes passam a nascer sem a licenca adicional.
alter table public.stores
  add column if not exists prospection_enabled boolean not null default true;

alter table public.stores
  alter column prospection_enabled set default false;

-- Mantem os planos existentes coerentes antes de ativar a validacao de cota.
update public.app_users agency
set prospection_store_limit = greatest(
  agency.prospection_store_limit,
  (
    select count(*)::integer
    from public.stores st
    where (
        st.technician_user_id = agency.id
        or (
          st.technician_user_id is null
          and 1 = (
            select count(*) from public.app_users only_agency
            where only_agency.admin_user_id = agency.admin_user_id
              and only_agency.role::text = 'technician'
              and only_agency.is_active = true
          )
        )
      )
      and st.is_active = true
      and st.prospection_enabled = true
  )
)
where agency.role::text = 'technician';

update public.app_users
set store_limit = greatest(store_limit, prospection_store_limit)
where role::text = 'technician';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'app_users_prospection_within_store_limit_check'
      and conrelid = 'public.app_users'::regclass
  ) then
    alter table public.app_users
      add constraint app_users_prospection_within_store_limit_check
      check (role::text <> 'technician' or prospection_store_limit <= store_limit);
  end if;
end $$;

create index if not exists stores_technician_prospection_enabled_idx
  on public.stores (technician_user_id, prospection_enabled)
  where is_active = true;

create or replace function app_private.enforce_prospection_store_quota()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_limit integer;
  v_in_use integer;
begin
  if tg_op = 'UPDATE' then
    if old.technician_user_id is not distinct from new.technician_user_id
       and old.admin_user_id is not distinct from new.admin_user_id
       and old.is_active is not distinct from new.is_active
       and old.prospection_enabled is not distinct from new.prospection_enabled then
      return new;
    end if;
  end if;

  if new.is_active is distinct from true
     or new.prospection_enabled is distinct from true then
    return new;
  end if;

  if new.technician_user_id is null then
    raise exception 'Defina a agencia responsavel antes de liberar Prospeccoes.';
  end if;

  select u.prospection_store_limit
  into v_limit
  from public.app_users u
  where u.id = new.technician_user_id
    and u.admin_user_id = new.admin_user_id
    and u.role::text = 'technician'
    and u.is_active = true
  for update;

  if not found then
    raise exception 'Agencia responsavel nao encontrada ou inativa.';
  end if;

  select count(*)::integer
  into v_in_use
  from public.stores st
  where st.technician_user_id = new.technician_user_id
    and st.admin_user_id = new.admin_user_id
    and st.is_active = true
    and st.prospection_enabled = true
    and st.id <> new.id;

  if v_in_use >= v_limit then
    raise exception 'Limite de clientes com Prospeccoes atingido (% de %).', v_in_use, v_limit;
  end if;

  return new;
end;
$$;

drop trigger if exists stores_enforce_prospection_quota on public.stores;
create trigger stores_enforce_prospection_quota
before insert or update of technician_user_id, admin_user_id, is_active, prospection_enabled
on public.stores
for each row execute function app_private.enforce_prospection_store_quota();

create or replace function app_private.rpc_get_prospection_entitlements(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return jsonb_build_object(
    'profile', jsonb_build_object(
      'role', v_session.user_role::text,
      'prospection_store_limit', case
        when v_session.user_role::text = 'technician' then coalesce((
          select u.prospection_store_limit from public.app_users u where u.id = v_session.user_id
        ), 0)
        else 0
      end,
      'prospection_store_count', case
        when v_session.user_role::text = 'technician' then (
          select count(*) from public.stores st
          where st.admin_user_id = v_session.admin_user_id
            and st.technician_user_id = v_session.user_id
            and st.is_active = true
            and st.prospection_enabled = true
        )
        else 0
      end
    ),
    'stores', coalesce((
      select jsonb_agg(jsonb_build_object(
        'store_id', st.id,
        'technician_id', st.technician_user_id,
        'prospection_enabled', st.prospection_enabled
      ) order by st.created_at)
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and (
          v_session.user_role::text = 'admin'
          or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
          or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
        )
    ), '[]'::jsonb),
    'technicians', coalesce((
      select jsonb_agg(jsonb_build_object(
        'technician_id', u.id,
        'prospection_store_limit', u.prospection_store_limit,
        'prospection_store_count', (
          select count(*) from public.stores st
          where st.admin_user_id = v_session.admin_user_id
            and st.technician_user_id = u.id
            and st.is_active = true
            and st.prospection_enabled = true
        )
      ) order by u.full_name, u.nick)
      from public.app_users u
      where u.admin_user_id = v_session.admin_user_id
        and u.role::text = 'technician'
        and u.is_active = true
        and (v_session.user_role::text = 'admin' or u.id = v_session.user_id)
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app_private.rpc_set_technician_prospection_limit(
  p_session_token text,
  p_technician_id uuid,
  p_limit integer
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_limit integer;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode alterar o limite de Prospeccoes.';
  end if;

  if coalesce(p_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de Prospeccoes entre 0 e 9999.';
  end if;

  select u.store_limit
  into v_store_limit
  from public.app_users u
  where u.id = p_technician_id
    and u.admin_user_id = v_session.admin_user_id
    and u.role::text = 'technician'
    and u.is_active = true
  for update;

  if not found then
    raise exception 'Agencia nao encontrada.';
  end if;

  if p_limit > v_store_limit then
    raise exception 'O limite de Prospeccoes nao pode superar o limite total de % clientes.', v_store_limit;
  end if;

  update public.app_users
  set prospection_store_limit = p_limit
  where id = p_technician_id;

  return true;
end;
$$;

create or replace function app_private.rpc_set_store_prospection_access(
  p_session_token text,
  p_store_id uuid,
  p_enabled boolean
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Somente o Admin ou a Agencia podem alterar este acesso.';
  end if;

  select st.*
  into v_store
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and (
      v_session.user_role::text = 'admin'
      or st.technician_user_id = v_session.user_id
    )
  for update;

  if not found then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  update public.stores
  set prospection_enabled = coalesce(p_enabled, false)
  where id = p_store_id;

  return true;
end;
$$;

create or replace function public.lc_get_prospection_entitlements(p_session_token text)
returns jsonb
language sql
security invoker
as $$
  select app_private.rpc_get_prospection_entitlements(p_session_token);
$$;

create or replace function public.lc_set_technician_prospection_limit(
  p_session_token text,
  p_technician_id uuid,
  p_limit integer
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_set_technician_prospection_limit(p_session_token, p_technician_id, p_limit);
$$;

create or replace function public.lc_set_store_prospection_access(
  p_session_token text,
  p_store_id uuid,
  p_enabled boolean
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_set_store_prospection_access(p_session_token, p_store_id, p_enabled);
$$;

-- Toda RPC do modulo ja passa por este helper. A licenca passa a fazer parte
-- do escopo de seguranca e impede acesso direto de clientes nao liberados.
create or replace function app_private.prospection_store_allowed(
  p_admin_user_id uuid,
  p_user_id uuid,
  p_user_role public.app_user_role,
  p_user_store_id uuid,
  p_store_id uuid,
  p_management_only boolean default false
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
      and st.prospection_enabled = true
      and (
        p_user_role::text = 'admin'
        or (p_user_role::text = 'technician' and st.technician_user_id = p_user_id)
        or (
          coalesce(p_management_only, false) = false
          and p_user_role::text = 'store'
          and st.id = p_user_store_id
        )
      )
  );
$$;

-- A exclusao pertence ao modulo Leads e, portanto, nao depende da licenca de
-- Prospeccoes. Esta redefinicao evita acoplamento acidental entre os produtos.
create or replace function app_private.rpc_delete_store_account(
  p_session_token text,
  p_store_id uuid
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

  if not exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true
      and (
        v_session.user_role::text = 'admin'
        or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      )
  ) then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  update public.stores set is_active = false where id = p_store_id;

  update public.app_users
  set is_active = false
  where store_id = p_store_id
    and admin_user_id = v_session.admin_user_id
    and role::text = 'store';

  update public.app_sessions s
  set revoked_at = coalesce(s.revoked_at, now())
  from public.app_users u
  where s.user_id = u.id
    and u.store_id = p_store_id
    and u.admin_user_id = v_session.admin_user_id;

  return true;
end;
$$;

revoke all on function app_private.enforce_prospection_store_quota() from public, anon, authenticated;
revoke all on function app_private.rpc_get_prospection_entitlements(text) from public, anon, authenticated;
revoke all on function app_private.rpc_set_technician_prospection_limit(text, uuid, integer) from public, anon, authenticated;
revoke all on function app_private.rpc_set_store_prospection_access(text, uuid, boolean) from public, anon, authenticated;
revoke all on function app_private.prospection_store_allowed(uuid, uuid, public.app_user_role, uuid, uuid, boolean) from public, anon, authenticated;

grant execute on function app_private.rpc_get_prospection_entitlements(text) to anon, authenticated;
grant execute on function app_private.rpc_set_technician_prospection_limit(text, uuid, integer) to anon, authenticated;
grant execute on function app_private.rpc_set_store_prospection_access(text, uuid, boolean) to anon, authenticated;

revoke all on function public.lc_get_prospection_entitlements(text) from public;
revoke all on function public.lc_set_technician_prospection_limit(text, uuid, integer) from public;
revoke all on function public.lc_set_store_prospection_access(text, uuid, boolean) from public;

grant execute on function public.lc_get_prospection_entitlements(text) to anon, authenticated;
grant execute on function public.lc_set_technician_prospection_limit(text, uuid, integer) to anon, authenticated;
grant execute on function public.lc_set_store_prospection_access(text, uuid, boolean) to anon, authenticated;

notify pgrst, 'reload schema';
