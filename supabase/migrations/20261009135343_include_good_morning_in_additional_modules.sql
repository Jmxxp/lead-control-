-- Bom Dia Vendedor passa a integrar Atendimento, sem licenca/cota propria.
-- A cota de modulos adicionais continua sendo a uniao de clientes com
-- Prospeccao OU Atendimento. Parametros antigos sao aceitos e ignorados.
begin;
set local lock_timeout = '10s';
set local statement_timeout = '120s';
set local search_path = public, app_private, extensions;

-- A coluna antiga fica apenas para compatibilidade. Ela nao pode impedir
-- diminuicao de um plano cuja cota adicional ja foi ajustada.
alter table public.app_users
  drop constraint if exists app_users_good_morning_seller_within_store_limit_check;
comment on column public.app_users.good_morning_seller_store_limit is
  'Legado sem efeito: Bom Dia Vendedor esta incluido em Atendimento. Nao representa cota ou licenca independente.';
comment on column public.stores.good_morning_seller_enabled is
  'Compatibilidade: espelha attendance_enabled. Bom Dia Vendedor esta incluido em Atendimento.';

-- Nome antigo preservado para eventuais dependencias de trigger existentes;
-- agora apenas normaliza a flag e nao consulta nem aplica qualquer cota.
create or replace function app_private.enforce_good_morning_seller_store_quota()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog
as $$
begin
  new.good_morning_seller_enabled := new.attendance_enabled;
  return new;
end;
$$;

drop trigger if exists stores_enforce_good_morning_seller_quota on public.stores;
drop trigger if exists stores_include_good_morning_with_attendance on public.stores;
create trigger stores_include_good_morning_with_attendance
before insert or update of attendance_enabled, good_morning_seller_enabled
on public.stores
for each row execute function app_private.enforce_good_morning_seller_store_quota();

-- Converte clientes existentes sem tocar metas, participantes ou historicos.
update public.stores
set good_morning_seller_enabled = attendance_enabled
where good_morning_seller_enabled is distinct from attendance_enabled;
alter table public.stores
  drop constraint if exists stores_good_morning_included_in_attendance_check;
alter table public.stores
  add constraint stores_good_morning_included_in_attendance_check
  check (good_morning_seller_enabled = attendance_enabled);

create or replace function app_private.good_morning_seller_store_allowed(
  p_admin_user_id uuid,
  p_user_id uuid,
  p_user_role public.app_user_role,
  p_user_store_id uuid,
  p_store_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  select app_private.attendance_store_allowed(
    p_admin_user_id, p_user_id, p_user_role, p_user_store_id, p_store_id
  );
$$;

-- Endpoint legado autorizado continua existindo, mas nao cria outra cota.
create or replace function app_private.rpc_set_technician_good_morning_seller_limit(
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
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode alterar o plano da Agencia.';
  end if;
  if not exists (
    select 1 from public.app_users agency
    where agency.id = p_technician_id
      and agency.admin_user_id = v_session.admin_user_id
      and agency.role::text = 'technician'
      and agency.is_active = true
  ) then
    raise exception 'Agencia nao encontrada.';
  end if;
  -- p_limit e deliberadamente ignorado, inclusive valores antigos fora da cota.
  return true;
end;
$$;


create or replace function app_private.validate_store_agency_access()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_agency record;
  v_store record;
  v_in_use integer;
begin
  select
    u.admin_user_id,
    u.store_limit,
    u.prospection_store_limit
  into v_agency
  from public.app_users u
  where u.id = new.agency_user_id
    and u.role::text = 'technician'
    and u.is_active = true
  for update;

  if not found or v_agency.admin_user_id is distinct from new.admin_user_id then
    raise exception 'Agencia nao encontrada, inativa ou fora desta conta.';
  end if;

  select
    st.is_active,
    st.prospection_enabled,
    st.attendance_enabled
  into v_store
  from public.stores st
  where st.id = new.store_id
    and st.admin_user_id = new.admin_user_id;

  if not found then
    raise exception 'Cliente nao encontrado nesta conta.';
  end if;

  if new.is_active is distinct from true
     or v_store.is_active is distinct from true
     or (
       tg_op = 'UPDATE'
       and old.is_active is true
       and old.agency_user_id is not distinct from new.agency_user_id
       and old.store_id is not distinct from new.store_id
     ) then
    new.updated_at := now();
    return new;
  end if;

  select count(*)::integer
  into v_in_use
  from app_private.store_agency_accesses access
  join public.stores st
    on st.id = access.store_id
   and st.admin_user_id = access.admin_user_id
  where access.agency_user_id = new.agency_user_id
    and access.is_active = true
    and st.is_active = true
    and access.store_id <> new.store_id;

  if v_in_use >= v_agency.store_limit then
    raise exception 'Limite de clientes da agencia atingido (% de %).',
      v_in_use, v_agency.store_limit;
  end if;

  if v_store.prospection_enabled is true
     or v_store.attendance_enabled is true then
    select count(*)::integer
    into v_in_use
    from app_private.store_agency_accesses access
    join public.stores st
      on st.id = access.store_id
     and st.admin_user_id = access.admin_user_id
    where access.agency_user_id = new.agency_user_id
      and access.is_active = true
      and st.is_active = true
      and (st.prospection_enabled = true or st.attendance_enabled = true)
      and access.store_id <> new.store_id;

    if v_in_use >= v_agency.prospection_store_limit then
      raise exception 'A agencia nao possui licenca premium disponivel (% de %).',
        v_in_use, v_agency.prospection_store_limit;
    end if;
  end if;


  new.updated_at := now();
  return new;
end;
$$;

create or replace function app_private.rpc_set_store_good_morning_seller_access(
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
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Somente o Admin ou a Agencia podem alterar este acesso.';
  end if;

  if not exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true
      and (
        v_session.user_role::text = 'admin'
        or app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          st.id
        )
      )
  ) then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  update public.stores
  set good_morning_seller_enabled = attendance_enabled
  where id = p_store_id
    and admin_user_id = v_session.admin_user_id;

  return true;
end;
$$;

create or replace function app_private.rpc_update_store_with_module_access_v2(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null,
  p_lead_enabled boolean default null,
  p_prospection_enabled boolean default null,
  p_attendance_enabled boolean default null,
  p_good_morning_seller_enabled boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_current record;
  v_actual record;
  v_result jsonb;
  v_lead_enabled boolean;
  v_prospection_enabled boolean;
  v_attendance_enabled boolean;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Sem permissao para editar este cliente.';
  end if;

  select
    st.lead_enabled,
    st.prospection_enabled,
    st.attendance_enabled
  into v_current
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and (
      v_session.user_role::text = 'admin'
      or app_private.technician_can_access_store(
        v_session.admin_user_id,
        v_session.user_id,
        st.id
      )
    )
  for update;

  if not found then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  v_lead_enabled := coalesce(p_lead_enabled, v_current.lead_enabled, true);
  v_prospection_enabled := coalesce(p_prospection_enabled, v_current.prospection_enabled, false);
  v_attendance_enabled := coalesce(p_attendance_enabled, v_current.attendance_enabled, false);
  -- O parametro legado e ignorado: Bom Dia acompanha Atendimento.

  -- So libera a cota antes de transferir quando o destino e basico. Nas
  -- trocas Prospeccao <-> Atendimento, preserva a uniao premium ate a
  -- atualizacao atomica final, inclusive depois de um downgrade com excesso.
  if not v_prospection_enabled and not v_attendance_enabled then
    update public.stores
    set prospection_enabled = false, attendance_enabled = false
    where id = p_store_id
      and admin_user_id = v_session.admin_user_id;
  end if;

  select to_jsonb(updated)
  into strict v_result
  from app_private.rpc_update_store_account(
    p_session_token,
    p_store_id,
    p_name,
    p_nick,
    p_password,
    p_technician_id
  ) updated;

  -- O trigger de cota valida a uniao para todas as agencias vinculadas; o
  -- trigger do bundle deriva Bom Dia. Uma troca nao consome nova licenca.
  update public.stores
  set lead_enabled = v_lead_enabled,
      prospection_enabled = v_prospection_enabled,
      attendance_enabled = v_attendance_enabled
  where id = p_store_id
    and admin_user_id = v_session.admin_user_id;

  select
    st.lead_enabled,
    st.prospection_enabled,
    st.attendance_enabled,
    st.good_morning_seller_enabled
  into strict v_actual
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id;

  return v_result || jsonb_build_object(
    'lead_enabled', v_actual.lead_enabled,
    'prospection_enabled', v_actual.prospection_enabled,
    'attendance_enabled', v_actual.attendance_enabled,
    'good_morning_seller_enabled', v_actual.good_morning_seller_enabled
  );
end;
$$;

create or replace function app_private.rpc_get_prospection_entitlements(
  p_session_token text
)
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
      'module_access_version', 3,
      'good_morning_included_in_premium', true,
      'prospection_store_limit', case
        when v_session.user_role::text = 'technician' then coalesce((
          select u.prospection_store_limit
          from public.app_users u
          where u.id = v_session.user_id
        ), 0)
        else 0
      end,
      'prospection_store_count', case
        when v_session.user_role::text = 'technician' then (
          select count(*)
          from app_private.store_agency_accesses access
          join public.stores st
            on st.id = access.store_id
           and st.admin_user_id = access.admin_user_id
          where access.agency_user_id = v_session.user_id
            and access.is_active = true
            and st.is_active = true
            and (st.prospection_enabled = true or st.attendance_enabled = true)
        )
        else 0
      end,
      'premium_store_limit', case
        when v_session.user_role::text = 'technician' then coalesce((
          select u.prospection_store_limit
          from public.app_users u
          where u.id = v_session.user_id
        ), 0)
        else 0
      end,
      'premium_store_count', case
        when v_session.user_role::text = 'technician' then (
          select count(*)
          from app_private.store_agency_accesses access
          join public.stores st
            on st.id = access.store_id
           and st.admin_user_id = access.admin_user_id
          where access.agency_user_id = v_session.user_id
            and access.is_active = true
            and st.is_active = true
            and (st.prospection_enabled = true or st.attendance_enabled = true)
        )
        else 0
      end,
      'good_morning_seller_store_limit', case
        when v_session.user_role::text = 'technician' then coalesce((
          select u.prospection_store_limit
          from public.app_users u
          where u.id = v_session.user_id
        ), 0)
        else 0
      end,
      'good_morning_seller_store_count', case
        when v_session.user_role::text = 'technician' then (
          select count(*)
          from app_private.store_agency_accesses access
          join public.stores st
            on st.id = access.store_id
           and st.admin_user_id = access.admin_user_id
          where access.agency_user_id = v_session.user_id
            and access.is_active = true
            and st.is_active = true
            and (st.prospection_enabled = true or st.attendance_enabled = true)
        )
        else 0
      end
    ),
    'stores', coalesce((
      select jsonb_agg(jsonb_build_object(
        'store_id', st.id,
        'technician_id', st.technician_user_id,
        'lead_enabled', st.lead_enabled,
        'prospection_enabled', st.prospection_enabled,
        'attendance_enabled', st.attendance_enabled,
        'good_morning_seller_enabled', st.attendance_enabled
      ) order by st.created_at)
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and (
          v_session.user_role::text = 'admin'
          or (
            v_session.user_role::text = 'technician'
            and app_private.technician_can_access_store(
              v_session.admin_user_id,
              v_session.user_id,
              st.id
            )
          )
          or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
        )
    ), '[]'::jsonb),
    'technicians', coalesce((
      select jsonb_agg(jsonb_build_object(
        'technician_id', u.id,
        'prospection_store_limit', u.prospection_store_limit,
        'prospection_store_count', (
          select count(*)
          from app_private.store_agency_accesses access
          join public.stores st
            on st.id = access.store_id
           and st.admin_user_id = access.admin_user_id
          where access.agency_user_id = u.id
            and access.is_active = true
            and st.is_active = true
            and (st.prospection_enabled = true or st.attendance_enabled = true)
        ),
        'premium_store_limit', u.prospection_store_limit,
        'premium_store_count', (
          select count(*)
          from app_private.store_agency_accesses access
          join public.stores st
            on st.id = access.store_id
           and st.admin_user_id = access.admin_user_id
          where access.agency_user_id = u.id
            and access.is_active = true
            and st.is_active = true
            and (st.prospection_enabled = true or st.attendance_enabled = true)
        ),
        'good_morning_seller_store_limit', u.prospection_store_limit,
        'good_morning_seller_store_count', (
          select count(*)
          from app_private.store_agency_accesses access
          join public.stores st
            on st.id = access.store_id
           and st.admin_user_id = access.admin_user_id
          where access.agency_user_id = u.id
            and access.is_active = true
            and st.is_active = true
            and (st.prospection_enabled = true or st.attendance_enabled = true)
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

create or replace function app_private.rpc_create_technician_with_feature_plan(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer,
  p_prospection_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_result jsonb;
  v_technician_id uuid;
begin
  if coalesce(p_store_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de clientes entre 0 e 9999.';
  end if;

  if coalesce(p_prospection_limit, -1) not between 0 and p_store_limit then
    raise exception
      'A franquia de Prospeccoes deve ficar entre 0 e o limite total de clientes.';
  end if;

  select to_jsonb(created)
  into strict v_result
  from app_private.rpc_create_technician(
    p_session_token,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit
  ) created;

  v_technician_id := nullif(v_result->>'id', '')::uuid;
  if v_technician_id is null then
    raise exception 'Nao foi possivel identificar a Agencia criada.';
  end if;

  perform app_private.rpc_set_technician_prospection_limit(
    p_session_token,
    v_technician_id,
    p_prospection_limit
  );

  return v_result || jsonb_build_object(
    'store_limit', p_store_limit,
    'prospection_store_limit', p_prospection_limit,
    'premium_store_limit', p_prospection_limit,
    'good_morning_included_in_premium', true
  );
end;
$$;

create or replace function app_private.rpc_update_technician_with_feature_plan(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5,
  p_prospection_limit integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_current_store_limit integer;
  v_result jsonb;
begin
  select *
  into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode alterar o plano da Agencia.';
  end if;

  if coalesce(p_store_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de clientes entre 0 e 9999.';
  end if;

  if coalesce(p_prospection_limit, -1) not between 0 and p_store_limit then
    raise exception
      'A franquia de Prospeccoes deve ficar entre 0 e o limite total de clientes.';
  end if;

  select agency.store_limit
  into v_current_store_limit
  from public.app_users agency
  where agency.id = p_technician_id
    and agency.admin_user_id = v_session.admin_user_id
    and agency.role::text = 'technician'
    and agency.is_active = true
  for update;

  if not found then
    raise exception 'Agencia nao encontrada.';
  end if;

  if p_store_limit < v_current_store_limit then
    perform app_private.rpc_set_technician_prospection_limit(
      p_session_token,
      p_technician_id,
      p_prospection_limit
    );
  end if;

  select to_jsonb(updated)
  into strict v_result
  from app_private.rpc_update_technician_account(
    p_session_token,
    p_technician_id,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit
  ) updated;

  if p_store_limit >= v_current_store_limit then
    perform app_private.rpc_set_technician_prospection_limit(
      p_session_token,
      p_technician_id,
      p_prospection_limit
    );
  end if;

  return v_result || jsonb_build_object(
    'store_limit', p_store_limit,
    'prospection_store_limit', p_prospection_limit,
    'premium_store_limit', p_prospection_limit,
    'good_morning_included_in_premium', true
  );
end;
$$;

create or replace function public.lc_create_technician_with_feature_plan(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer,
  p_prospection_limit integer
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_create_technician_with_feature_plan(
    p_session_token,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit,
    p_prospection_limit
  );
$$;

create or replace function public.lc_update_technician_with_feature_plan(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5,
  p_prospection_limit integer default 0
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_update_technician_with_feature_plan(
    p_session_token,
    p_technician_id,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit,
    p_prospection_limit
  );
$$;


-- Wrappers legados descartam a antiga cota sem alterar autorizacao.
create or replace function app_private.rpc_create_technician_with_all_feature_plan(
  p_session_token text, p_full_name text, p_nick text, p_password text,
  p_store_limit integer, p_prospection_limit integer,
  p_good_morning_seller_limit integer
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_create_technician_with_feature_plan(
    p_session_token, p_full_name, p_nick, p_password,
    p_store_limit, p_prospection_limit
  ) || jsonb_build_object('good_morning_seller_store_limit', p_prospection_limit);
$$;

create or replace function app_private.rpc_update_technician_with_all_feature_plan(
  p_session_token text, p_technician_id uuid, p_full_name text, p_nick text,
  p_password text default null, p_store_limit integer default 5,
  p_prospection_limit integer default 0,
  p_good_morning_seller_limit integer default 0
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_update_technician_with_feature_plan(
    p_session_token, p_technician_id, p_full_name, p_nick, p_password,
    p_store_limit, p_prospection_limit
  ) || jsonb_build_object('good_morning_seller_store_limit', p_prospection_limit);
$$;



-- Os helpers/RPCs ja existentes preservam grants. Os RPCs canonicos abaixo
-- tambem existem em instalacoes antigas, mas faltavam ao bootstrap atual.
revoke all on function app_private.rpc_create_technician_with_feature_plan(text, text, text, text, integer, integer) from public, anon, authenticated;
revoke all on function app_private.rpc_update_technician_with_feature_plan(text, uuid, text, text, text, integer, integer) from public, anon, authenticated;
grant execute on function app_private.rpc_create_technician_with_feature_plan(text, text, text, text, integer, integer) to anon, authenticated;
grant execute on function app_private.rpc_update_technician_with_feature_plan(text, uuid, text, text, text, integer, integer) to anon, authenticated;
revoke all on function public.lc_create_technician_with_feature_plan(text, text, text, text, integer, integer) from public;
revoke all on function public.lc_update_technician_with_feature_plan(text, uuid, text, text, text, integer, integer) from public;
grant execute on function public.lc_create_technician_with_feature_plan(text, text, text, text, integer, integer) to anon, authenticated;
grant execute on function public.lc_update_technician_with_feature_plan(text, uuid, text, text, text, integer, integer) to anon, authenticated;

comment on function public.lc_set_store_good_morning_seller_access(text, uuid, boolean) is
  'Compatibilidade: ignora p_enabled e sincroniza Bom Dia Vendedor com Atendimento.';
comment on function public.lc_set_technician_good_morning_seller_limit(text, uuid, integer) is
  'Compatibilidade: valida Admin e Agencia, ignora cota antiga sem alterar o plano.';
comment on function public.lc_get_prospection_entitlements(text) is
  'Acessos v3: Bom Dia incluido em Atendimento e cota unica para Prospeccao OU Atendimento. Campos de cota Bom Dia sao aliases legados da cota adicional.';
notify pgrst, 'reload schema';
commit;

