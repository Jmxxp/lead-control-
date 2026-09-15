-- Atendimentos | múltiplas ordens de serviço e cancelamento auditável.
--
-- Compatibilidade:
--   * os RPCs V3/V1 continuam disponíveis para clientes antigos;
--   * V4/V2 normalizam as OS em uma tabela privada e calculam o total no banco;
--   * cancelar preserva o snapshot comercial, mas remove o registro das
--     projeções, metas e métricas operacionais.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';
set local search_path = '';
-- Alguns wrappers aparecem antes dos helpers privados no arquivo para manter
-- o contrato V4/V2 junto. Todos são compilados/exercitados no smoke test.
set local check_function_bodies = off;

alter table public.attendances
  add column if not exists canceled_at timestamptz,
  add column if not exists canceled_by uuid,
  add column if not exists cancellation_reason text,
  add column if not exists canceled_original_tag text,
  add column if not exists canceled_original_service_value numeric(14,2),
  add column if not exists canceled_original_purchase_value numeric(14,2),
  add column if not exists canceled_original_service_order text,
  add column if not exists canceled_original_idempotency_key text,
  add column if not exists canceled_original_lead_id uuid,
  add column if not exists canceled_original_prospection_id uuid,
  add column if not exists canceled_original_match_status text;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint constraints
    where constraints.conname = 'attendances_cancellation_state_check'
      and constraints.conrelid = 'public.attendances'::regclass
  ) then
    alter table public.attendances
      add constraint attendances_cancellation_state_check check (
        (
          canceled_at is null
          and canceled_by is null
          and cancellation_reason is null
          and canceled_original_tag is null
          and canceled_original_service_value is null
          and canceled_original_purchase_value is null
          and canceled_original_service_order is null
          and canceled_original_idempotency_key is null
          and canceled_original_lead_id is null
          and canceled_original_prospection_id is null
          and canceled_original_match_status is null
        )
        or (
          canceled_at is not null
          and canceled_by is not null
          and canceled_original_tag in ('budget', 'purchase', 'other')
          and char_length(coalesce(cancellation_reason, '')) <= 500
        )
      );
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint constraints
    where constraints.conname = 'attendances_id_store_admin_unique'
      and constraints.conrelid = 'public.attendances'::regclass
  ) then
    alter table public.attendances
      add constraint attendances_id_store_admin_unique
      unique (id, store_id, admin_user_id);
  end if;
end;
$$;

create or replace function app_private.lock_attendance_service_orders(
  p_store_id uuid,
  p_service_orders jsonb
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_order_key text;
begin
  for v_order_key in
    select distinct pg_catalog.lower(pg_catalog.btrim(items.value ->> 'service_order'))
    from pg_catalog.jsonb_array_elements(coalesce(p_service_orders, '[]'::jsonb)) items(value)
    order by 1
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'attendance:os:' || p_store_id::text || ':' || v_order_key,
        0
      )
    );
  end loop;
end;
$$;

create or replace function app_private.assert_attendance_service_orders_available(
  p_store_id uuid,
  p_attendance_id uuid,
  p_service_orders jsonb
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from app_private.attendance_service_orders existing
    join pg_catalog.jsonb_array_elements(coalesce(p_service_orders, '[]'::jsonb)) requested(value)
      on existing.service_order_key = pg_catalog.lower(
        pg_catalog.btrim(requested.value ->> 'service_order')
      )
    where existing.store_id = p_store_id
      and existing.canceled_at is null
      and (
        p_attendance_id is null
        or existing.attendance_id <> p_attendance_id
      )
  ) or exists (
    -- Compatibilidade com uma eventual escrita V3 que ainda não tenha sido
    -- espelhada pelo trigger (por exemplo, durante rollout entre abas antigas).
    select 1
    from public.attendances existing
    join pg_catalog.jsonb_array_elements(coalesce(p_service_orders, '[]'::jsonb)) requested(value)
      on pg_catalog.lower(pg_catalog.btrim(existing.service_order))
        = pg_catalog.lower(pg_catalog.btrim(requested.value ->> 'service_order'))
    where existing.store_id = p_store_id
      and existing.tag = 'purchase'
      and existing.canceled_at is null
      and (
        p_attendance_id is null
        or existing.id <> p_attendance_id
      )
  ) then
    raise exception using
      errcode = '23505',
      message = 'Uma das OS informadas já está vinculada a outro atendimento desta loja.';
  end if;
end;
$$;

create or replace function app_private.replace_attendance_service_orders(
  p_attendance_id uuid,
  p_store_id uuid,
  p_admin_user_id uuid,
  p_service_orders jsonb
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  delete from app_private.attendance_service_orders service_orders
  where service_orders.attendance_id = p_attendance_id;

  insert into app_private.attendance_service_orders (
    attendance_id,
    store_id,
    admin_user_id,
    position,
    service_order,
    amount
  )
  select
    p_attendance_id,
    p_store_id,
    p_admin_user_id,
    items.ordinality::smallint,
    items.value ->> 'service_order',
    (items.value ->> 'amount')::numeric(14,2)
  from pg_catalog.jsonb_array_elements(coalesce(p_service_orders, '[]'::jsonb))
    with ordinality items(value, ordinality);
end;
$$;

create or replace function app_private.rpc_upsert_attendance_v4(
  p_session_token text,
  p_store_id uuid,
  p_professional_name text,
  p_customer_name text,
  p_phone text,
  p_cpf text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_service_orders jsonb,
  p_attended_on date,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_tag text;
  v_orders jsonb;
  v_total numeric(14,2);
  v_primary_order text;
  v_response jsonb;
  v_attendance_id uuid;
  v_existing_orders jsonb;
  v_store_id uuid;
  v_admin_user_id uuid;
  v_replay boolean := false;
  v_possible_existing_id uuid;
begin
  if p_attended_on is null then
    raise exception using
      errcode = '22004',
      message = 'Informe a data em que o atendimento aconteceu.';
  end if;

  select * into v_session
  from app_private.session_user(p_session_token);
  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente não pode registrar atendimento em outra loja.';
    end if;
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;
  if v_store_id is null or not app_private.attendance_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  v_tag := app_private.attendance_normalize_tag(p_tag);
  if v_tag is null then
    raise exception 'Use a etiqueta Orçamento, Compra ou Outro.';
  end if;

  if v_tag = 'purchase' then
    v_orders := app_private.normalize_attendance_service_orders(
      p_service_orders,
      true
    );
    select
      pg_catalog.round(pg_catalog.sum((orders.value ->> 'amount')::numeric), 2),
      v_orders -> 0 ->> 'service_order'
    into v_total, v_primary_order
    from pg_catalog.jsonb_array_elements(v_orders) orders(value);
  else
    v_orders := app_private.normalize_attendance_service_orders(
      p_service_orders,
      false
    );
    if pg_catalog.jsonb_array_length(v_orders) > 0 then
      raise exception 'Ordens de serviço só podem ser informadas na etiqueta Compra.';
    end if;
    v_total := null;
    v_primary_order := null;
  end if;

  -- A ordem global dos locks impede deadlock quando duas vendas trocam OS
  -- primária/secundária entre si. O lock da loja vem sempre primeiro, igual
  -- ao V2/cancelamento, evitando ciclo row -> OS contra OS -> row.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('attendance:store-edit:' || v_store_id::text, 0)
  );
  perform app_private.lock_attendance_service_orders(v_store_id, v_orders);

  select attendance.id into v_possible_existing_id
  from public.attendances attendance
  where attendance.store_id = v_store_id
    and (
      (
        nullif(left(pg_catalog.btrim(coalesce(p_idempotency_key, '')), 200), '')
          is not null
        and attendance.idempotency_key = nullif(
          left(pg_catalog.btrim(coalesce(p_idempotency_key, '')), 200),
          ''
        )
      )
      or (
        v_tag = 'purchase'
        and attendance.tag = 'purchase'
        and pg_catalog.lower(pg_catalog.btrim(attendance.service_order))
          = pg_catalog.lower(v_primary_order)
      )
    )
  order by (
    attendance.idempotency_key = nullif(
      left(pg_catalog.btrim(coalesce(p_idempotency_key, '')), 200),
      ''
    )
  ) desc
  limit 1;

  perform app_private.assert_attendance_service_orders_available(
    v_store_id,
    v_possible_existing_id,
    v_orders
  );

  -- O RPC V3 continua sendo a autoridade para sessão, tenant, identidade,
  -- idempotência e projeções em lead/prospecção.
  begin
    v_response := app_private.rpc_upsert_attendance_v3_required_date(
      p_session_token,
      v_store_id,
      p_professional_name,
      p_customer_name,
      p_phone,
      p_cpf,
      p_description,
      v_tag,
      p_service_value,
      v_total,
      v_primary_order,
      p_attended_on,
      p_idempotency_key
    );
  exception
    when unique_violation then
      raise exception using
        errcode = '23505',
        message = 'Uma das OS informadas já está vinculada a outro atendimento desta loja.';
  end;

  v_attendance_id := nullif(
    coalesce(
      v_response -> 'attendance' ->> 'id',
      v_response -> 'record' ->> 'id'
    ),
    ''
  )::uuid;
  if v_attendance_id is null then
    raise exception 'Não foi possível identificar o atendimento registrado.';
  end if;

  select attendance.store_id, attendance.admin_user_id
  into v_store_id, v_admin_user_id
  from public.attendances attendance
  where attendance.id = v_attendance_id
  for update;

  v_replay := coalesce((v_response ->> 'idempotent_replay')::boolean, false);
  v_existing_orders := app_private.attendance_service_orders_json(v_attendance_id);

  perform app_private.assert_attendance_service_orders_available(
    v_store_id,
    v_attendance_id,
    v_orders
  );

  if v_replay and v_existing_orders is distinct from v_orders then
    raise exception using
      errcode = '23505',
      message = 'Esta chave de registro já foi usada com uma lista de OS diferente.';
  end if;

  if not v_replay then
    perform app_private.replace_attendance_service_orders(
      v_attendance_id,
      v_store_id,
      v_admin_user_id,
      v_orders
    );
  end if;

  return app_private.attendance_result_v4(v_attendance_id, v_replay);
end;
$$;

create or replace function public.lc_upsert_attendance_v4(
  p_session_token text,
  p_store_id uuid,
  p_professional_name text,
  p_customer_name text,
  p_phone text,
  p_cpf text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_service_orders jsonb,
  p_attended_on date,
  p_idempotency_key text default null
)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$
  select app_private.rpc_upsert_attendance_v4(
    p_session_token,
    p_store_id,
    p_professional_name,
    p_customer_name,
    p_phone,
    p_cpf,
    p_description,
    p_tag,
    p_service_value,
    p_service_orders,
    p_attended_on,
    p_idempotency_key
  );
$$;

-- Clientes que ainda usam o contrato V3 entram na mesma hierarquia global
-- de locks da V4/V2/cancelamento. Sem este guard, uma gravacao legada poderia
-- bloquear uma linha pela OS enquanto uma edicao nova aguardava a mesma OS.
create or replace function app_private.rpc_upsert_attendance_v3_required_date(
  p_session_token text,
  p_store_id uuid,
  p_professional_name text,
  p_customer_name text,
  p_phone text,
  p_cpf text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_purchase_value numeric,
  p_service_order text,
  p_attended_on date,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_store_id uuid;
begin
  if p_attended_on is null then
    raise exception using
      errcode = '22004',
      message = 'Informe a data em que o atendimento aconteceu.';
  end if;

  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente não pode registrar atendimento em outra loja.';
    end if;
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if v_store_id is null then
    raise exception 'Selecione o cliente do atendimento.';
  end if;
  if not app_private.attendance_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'attendance:store-edit:' || v_store_id::text,
      0
    )
  );

  return app_private.rpc_upsert_attendance_v3(
    p_session_token,
    v_store_id,
    p_professional_name,
    p_customer_name,
    p_phone,
    p_cpf,
    p_description,
    p_tag,
    p_service_value,
    p_purchase_value,
    p_service_order,
    p_attended_on,
    p_idempotency_key
  );
end;
$$;

-- Resolve o tenant antes do lock. Em especial, uma loja pode chamar os RPCs
-- legados com p_store_id nulo; nesse caso o escopo correto continua sendo a
-- loja da sessão, nunca uma chave vazia ou controlada pelo cliente.
create or replace function app_private.lock_attendance_store_edit_for_session(
  p_session_token text,
  p_store_id uuid
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_store_id uuid;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente não pode registrar atendimento em outra loja.';
    end if;
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if v_store_id is null then
    raise exception 'Selecione o cliente do atendimento.';
  end if;
  if not app_private.attendance_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'attendance:store-edit:' || v_store_id::text,
      0
    )
  );

  return v_store_id;
end;
$$;

-- Os contratos V1/V2 permanecem disponíveis para versões em cache, mas o
-- único caminho exposto passa pelo mesmo lock global de V3/V4/update/cancel.
create or replace function app_private.rpc_upsert_attendance_v1_serialized(
  p_session_token text,
  p_store_id uuid,
  p_professional_name text,
  p_customer_name text,
  p_phone text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_purchase_value numeric,
  p_service_order text,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.lock_attendance_store_edit_for_session(
    p_session_token,
    p_store_id
  );

  return app_private.rpc_upsert_attendance(
    p_session_token,
    v_store_id,
    p_professional_name,
    p_customer_name,
    p_phone,
    p_description,
    p_tag,
    p_service_value,
    p_purchase_value,
    p_service_order,
    p_idempotency_key
  );
end;
$$;

create or replace function app_private.rpc_upsert_attendance_v2_serialized(
  p_session_token text,
  p_store_id uuid,
  p_professional_name text,
  p_customer_name text,
  p_phone text,
  p_cpf text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_purchase_value numeric,
  p_service_order text,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.lock_attendance_store_edit_for_session(
    p_session_token,
    p_store_id
  );

  return app_private.rpc_upsert_attendance_v2(
    p_session_token,
    v_store_id,
    p_professional_name,
    p_customer_name,
    p_phone,
    p_cpf,
    p_description,
    p_tag,
    p_service_value,
    p_purchase_value,
    p_service_order,
    p_idempotency_key
  );
end;
$$;

create or replace function public.lc_upsert_attendance(
  p_session_token text,
  p_store_id uuid,
  p_professional_name text,
  p_customer_name text,
  p_phone text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_purchase_value numeric,
  p_service_order text,
  p_idempotency_key text default null
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app_private.rpc_upsert_attendance_v1_serialized(
    p_session_token,
    p_store_id,
    p_professional_name,
    p_customer_name,
    p_phone,
    p_description,
    p_tag,
    p_service_value,
    p_purchase_value,
    p_service_order,
    p_idempotency_key
  );
$$;

create or replace function public.lc_upsert_attendance_v2(
  p_session_token text,
  p_store_id uuid,
  p_professional_name text,
  p_customer_name text,
  p_phone text,
  p_cpf text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_purchase_value numeric,
  p_service_order text,
  p_idempotency_key text default null
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app_private.rpc_upsert_attendance_v2_serialized(
    p_session_token,
    p_store_id,
    p_professional_name,
    p_customer_name,
    p_phone,
    p_cpf,
    p_description,
    p_tag,
    p_service_value,
    p_purchase_value,
    p_service_order,
    p_idempotency_key
  );
$$;

create or replace function app_private.rpc_update_attendance_v2(
  p_session_token text,
  p_attendance_id uuid,
  p_store_id uuid,
  p_professional_name text,
  p_attended_on date,
  p_customer_name text,
  p_phone text,
  p_cpf text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_service_orders jsonb,
  p_expected_updated_at timestamptz
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_existing public.attendances%rowtype;
  v_current public.attendances%rowtype;
  v_store_id uuid;
  v_tag text;
  v_orders jsonb;
  v_before_orders jsonb;
  v_total numeric(14,2);
  v_primary_order text;
  v_response jsonb;
  v_final jsonb;
  v_parent_updated boolean := false;
  v_response_updated boolean := false;
  v_parent_replay boolean := false;
  v_orders_changed boolean := false;
  v_previous_multi_order_setting text := coalesce(
    pg_catalog.current_setting('app_private.attendance_multi_order_write', true),
    ''
  );
begin
  if p_attendance_id is null then
    raise exception 'Informe o atendimento que será editado.';
  end if;
  if p_expected_updated_at is null then
    raise exception 'Atualize a lista antes de editar este atendimento.';
  end if;

  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente não pode editar atendimento de outra loja.';
    end if;
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if v_store_id is null or not app_private.attendance_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id
  ) then
    raise exception 'Atendimento não encontrado ou sem permissão.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('attendance:store-edit:' || v_store_id::text, 0)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('attendance:edit:' || p_attendance_id::text, 0)
  );

  select attendance.* into v_existing
  from public.attendances attendance
  where attendance.id = p_attendance_id
    and attendance.store_id = v_store_id
    and attendance.admin_user_id = v_session.admin_user_id
  for update;

  if not found then
    raise exception 'Atendimento não encontrado ou sem permissão.';
  end if;
  if v_existing.canceled_at is not null then
    raise exception 'Atendimento cancelado não pode ser editado.';
  end if;
  v_tag := app_private.attendance_normalize_tag(p_tag);
  if v_tag is null then
    raise exception 'Use a etiqueta Orçamento, Compra ou Outro.';
  end if;
  if v_tag = 'purchase' then
    v_orders := app_private.normalize_attendance_service_orders(
      p_service_orders,
      true
    );
    select
      pg_catalog.round(pg_catalog.sum((orders.value ->> 'amount')::numeric), 2),
      v_orders -> 0 ->> 'service_order'
    into v_total, v_primary_order
    from pg_catalog.jsonb_array_elements(v_orders) orders(value);
  else
    v_orders := app_private.normalize_attendance_service_orders(
      p_service_orders,
      false
    );
    if pg_catalog.jsonb_array_length(v_orders) > 0 then
      raise exception 'Ordens de serviço só podem ser informadas na etiqueta Compra.';
    end if;
    v_total := null;
    v_primary_order := null;
  end if;

  v_before_orders := app_private.attendance_service_orders_json(p_attendance_id);
  v_orders_changed := v_before_orders is distinct from v_orders;

  -- Um retry exato após perda de resposta mantém a idempotência do V1. Se a
  -- composição de OS mudou desde a versão esperada, o cliente deve recarregar
  -- em vez de sobrescrever silenciosamente uma edição concorrente.
  if p_expected_updated_at is distinct from v_existing.updated_at
     and v_orders_changed then
    raise exception 'Este atendimento foi alterado em outra tela. Recarregue a lista e tente novamente.';
  end if;

  perform app_private.lock_attendance_service_orders(v_store_id, v_orders);
  perform app_private.assert_attendance_service_orders_available(
    v_store_id,
    p_attendance_id,
    v_orders
  );

  perform pg_catalog.set_config(
    'app_private.attendance_multi_order_write',
    '1',
    true
  );

  begin
    v_response := app_private.rpc_update_attendance_v1(
      p_session_token,
      p_attendance_id,
      v_store_id,
      p_professional_name,
      p_attended_on,
      p_customer_name,
      p_phone,
      p_cpf,
      p_description,
      v_tag,
      p_service_value,
      v_total,
      v_primary_order,
      p_expected_updated_at
    );
  exception
    when unique_violation then
      raise exception using
        errcode = '23505',
        message = 'Uma das OS informadas já está vinculada a outro atendimento desta loja.';
  end;

  v_response_updated := coalesce((v_response ->> 'updated')::boolean, false);
  v_parent_replay := coalesce((v_response ->> 'edit_replay')::boolean, false);
  v_parent_updated := v_response_updated and not v_parent_replay;

  if v_parent_updated or v_orders_changed then
    perform app_private.replace_attendance_service_orders(
      p_attendance_id,
      v_store_id,
      v_session.admin_user_id,
      v_orders
    );
  end if;

  -- Uma alteração apenas na segunda/terceira OS não muda o payload legado.
  -- Ainda assim, ela ganha nova versão otimista e entra no histórico privado.
  if v_orders_changed and not v_parent_updated then
    update public.attendances attendance
    set updated_by = v_session.user_id,
        edit_count = attendance.edit_count + 1,
        updated_at = pg_catalog.clock_timestamp()
    where attendance.id = p_attendance_id
      and attendance.store_id = v_store_id
      and attendance.admin_user_id = v_session.admin_user_id;
  end if;

  select attendance.* into v_current
  from public.attendances attendance
  where attendance.id = p_attendance_id;

  if v_orders_changed then
    insert into app_private.attendance_service_order_audit (
      attendance_id,
      admin_user_id,
      store_id,
      edit_number,
      expected_updated_at,
      before_orders,
      after_orders,
      changed_by
    ) values (
      p_attendance_id,
      v_session.admin_user_id,
      v_store_id,
      v_current.edit_count,
      p_expected_updated_at,
      v_before_orders,
      v_orders,
      v_session.user_id
    );
  end if;

  v_final := app_private.attendance_result_v4(p_attendance_id, false);
  perform pg_catalog.set_config(
    'app_private.attendance_multi_order_write',
    v_previous_multi_order_setting,
    true
  );
  return v_final || pg_catalog.jsonb_build_object(
    'message', case
      when v_orders_changed and not v_parent_updated
        then 'Ordens de serviço atualizadas com sucesso.'
      else coalesce(v_response ->> 'message', 'Atendimento atualizado com sucesso.')
    end,
    'mensagem', case
      when v_orders_changed and not v_parent_updated
        then 'Ordens de serviço atualizadas com sucesso.'
      else coalesce(v_response ->> 'mensagem', 'Atendimento atualizado com sucesso.')
    end,
    'updated', case
      when v_orders_changed then true else v_response_updated
    end,
    'edit_replay', v_parent_replay and not v_orders_changed,
    'changed_fields', case
      when v_orders_changed then coalesce(v_response -> 'changed_fields', '[]'::jsonb)
        || pg_catalog.jsonb_build_array('service_orders')
      else coalesce(v_response -> 'changed_fields', '[]'::jsonb)
    end
  );
end;
$$;

create or replace function public.lc_update_attendance_v2(
  p_session_token text,
  p_attendance_id uuid,
  p_store_id uuid,
  p_professional_name text,
  p_attended_on date,
  p_customer_name text,
  p_phone text,
  p_cpf text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_service_orders jsonb,
  p_expected_updated_at timestamptz
)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$
  select app_private.rpc_update_attendance_v2(
    p_session_token,
    p_attendance_id,
    p_store_id,
    p_professional_name,
    p_attended_on,
    p_customer_name,
    p_phone,
    p_cpf,
    p_description,
    p_tag,
    p_service_value,
    p_service_orders,
    p_expected_updated_at
  );
$$;

create index if not exists attendances_store_canceled_date_idx
  on public.attendances (store_id, canceled_at desc, attended_at desc)
  where canceled_at is not null;

create table if not exists app_private.attendance_service_orders (
  id bigint generated always as identity primary key,
  attendance_id uuid not null,
  store_id uuid not null,
  admin_user_id uuid not null,
  position smallint not null,
  service_order text not null,
  service_order_key text generated always as (
    pg_catalog.lower(pg_catalog.btrim(service_order))
  ) stored,
  amount numeric(14,2) not null,
  canceled_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint attendance_service_orders_attendance_fk
    foreign key (attendance_id, store_id, admin_user_id)
    references public.attendances (id, store_id, admin_user_id)
    on delete cascade,
  constraint attendance_service_orders_position_check
    check (position between 1 and 12),
  constraint attendance_service_orders_number_check
    check (
      char_length(pg_catalog.btrim(service_order)) between 1 and 120
      and service_order = pg_catalog.btrim(service_order)
    ),
  constraint attendance_service_orders_amount_check
    check (amount > 0 and amount <= 999999999999.99),
  constraint attendance_service_orders_position_unique
    unique (attendance_id, position),
  constraint attendance_service_orders_number_unique
    unique (attendance_id, service_order_key)
);

create unique index if not exists attendance_service_orders_store_active_uidx
  on app_private.attendance_service_orders (store_id, service_order_key)
  where canceled_at is null;

create index if not exists attendance_service_orders_attendance_idx
  on app_private.attendance_service_orders (attendance_id, position);

alter table app_private.attendance_service_orders enable row level security;
alter table app_private.attendance_service_orders force row level security;
revoke all on table app_private.attendance_service_orders
  from public, anon, authenticated;
grant select, insert, update, delete
  on table app_private.attendance_service_orders to service_role;
revoke all on sequence app_private.attendance_service_orders_id_seq
  from public, anon, authenticated;
grant usage, select on sequence app_private.attendance_service_orders_id_seq
  to service_role;

-- Toda compra antiga passa a ter exatamente uma OS normalizada. O índice
-- legado garante que o backfill não contenha duplicidade por loja.
insert into app_private.attendance_service_orders (
  attendance_id,
  store_id,
  admin_user_id,
  position,
  service_order,
  amount
)
select
  attendance.id,
  attendance.store_id,
  attendance.admin_user_id,
  1,
  pg_catalog.btrim(attendance.service_order),
  pg_catalog.round(attendance.purchase_value, 2)
from public.attendances attendance
where attendance.tag = 'purchase'
  and attendance.purchase_value > 0
  and nullif(pg_catalog.btrim(attendance.service_order), '') is not null
on conflict (attendance_id, position) do nothing;

create table if not exists app_private.attendance_service_order_audit (
  id uuid primary key default extensions.gen_random_uuid(),
  attendance_id uuid not null,
  admin_user_id uuid not null,
  store_id uuid not null,
  edit_number bigint not null,
  expected_updated_at timestamptz,
  before_orders jsonb not null,
  after_orders jsonb not null,
  changed_by uuid not null,
  changed_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint attendance_service_order_audit_orders_check check (
    pg_catalog.jsonb_typeof(before_orders) = 'array'
    and pg_catalog.jsonb_typeof(after_orders) = 'array'
  )
);

create index if not exists attendance_service_order_audit_attendance_idx
  on app_private.attendance_service_order_audit
    (attendance_id, changed_at desc);

create table if not exists app_private.attendance_cancellation_audit (
  id uuid primary key default extensions.gen_random_uuid(),
  attendance_id uuid not null unique,
  admin_user_id uuid not null,
  store_id uuid not null,
  attended_on date not null,
  reason text,
  before_state jsonb not null,
  after_state jsonb not null,
  reconciliation jsonb not null default '{}'::jsonb,
  response jsonb not null,
  canceled_by uuid not null,
  canceled_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint attendance_cancellation_audit_reason_check
    check (char_length(coalesce(reason, '')) <= 500)
);

create index if not exists attendance_cancellation_audit_store_date_idx
  on app_private.attendance_cancellation_audit
    (store_id, canceled_at desc);

alter table app_private.attendance_service_order_audit enable row level security;
alter table app_private.attendance_service_order_audit force row level security;
alter table app_private.attendance_cancellation_audit enable row level security;
alter table app_private.attendance_cancellation_audit force row level security;

revoke all on table app_private.attendance_service_order_audit,
  app_private.attendance_cancellation_audit
  from public, anon, authenticated, service_role;
grant select on table app_private.attendance_service_order_audit,
  app_private.attendance_cancellation_audit to service_role;

create or replace function app_private.prevent_attendance_history_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'O histórico de atendimentos é imutável.';
end;
$$;

drop trigger if exists attendance_service_order_audit_immutable
  on app_private.attendance_service_order_audit;
create trigger attendance_service_order_audit_immutable
before update or delete on app_private.attendance_service_order_audit
for each row execute function app_private.prevent_attendance_history_mutation();

drop trigger if exists attendance_cancellation_audit_immutable
  on app_private.attendance_cancellation_audit;
create trigger attendance_cancellation_audit_immutable
before update or delete on app_private.attendance_cancellation_audit
for each row execute function app_private.prevent_attendance_history_mutation();

create or replace function app_private.prevent_canceled_attendance_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if (
    old.canceled_at is not null
    or new.canceled_at is distinct from old.canceled_at
  ) and coalesce(
    pg_catalog.current_setting('app_private.attendance_cancel_write', true),
    ''
  ) <> '1' then
    raise exception 'Atendimento cancelado não pode ser alterado.';
  end if;

  if old.canceled_at is not null and new.canceled_at is null then
    raise exception 'O cancelamento de atendimento é permanente.';
  end if;

  return new;
end;
$$;

drop trigger if exists attendances_prevent_canceled_mutation
  on public.attendances;
create trigger attendances_prevent_canceled_mutation
before update on public.attendances
for each row execute function app_private.prevent_canceled_attendance_mutation();

create or replace function app_private.prevent_legacy_multiple_order_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(
       pg_catalog.current_setting(
         'app_private.attendance_multi_order_write',
         true
       ),
       ''
     ) <> '1'
     and coalesce(
       pg_catalog.current_setting('app_private.attendance_cancel_write', true),
       ''
     ) <> '1'
     and (
       select pg_catalog.count(*)
       from app_private.attendance_service_orders service_orders
       where service_orders.attendance_id = old.id
         and service_orders.canceled_at is null
     ) > 1 then
    raise exception
      'Este atendimento possui várias OS. Reabra a tela atualizada para editá-lo com segurança.';
  end if;
  return new;
end;
$$;

drop trigger if exists attendances_protect_multiple_orders
  on public.attendances;
create trigger attendances_protect_multiple_orders
before update of tag, purchase_value, service_order on public.attendances
for each row execute function app_private.prevent_legacy_multiple_order_update();

create or replace function app_private.sync_attendance_service_orders()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.canceled_at is not null then
    update app_private.attendance_service_orders service_orders
    set canceled_at = new.canceled_at,
        updated_at = pg_catalog.clock_timestamp()
    where service_orders.attendance_id = new.id
      and service_orders.canceled_at is distinct from new.canceled_at;
  elsif new.tag = 'purchase'
      and new.purchase_value > 0
      and nullif(pg_catalog.btrim(new.service_order), '') is not null then
    delete from app_private.attendance_service_orders service_orders
    where service_orders.attendance_id = new.id;

    insert into app_private.attendance_service_orders (
      attendance_id,
      store_id,
      admin_user_id,
      position,
      service_order,
      amount
    ) values (
      new.id,
      new.store_id,
      new.admin_user_id,
      1,
      pg_catalog.btrim(new.service_order),
      pg_catalog.round(new.purchase_value, 2)
    );
  else
    delete from app_private.attendance_service_orders service_orders
    where service_orders.attendance_id = new.id;
  end if;

  return new;
end;
$$;

drop trigger if exists attendances_sync_service_orders
  on public.attendances;
create trigger attendances_sync_service_orders
after insert or update of tag, purchase_value, service_order, canceled_at
on public.attendances
for each row execute function app_private.sync_attendance_service_orders();

create or replace function app_private.normalize_attendance_service_orders(
  p_service_orders jsonb,
  p_required boolean default false
)
returns jsonb
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_orders jsonb := coalesce(p_service_orders, '[]'::jsonb);
  v_item jsonb;
  v_order text;
  v_order_key text;
  v_amount numeric(14,2);
  v_seen text[] := array[]::text[];
  v_result jsonb := '[]'::jsonb;
  v_count integer;
  v_total numeric := 0;
begin
  if pg_catalog.jsonb_typeof(v_orders) <> 'array' then
    raise exception using
      errcode = '22023',
      message = 'As ordens de serviço devem ser enviadas em uma lista.';
  end if;

  v_count := pg_catalog.jsonb_array_length(v_orders);
  if p_required and v_count = 0 then
    raise exception using
      errcode = '22023',
      message = 'Adicione ao menos uma OS para registrar a compra.';
  end if;
  if v_count > 12 then
    raise exception using
      errcode = '22023',
      message = 'Um atendimento pode ter no máximo 12 ordens de serviço.';
  end if;

  for v_item in
    select items.value
    from pg_catalog.jsonb_array_elements(v_orders) items(value)
  loop
    if pg_catalog.jsonb_typeof(v_item) <> 'object' then
      raise exception using
        errcode = '22023',
        message = 'Cada OS deve informar número e valor.';
    end if;

    v_order := pg_catalog.btrim(coalesce(v_item ->> 'service_order', ''));
    if char_length(v_order) < 1 or char_length(v_order) > 120 then
      raise exception using
        errcode = '22023',
        message = 'Informe um número de OS com até 120 caracteres.';
    end if;
    v_order_key := pg_catalog.lower(v_order);
    if v_order_key = any(v_seen) then
      raise exception using
        errcode = '23505',
        message = 'A mesma OS foi adicionada mais de uma vez.';
    end if;

    begin
      v_amount := pg_catalog.round((v_item ->> 'amount')::numeric, 2);
    exception
      when invalid_text_representation or numeric_value_out_of_range then
        raise exception using
          errcode = '22023',
          message = 'Informe um valor válido para cada OS.';
    end;

    if v_amount is null or v_amount <= 0 then
      raise exception using
        errcode = '22023',
        message = 'O valor de cada OS deve ser maior que zero.';
    end if;

    v_total := v_total + v_amount;
    if v_total > 999999999999.99 then
      raise exception using
        errcode = '22003',
        message = 'O valor total das OS está fora do limite permitido.';
    end if;

    v_seen := pg_catalog.array_append(v_seen, v_order_key);
    v_result := v_result || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'service_order', v_order,
        'amount', v_amount
      )
    );
  end loop;

  return v_result;
end;
$$;

-- O resumo push diário também ignora cancelados no numerador e denominador.
create or replace function app_private.build_daily_report_payload(
  p_store_id uuid,
  p_admin_user_id uuid,
  p_report_local_date date,
  p_time_zone text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_store_name text;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_revenue_cents bigint := 0;
  v_attendances bigint := 0;
  v_sales bigint := 0;
  v_prospections bigint := 0;
  v_converted_prospections bigint := 0;
  v_conversion_rate numeric := 0;
begin
  if not app_private.daily_report_valid_time_zone(p_time_zone) then
    raise exception 'Fuso do relatorio diario invalido.';
  end if;

  select store_record.name
  into v_store_name
  from public.stores store_record
  where store_record.id = p_store_id
    and store_record.admin_user_id = p_admin_user_id
    and store_record.is_active = true;

  if not found then
    raise exception 'Loja do relatorio diario nao encontrada.';
  end if;

  v_day_start := p_report_local_date::timestamp at time zone p_time_zone;
  v_day_end := (p_report_local_date + 1)::timestamp at time zone p_time_zone;

  -- Um unico recorte garante que faturamento, atendimentos e vendas usem
  -- exatamente a mesma loja, data operacional e fuso horario.
  select
    pg_catalog.count(*)::bigint,
    pg_catalog.count(*) filter (
      where attendance.tag = 'purchase'
    )::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round(attendance.purchase_value * 100)::bigint
    ) filter (
      where attendance.tag = 'purchase'
        and attendance.purchase_value > 0
    ), 0)::bigint
  into v_attendances, v_sales, v_revenue_cents
  from public.attendances attendance
  where attendance.store_id = p_store_id
    and attendance.admin_user_id = p_admin_user_id
    and attendance.canceled_at is null
    and attendance.attended_at >= v_day_start
    and attendance.attended_at < v_day_end;

  select
    pg_catalog.count(*)::bigint,
    pg_catalog.count(*) filter (
      where prospection.purchased_at is not null
    )::bigint
  into v_prospections, v_converted_prospections
  from public.prospections prospection
  where prospection.store_id = p_store_id
    and prospection.admin_user_id = p_admin_user_id
    and prospection.created_at >= v_day_start
    and prospection.created_at < v_day_end;

  if v_attendances > 0 then
    v_conversion_rate := pg_catalog.round(
      (v_sales::numeric / v_attendances::numeric) * 100,
      1
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'store_id', p_store_id,
    'store_name', v_store_name,
    'report_date', p_report_local_date,
    'time_zone', p_time_zone,
    'revenue_cents', v_revenue_cents,
    'prospections', v_prospections,
    'converted_prospections', v_converted_prospections,
    'attendances', v_attendances,
    'sales', v_sales,
    'conversion_rate', v_conversion_rate,
    'url', './?module=attendances'
  );
end;
$$;

create or replace function app_private.attendance_service_orders_json(
  p_attendance_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'service_order', service_orders.service_order,
        'amount', service_orders.amount
      )
      order by service_orders.position
    ),
    '[]'::jsonb
  )
  from app_private.attendance_service_orders service_orders
  where service_orders.attendance_id = p_attendance_id;
$$;

create or replace function app_private.attendance_result_v4(
  p_attendance_id uuid,
  p_idempotent_replay boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_record jsonb;
  v_attendance public.attendances%rowtype;
  v_orders jsonb;
  v_effective_tag text;
  v_effective_service_value numeric(14,2);
  v_effective_purchase_value numeric(14,2);
  v_effective_service_order text;
  v_canceled_by_name text;
  v_links jsonb;
begin
  v_result := app_private.attendance_result_with_identity(
    p_attendance_id,
    p_idempotent_replay
  );
  if v_result is null then
    return null;
  end if;

  select attendance.* into v_attendance
  from public.attendances attendance
  where attendance.id = p_attendance_id;

  v_orders := app_private.attendance_service_orders_json(p_attendance_id);
  if v_attendance.canceled_by is not null then
    select coalesce(
      nullif(pg_catalog.btrim(users.full_name), ''),
      nullif(pg_catalog.btrim(users.nick), '')
    )
    into v_canceled_by_name
    from public.app_users users
    where users.id = v_attendance.canceled_by
      and (
        users.id = v_attendance.admin_user_id
        or users.admin_user_id = v_attendance.admin_user_id
      );
  end if;
  v_effective_tag := case
    when v_attendance.canceled_at is null then v_attendance.tag
    else v_attendance.canceled_original_tag
  end;
  v_effective_service_value := case
    when v_attendance.canceled_at is null then v_attendance.service_value
    else v_attendance.canceled_original_service_value
  end;
  v_effective_purchase_value := case
    when v_attendance.canceled_at is null then v_attendance.purchase_value
    else v_attendance.canceled_original_purchase_value
  end;
  v_effective_service_order := case
    when v_attendance.canceled_at is null then v_attendance.service_order
    else v_attendance.canceled_original_service_order
  end;

  v_links := coalesce(v_result -> 'links', '{}'::jsonb);
  if v_attendance.canceled_at is not null then
    v_links := pg_catalog.jsonb_build_object(
      'status', coalesce(v_attendance.canceled_original_match_status, 'unmatched'),
      'historical', true,
      'active', false,
      'lead', case when v_attendance.canceled_original_lead_id is null then null else (
        select pg_catalog.jsonb_build_object(
          'id', leads.id,
          'name', leads.name,
          'phone', leads.phone,
          'visit_applied', false,
          'purchase_applied', false,
          'historical', true
        )
        from public.leads leads
        where leads.id = v_attendance.canceled_original_lead_id
          and leads.store_id = v_attendance.store_id
          and leads.admin_user_id = v_attendance.admin_user_id
      ) end,
      'prospection', case
        when v_attendance.canceled_original_prospection_id is null then null
        else (
          select pg_catalog.jsonb_build_object(
            'id', prospections.id,
            'name', prospections.name,
            'phone', prospections.phone,
            'return_applied', false,
            'purchase_applied', false,
            'historical', true
          )
          from public.prospections prospections
          where prospections.id = v_attendance.canceled_original_prospection_id
            and prospections.store_id = v_attendance.store_id
            and prospections.admin_user_id = v_attendance.admin_user_id
        )
      end
    );
  end if;

  v_record := coalesce(v_result -> 'attendance', '{}'::jsonb)
    || pg_catalog.jsonb_build_object(
      'tag', v_effective_tag,
      'tag_label', case v_effective_tag
        when 'budget' then 'Orçamento'
        when 'purchase' then 'Compra'
        else 'Outro'
      end,
      'service_value', v_effective_service_value,
      'purchase_value', v_effective_purchase_value,
      'service_order', v_effective_service_order,
      'service_orders', v_orders,
      'canceled', v_attendance.canceled_at is not null,
      'cancelled', v_attendance.canceled_at is not null,
      'canceled_at', v_attendance.canceled_at,
      'cancelled_at', v_attendance.canceled_at,
      'canceled_by', v_attendance.canceled_by,
      'canceled_by_name', v_canceled_by_name,
      'cancellation_reason', v_attendance.cancellation_reason,
      'original_tag', v_attendance.canceled_original_tag,
      'original_service_value', v_attendance.canceled_original_service_value,
      'original_purchase_value', v_attendance.canceled_original_purchase_value,
      'original_service_order', v_attendance.canceled_original_service_order,
      'original_lead_id', v_attendance.canceled_original_lead_id,
      'original_prospection_id', v_attendance.canceled_original_prospection_id,
      'original_match_status', v_attendance.canceled_original_match_status,
      'historical_links', case
        when v_attendance.canceled_at is null then null else v_links
      end,
      'editable', v_attendance.canceled_at is null,
      'cancelable', v_attendance.canceled_at is null
    );

  return v_result || pg_catalog.jsonb_build_object(
    'attendance', v_record,
    'record', v_record,
    'registro', v_record,
    'links', v_links,
    'vinculos', v_links,
    'service_orders', v_orders,
    'canceled', v_attendance.canceled_at is not null,
    'cancelled', v_attendance.canceled_at is not null,
    'canceled_at', v_attendance.canceled_at,
    'cancellation_reason', v_attendance.cancellation_reason,
    'expected_updated_at', v_attendance.updated_at,
    'edit_count', v_attendance.edit_count
  );
end;
$$;

create or replace function app_private.rpc_cancel_attendance_v1(
  p_session_token text,
  p_attendance_id uuid,
  p_store_id uuid,
  p_expected_updated_at timestamptz,
  p_reason text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_existing public.attendances%rowtype;
  v_current public.attendances%rowtype;
  v_store_id uuid;
  v_reason text := nullif(left(pg_catalog.btrim(coalesce(p_reason, '')), 500), '');
  v_cancelled_at timestamptz := pg_catalog.clock_timestamp();
  v_marked_updated_at timestamptz;
  v_before_orders jsonb;
  v_before_state jsonb;
  v_after_state jsonb;
  v_reconciliation jsonb := '{}'::jsonb;
  v_decision jsonb;
  v_response jsonb;
  v_previous_cancel_setting text := coalesce(
    pg_catalog.current_setting('app_private.attendance_cancel_write', true),
    ''
  );
begin
  if p_attendance_id is null then
    raise exception 'Informe o atendimento que será cancelado.';
  end if;
  if p_expected_updated_at is null then
    raise exception 'Atualize a lista antes de cancelar este atendimento.';
  end if;

  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente não pode cancelar atendimento de outra loja.';
    end if;
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if v_store_id is null or not app_private.attendance_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id
  ) then
    raise exception 'Atendimento não encontrado ou sem permissão.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('attendance:store-edit:' || v_store_id::text, 0)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('attendance:edit:' || p_attendance_id::text, 0)
  );

  select attendance.* into v_existing
  from public.attendances attendance
  where attendance.id = p_attendance_id
    and attendance.store_id = v_store_id
    and attendance.admin_user_id = v_session.admin_user_id
  for update;

  if not found then
    raise exception 'Atendimento não encontrado ou sem permissão.';
  end if;

  if v_existing.canceled_at is not null then
    return app_private.attendance_result_v4(p_attendance_id, true)
      || pg_catalog.jsonb_build_object(
        'message', 'Este atendimento já estava cancelado.',
        'mensagem', 'Este atendimento já estava cancelado.',
        'canceled', true,
        'cancelled', true,
        'cancellation_replay', true
      );
  end if;

  if p_expected_updated_at is distinct from v_existing.updated_at then
    raise exception 'Este atendimento foi alterado em outra tela. Recarregue a lista e tente novamente.';
  end if;

  v_before_orders := app_private.attendance_service_orders_json(p_attendance_id);
  v_before_state := pg_catalog.jsonb_build_object(
    'attendance', to_jsonb(v_existing),
    'service_orders', v_before_orders,
    'lead', case when v_existing.lead_id is null then null else (
      select to_jsonb(leads)
      from public.leads leads
      where leads.id = v_existing.lead_id
        and leads.store_id = v_store_id
        and leads.admin_user_id = v_session.admin_user_id
    ) end,
    'prospection', case when v_existing.prospection_id is null then null else (
      select to_jsonb(prospections)
      from public.prospections prospections
      where prospections.id = v_existing.prospection_id
        and prospections.store_id = v_store_id
        and prospections.admin_user_id = v_session.admin_user_id
    ) end
  );

  perform pg_catalog.set_config(
    'app_private.attendance_cancel_write',
    '1',
    true
  );

  -- Primeiro congela o snapshot. O trigger libera todas as OS para que elas
  -- possam ser usadas por uma venda válida, sem apagar o histórico cancelado.
  update public.attendances attendance
  set canceled_at = v_cancelled_at,
      canceled_by = v_session.user_id,
      cancellation_reason = v_reason,
      canceled_original_tag = attendance.tag,
      canceled_original_service_value = attendance.service_value,
      canceled_original_purchase_value = attendance.purchase_value,
      canceled_original_service_order = attendance.service_order,
      canceled_original_idempotency_key = attendance.idempotency_key,
      canceled_original_lead_id = attendance.lead_id,
      canceled_original_prospection_id = attendance.prospection_id,
      canceled_original_match_status = attendance.match_status,
      metadata = attendance.metadata || pg_catalog.jsonb_build_object(
        'canceled_at', v_cancelled_at,
        'canceled_by', v_session.user_id,
        'cancellation_reason', v_reason
      ),
      updated_by = v_session.user_id,
      updated_at = v_cancelled_at
  where attendance.id = p_attendance_id
  returning attendance.updated_at into v_marked_updated_at;

  -- A transição pelo motor V1 reverte compra, bônus e owners financeiros com
  -- as mesmas regras já utilizadas numa edição comum.
  perform app_private.rpc_update_attendance_v1(
    p_session_token,
    p_attendance_id,
    v_store_id,
    v_existing.professional_name_snapshot,
    pg_catalog.timezone('America/Sao_Paulo', v_existing.attended_at)::date,
    v_existing.customer_name,
    v_existing.phone,
    v_existing.customer_cpf,
    v_existing.description,
    'other',
    null::numeric,
    null::numeric,
    null::text,
    v_marked_updated_at
  );

  -- Remove o vínculo ativo antes de reconciliar visita/retorno. Dessa forma
  -- os helpers existentes promovem um sibling válido e nunca voltam a eleger
  -- um cancelado (todos os cancelados ficam sem lead_id/prospection_id ativos).
  update public.attendances attendance
  set lead_id = null,
      prospection_id = null,
      match_status = 'unmatched',
      lead_match_count = 0,
      prospection_match_count = 0,
      match_ambiguous = false,
      lead_visit_applied = false,
      lead_purchase_applied = false,
      prospection_visit_applied = false,
      prospection_purchase_applied = false,
      purchase_credit_applied = false,
      credited_professional_id = null,
      credited_professional_name_snapshot = null,
      bonus_eligible = false,
      bonus_awarded_amount = 0,
      bonus_credit_status = 'not_applicable',
      updated_by = v_session.user_id,
      edit_count = v_existing.edit_count + 1,
      updated_at = pg_catalog.clock_timestamp()
  where attendance.id = p_attendance_id;

  if v_existing.lead_id is not null then
    v_decision := app_private.reconcile_lead_from_attendances(
      v_existing.lead_id,
      v_session.admin_user_id,
      v_store_id,
      p_attendance_id,
      v_session.user_id,
      true,
      true,
      false
    );
    v_reconciliation := v_reconciliation
      || pg_catalog.jsonb_build_object('lead', v_decision);
  end if;

  if v_existing.prospection_id is not null then
    v_decision := app_private.reconcile_prospection_from_attendances(
      v_existing.prospection_id,
      v_session.admin_user_id,
      v_store_id,
      p_attendance_id,
      v_session.user_id,
      true,
      true,
      false
    );
    v_reconciliation := v_reconciliation
      || pg_catalog.jsonb_build_object('prospection', v_decision);
  end if;

  -- A primeira configuração do mês guarda um snapshot do realizado. Uma OS
  -- anterior ao cutoff precisa ser retirada também desse snapshot, não apenas
  -- das somas ao vivo.
  update public.good_morning_seller_settings settings
  set goal_configuration_actuals_cents =
        app_private.capture_good_morning_actuals_cents(
          settings.store_id,
          settings.admin_user_id,
          pg_catalog.timezone(
            'America/Sao_Paulo', settings.goal_configured_at
          )::date,
          settings.goal_configured_at
        ),
      updated_by = v_session.user_id
  where settings.store_id = v_store_id
    and settings.admin_user_id = v_session.admin_user_id
    and settings.goal_configured_at is not null
    and settings.goal_month = pg_catalog.date_trunc(
      'month',
      pg_catalog.timezone('America/Sao_Paulo', v_existing.attended_at)::date
    )::date;

  select attendance.* into v_current
  from public.attendances attendance
  where attendance.id = p_attendance_id;

  v_response := app_private.attendance_result_v4(p_attendance_id, false)
    || pg_catalog.jsonb_build_object(
      'message', 'Atendimento cancelado e retirado dos resultados do mês.',
      'mensagem', 'Atendimento cancelado e retirado dos resultados do mês.',
      'canceled', true,
      'cancelled', true,
      'cancellation_replay', false,
      'reconciliation', v_reconciliation
    );

  v_after_state := pg_catalog.jsonb_build_object(
    'attendance', to_jsonb(v_current),
    'service_orders', app_private.attendance_service_orders_json(p_attendance_id),
    'lead', case when v_existing.lead_id is null then null else (
      select to_jsonb(leads)
      from public.leads leads
      where leads.id = v_existing.lead_id
        and leads.store_id = v_store_id
        and leads.admin_user_id = v_session.admin_user_id
    ) end,
    'prospection', case when v_existing.prospection_id is null then null else (
      select to_jsonb(prospections)
      from public.prospections prospections
      where prospections.id = v_existing.prospection_id
        and prospections.store_id = v_store_id
        and prospections.admin_user_id = v_session.admin_user_id
    ) end
  );

  insert into app_private.attendance_cancellation_audit (
    attendance_id,
    admin_user_id,
    store_id,
    attended_on,
    reason,
    before_state,
    after_state,
    reconciliation,
    response,
    canceled_by,
    canceled_at
  ) values (
    p_attendance_id,
    v_session.admin_user_id,
    v_store_id,
    pg_catalog.timezone('America/Sao_Paulo', v_existing.attended_at)::date,
    v_reason,
    v_before_state,
    v_after_state,
    v_reconciliation,
    v_response,
    v_session.user_id,
    v_cancelled_at
  );

  perform pg_catalog.set_config(
    'app_private.attendance_cancel_write',
    v_previous_cancel_setting,
    true
  );

  return v_response;
end;
$$;

create or replace function public.lc_cancel_attendance_v1(
  p_session_token text,
  p_attendance_id uuid,
  p_store_id uuid,
  p_expected_updated_at timestamptz,
  p_reason text default null
)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$
  select app_private.rpc_cancel_attendance_v1(
    p_session_token,
    p_attendance_id,
    p_store_id,
    p_expected_updated_at,
    p_reason
  );
$$;

create or replace function app_private.rpc_list_attendances_v4(
  p_session_token text,
  p_store_id uuid default null,
  p_search text default null,
  p_tag text default null,
  p_professional_id uuid default null,
  p_professional_name text default null,
  p_link_status text default null,
  p_start_date date default null,
  p_end_date date default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_store_id uuid;
  v_search text := nullif(left(pg_catalog.btrim(coalesce(p_search, '')), 200), '');
  v_search_digits text := nullif(
    pg_catalog.regexp_replace(coalesce(p_search, ''), '[^0-9]', '', 'g'),
    ''
  );
  v_tag text;
  v_professional_name text := nullif(
    left(pg_catalog.btrim(coalesce(p_professional_name, '')), 200),
    ''
  );
  v_link_status text := pg_catalog.lower(
    nullif(pg_catalog.btrim(coalesce(p_link_status, '')), '')
  );
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_total bigint := 0;
  v_items jsonb := '[]'::jsonb;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente não pode consultar atendimentos de outra loja.';
    end if;
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if v_store_id is null then
    raise exception 'Selecione um cliente para consultar os atendimentos.';
  end if;
  if not app_private.attendance_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  if nullif(pg_catalog.btrim(coalesce(p_tag, '')), '') is not null
     and pg_catalog.lower(pg_catalog.btrim(p_tag)) <> 'all' then
    v_tag := app_private.attendance_normalize_tag(p_tag);
    if v_tag is null then
      raise exception 'Etiqueta de atendimento inválida.';
    end if;
  end if;

  if v_link_status is not null and v_link_status not in (
    'all', 'matched', 'standalone', 'review',
    'unmatched', 'lead', 'prospection', 'both'
  ) then
    raise exception 'Filtro de vínculo inválido.';
  end if;
  if p_start_date is not null and p_end_date is not null
     and p_start_date > p_end_date then
    raise exception 'Período inválido.';
  end if;

  with filtered as materialized (
    select attendance.id, attendance.attended_at
    from public.attendances attendance
    where attendance.store_id = v_store_id
      and attendance.admin_user_id = v_session.admin_user_id
      and attendance.attended_at >= pg_catalog.now() - interval '2 years'
      and (
        v_tag is null
        or (attendance.canceled_at is null and attendance.tag = v_tag)
        or (
          attendance.canceled_at is not null
          and attendance.canceled_original_tag = v_tag
        )
      )
      and (
        p_professional_id is null
        or attendance.professional_id = p_professional_id
      )
      and (
        v_professional_name is null
        or attendance.professional_name_snapshot = v_professional_name
      )
      and (
        p_start_date is null
        or attendance.attended_at >= (
          p_start_date::timestamp at time zone 'America/Sao_Paulo'
        )
      )
      and (
        p_end_date is null
        or attendance.attended_at < (
          (p_end_date + 1)::timestamp at time zone 'America/Sao_Paulo'
        )
      )
      and (
        v_link_status is null or v_link_status = 'all'
        or (v_link_status = 'matched' and attendance.match_status <> 'unmatched')
        or (
          v_link_status = 'standalone'
          and attendance.match_status = 'unmatched'
          and not attendance.match_ambiguous
        )
        or (v_link_status = 'review' and attendance.match_ambiguous)
        or (
          v_link_status in ('unmatched', 'lead', 'prospection', 'both')
          and attendance.match_status = v_link_status
        )
      )
      and (
        v_search is null
        or attendance.customer_name ilike '%' || v_search || '%'
        or attendance.description ilike '%' || v_search || '%'
        or attendance.professional_name_snapshot ilike '%' || v_search || '%'
        or coalesce(attendance.credited_professional_name_snapshot, '')
          ilike '%' || v_search || '%'
        or coalesce(
          attendance.service_order,
          attendance.canceled_original_service_order,
          ''
        ) ilike '%' || v_search || '%'
        or exists (
          select 1
          from app_private.attendance_service_orders service_orders
          where service_orders.attendance_id = attendance.id
            and service_orders.service_order ilike '%' || v_search || '%'
        )
        or (
          attendance.canceled_at is not null
          and 'cancelado cancelada cancelados canceladas'
            ilike '%' || v_search || '%'
        )
        or (
          v_search_digits is not null
          and (
            coalesce(attendance.phone_normalized, '')
              like '%' || v_search_digits || '%'
            or coalesce(attendance.cpf_normalized, '')
              like '%' || v_search_digits || '%'
          )
        )
      )
  ), page as (
    select filtered.id, filtered.attended_at
    from filtered
    order by filtered.attended_at desc, filtered.id desc
    limit v_limit offset v_offset
  )
  select
    (select pg_catalog.count(*) from filtered),
    coalesce(pg_catalog.jsonb_agg(
      (result.payload -> 'attendance')
        || pg_catalog.jsonb_build_object('links', result.payload -> 'links')
      order by page.attended_at desc, page.id desc
    ), '[]'::jsonb)
  into v_total, v_items
  from page
  cross join lateral (
    select app_private.attendance_result_v4(page.id, false) as payload
  ) result;

  return pg_catalog.jsonb_build_object(
    'store_id', v_store_id,
    'items', v_items,
    'attendances', v_items,
    'total', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'has_more', v_offset::bigint
      + pg_catalog.jsonb_array_length(v_items)::bigint < v_total
  );
end;
$$;

create or replace function public.lc_list_attendances_v4(
  p_session_token text,
  p_store_id uuid default null,
  p_search text default null,
  p_tag text default null,
  p_professional_id uuid default null,
  p_professional_name text default null,
  p_link_status text default null,
  p_start_date date default null,
  p_end_date date default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select app_private.rpc_list_attendances_v4(
    p_session_token,
    p_store_id,
    p_search,
    p_tag,
    p_professional_id,
    p_professional_name,
    p_link_status,
    p_start_date,
    p_end_date,
    p_limit,
    p_offset
  );
$$;

-- Cancelados permanecem no histórico, mas ficam fora de todo indicador
-- operacional (inclusive o denominador de conversão).
create or replace function app_private.attendance_metrics_json(
  p_admin_user_id uuid,
  p_store_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with windows(window_key, start_at) as (
    values
      ('today'::text, pg_catalog.date_trunc('day', pg_catalog.now())),
      ('7d'::text, pg_catalog.date_trunc('day', pg_catalog.now()) - interval '6 days'),
      ('30d'::text, pg_catalog.date_trunc('day', pg_catalog.now()) - interval '29 days'),
      ('all'::text, pg_catalog.now() - interval '2 years')
  ), effective_attendances as (
    select
      attendance.*,
      (
        prospections.attendance_purchase_source_id = attendance.id
        and (
          prospections.bonus_professional_id_snapshot is not null
          or prospections.professional_id is not null
          or nullif(pg_catalog.btrim(prospections.bonus_professional_name_snapshot), '') is not null
          or nullif(pg_catalog.btrim(prospections.professional_name_snapshot), '') is not null
        )
      ) as effective_purchase_credit,
      (
        prospections.attendance_purchase_source_id = attendance.id
        and coalesce(
          prospections.bonus_eligible_snapshot,
          (
            prospections.bonus_professional_id_snapshot is not null
            or prospections.professional_id is not null
            or nullif(pg_catalog.btrim(prospections.bonus_professional_name_snapshot), '') is not null
            or nullif(pg_catalog.btrim(prospections.professional_name_snapshot), '') is not null
          ) and coalesce(prospections.purchase_amount, 0)
            >= coalesce(
              prospections.bonus_minimum_snapshot,
              attendance.bonus_minimum_snapshot,
              300
            )
        )
      ) as effective_bonus_eligible,
      case
        when prospections.attendance_purchase_source_id = attendance.id
         and coalesce(
           prospections.bonus_eligible_snapshot,
           (
             prospections.bonus_professional_id_snapshot is not null
             or prospections.professional_id is not null
             or nullif(pg_catalog.btrim(prospections.bonus_professional_name_snapshot), '') is not null
             or nullif(pg_catalog.btrim(prospections.professional_name_snapshot), '') is not null
           ) and coalesce(prospections.purchase_amount, 0)
             >= coalesce(
               prospections.bonus_minimum_snapshot,
               attendance.bonus_minimum_snapshot,
               300
             )
         )
          then coalesce(
            prospections.bonus_awarded_amount_snapshot,
            prospections.bonus_amount_snapshot,
            attendance.bonus_amount_snapshot,
            20
          )
        else 0
      end::numeric(14,2) as effective_bonus_awarded_amount,
      case
        when prospections.attendance_purchase_source_id = attendance.id then
          coalesce(
            prospections.bonus_credit_status_snapshot,
            case
              when prospections.bonus_professional_id_snapshot is null
               and prospections.professional_id is null
               and nullif(pg_catalog.btrim(prospections.bonus_professional_name_snapshot), '') is null
               and nullif(pg_catalog.btrim(prospections.professional_name_snapshot), '') is null
                then 'missing_professional'
              when coalesce(prospections.purchase_amount, 0)
                >= coalesce(
                  prospections.bonus_minimum_snapshot,
                  attendance.bonus_minimum_snapshot,
                  300
                ) then 'awarded'
              else 'below_minimum'
            end
          )
        else attendance.bonus_credit_status
      end as effective_bonus_credit_status
    from public.attendances attendance
    left join public.prospections prospections
      on prospections.id = attendance.prospection_id
     and prospections.store_id = attendance.store_id
     and prospections.admin_user_id = attendance.admin_user_id
    where attendance.admin_user_id = p_admin_user_id
      and attendance.store_id = p_store_id
      and attendance.canceled_at is null
      and attendance.attended_at >= pg_catalog.now() - interval '2 years'
  ), stats as (
    select
      windows.window_key,
      windows.start_at,
      count(attendance.id)::bigint as total,
      count(attendance.id) filter (where attendance.tag = 'budget')::bigint as budgets,
      count(attendance.id) filter (where attendance.tag = 'purchase')::bigint as purchases,
      count(attendance.id) filter (where attendance.tag = 'other')::bigint as others,
      coalesce(
        sum(attendance.purchase_value) filter (where attendance.tag = 'purchase'),
        0
      )::numeric(14,2) as purchase_revenue,
      coalesce(sum(attendance.service_value), 0)::numeric(14,2) as service_value,
      count(attendance.id) filter (where attendance.match_status <> 'unmatched')::bigint as linked,
      count(attendance.id) filter (where attendance.match_status = 'unmatched')::bigint as unmatched,
      count(attendance.id) filter (where attendance.match_ambiguous)::bigint as ambiguous,
      count(attendance.id) filter (
        where attendance.effective_purchase_credit
      )::bigint as purchase_credits,
      count(attendance.id) filter (
        where attendance.effective_bonus_eligible
      )::bigint as bonuses_awarded,
      coalesce(sum(attendance.effective_bonus_awarded_amount), 0)::numeric(14,2)
        as bonus_awarded_amount,
      count(attendance.id) filter (
        where attendance.effective_bonus_credit_status in (
          'ambiguous_prospection', 'missing_professional'
        )
      )::bigint as bonus_pending_review,
      count(distinct attendance.phone_normalized)::bigint as unique_customers,
      min(attendance.attended_at) as first_attendance_at,
      max(attendance.attended_at) as last_attendance_at
    from windows
    left join effective_attendances attendance
      on attendance.attended_at >= windows.start_at
    group by windows.window_key, windows.start_at
  )
  select coalesce(pg_catalog.jsonb_object_agg(
    stats.window_key,
    pg_catalog.jsonb_build_object(
      'start_at', stats.start_at,
      'total', stats.total,
      'budgets', stats.budgets,
      'purchases', stats.purchases,
      'others', stats.others,
      'conversion', case when stats.total = 0 then 0
        else pg_catalog.round((stats.purchases * 100.0) / stats.total, 2) end,
      'conversion_rate', case when stats.total = 0 then 0
        else pg_catalog.round((stats.purchases * 100.0) / stats.total, 2) end,
      'revenue', stats.purchase_revenue,
      'purchase_revenue', stats.purchase_revenue,
      'service_value', stats.service_value,
      'linked', stats.linked,
      'unmatched', stats.unmatched,
      'ambiguous', stats.ambiguous,
      'purchase_credits', stats.purchase_credits,
      'bonuses_awarded', stats.bonuses_awarded,
      'bonus_awarded_amount', stats.bonus_awarded_amount,
      'bonus_pending_review', stats.bonus_pending_review,
      'unique_customers', stats.unique_customers,
      'first_attendance_at', stats.first_attendance_at,
      'last_attendance_at', stats.last_attendance_at
    )
  ), '{}'::jsonb)
  from stats;
$$;

-- O painel analítico usa o mesmo conjunto ativo das métricas resumidas.
create or replace function app_private.rpc_get_attendance_analysis_v1(
  p_session_token text,
  p_store_id uuid default null,
  p_search text default null,
  p_tag text default null,
  p_professional_id uuid default null,
  p_professional_name text default null,
  p_link_status text default null,
  p_start_date date default null,
  p_end_date date default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_search text := nullif(left(btrim(coalesce(p_search, '')), 200), '');
  v_search_digits text := nullif(regexp_replace(coalesce(p_search, ''), '[^0-9]', '', 'g'), '');
  v_tag text;
  v_professional_name text := nullif(left(btrim(coalesce(p_professional_name, '')), 200), '');
  v_link_status text := lower(nullif(btrim(coalesce(p_link_status, '')), ''));
  v_result jsonb;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente não pode analisar atendimentos de outra loja.';
    end if;
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if v_store_id is null then
    raise exception 'Selecione um cliente para analisar os atendimentos.';
  end if;

  if not app_private.attendance_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  if nullif(btrim(coalesce(p_tag, '')), '') is not null
     and lower(btrim(p_tag)) <> 'all' then
    v_tag := app_private.attendance_normalize_tag(p_tag);
    if v_tag is null then
      raise exception 'Etiqueta de atendimento inválida.';
    end if;
  end if;

  if v_link_status is not null
     and v_link_status not in (
       'all', 'matched', 'standalone', 'review',
       'unmatched', 'lead', 'prospection', 'both'
     ) then
    raise exception 'Filtro de vínculo inválido.';
  end if;

  if p_start_date is not null
     and p_end_date is not null
     and p_start_date > p_end_date then
    raise exception 'Período inválido.';
  end if;

  with filtered as materialized (
    select
      a.id,
      a.professional_id,
      coalesce(nullif(btrim(a.professional_name_snapshot), ''), 'Não informado') as professional_name,
      a.tag,
      coalesce(a.purchase_value, 0)::numeric as purchase_value,
      coalesce(a.service_value, 0)::numeric as service_value,
      a.lead_id,
      a.prospection_id,
      a.match_status,
      a.match_ambiguous,
      coalesce(
        nullif(a.phone_normalized, ''),
        case when nullif(a.cpf_normalized, '') is not null then 'cpf:' || a.cpf_normalized end,
        'attendance:' || a.id::text
      ) as customer_key
    from public.attendances a
    where a.store_id = v_store_id
      and a.admin_user_id = v_session.admin_user_id
      and a.canceled_at is null
      and a.attended_at >= now() - interval '2 years'
      and (v_tag is null or a.tag = v_tag)
      and (p_professional_id is null or a.professional_id = p_professional_id)
      and (v_professional_name is null or a.professional_name_snapshot = v_professional_name)
      and (p_start_date is null or a.attended_at >= (p_start_date::timestamp at time zone 'America/Sao_Paulo'))
      and (p_end_date is null or a.attended_at < ((p_end_date + 1)::timestamp at time zone 'America/Sao_Paulo'))
      and (
        v_link_status is null or v_link_status = 'all'
        or (v_link_status = 'matched' and a.match_status <> 'unmatched')
        or (v_link_status = 'standalone' and a.match_status = 'unmatched' and not a.match_ambiguous)
        or (v_link_status = 'review' and a.match_ambiguous)
        or (v_link_status in ('unmatched', 'lead', 'prospection', 'both') and a.match_status = v_link_status)
      )
      and (
        v_search is null
        or a.customer_name ilike '%' || v_search || '%'
        or a.description ilike '%' || v_search || '%'
        or a.professional_name_snapshot ilike '%' || v_search || '%'
        or coalesce(a.credited_professional_name_snapshot, '') ilike '%' || v_search || '%'
        or coalesce(a.service_order, '') ilike '%' || v_search || '%'
        or exists (
          select 1
          from app_private.attendance_service_orders service_orders
          where service_orders.attendance_id = a.id
            and service_orders.service_order ilike '%' || v_search || '%'
        )
        or (
          v_search_digits is not null
          and (
            coalesce(a.phone_normalized, '') like '%' || v_search_digits || '%'
            or coalesce(a.cpf_normalized, '') like '%' || v_search_digits || '%'
          )
        )
      )
  ), overall as (
    select
      count(*)::bigint as total,
      count(*) filter (where tag = 'budget')::bigint as budgets,
      count(*) filter (where tag = 'purchase')::bigint as purchases,
      count(*) filter (where tag = 'other')::bigint as other,
      count(distinct customer_key)::bigint as unique_customers,
      count(distinct customer_key) filter (where tag = 'purchase')::bigint as unique_buyers,
      coalesce(sum(purchase_value) filter (where tag = 'purchase'), 0)::numeric as revenue,
      coalesce(sum(service_value), 0)::numeric as service_value,
      count(*) filter (where lead_id is not null)::bigint as linked_lead,
      count(*) filter (where prospection_id is not null)::bigint as linked_prospection,
      count(*) filter (where lead_id is not null or prospection_id is not null)::bigint as linked,
      count(*) filter (where lead_id is not null and prospection_id is not null)::bigint as both,
      count(*) filter (where lead_id is null and prospection_id is null)::bigint as unmatched,
      count(*) filter (where match_ambiguous)::bigint as ambiguous
    from filtered
  ), professional_summary as (
    select
      professional_id,
      professional_name,
      count(*)::bigint as total,
      count(*) filter (where tag = 'budget')::bigint as budgets,
      count(*) filter (where tag = 'purchase')::bigint as purchases,
      count(*) filter (where tag = 'other')::bigint as other,
      count(distinct customer_key)::bigint as unique_customers,
      count(distinct customer_key) filter (where tag = 'purchase')::bigint as unique_buyers,
      coalesce(sum(purchase_value) filter (where tag = 'purchase'), 0)::numeric as revenue,
      coalesce(sum(service_value), 0)::numeric as service_value
    from filtered
    group by professional_id, professional_name
  )
  select jsonb_build_object(
    'store_id', v_store_id,
    'metrics', jsonb_build_object(
      'total', o.total,
      'budgets', o.budgets,
      'purchases', o.purchases,
      'other', o.other,
      'unique_customers', o.unique_customers,
      'unique_buyers', o.unique_buyers,
      'conversion', case when o.unique_customers > 0 then round((o.unique_buyers::numeric / o.unique_customers::numeric) * 100, 1) else 0 end,
      'attendance_conversion', case when o.total > 0 then round((o.purchases::numeric / o.total::numeric) * 100, 1) else 0 end,
      'revenue', o.revenue,
      'ticket', case when o.purchases > 0 then round(o.revenue / o.purchases::numeric, 2) else 0 end,
      'service_value', o.service_value,
      'average_service_value', case when o.total > 0 then round(o.service_value / o.total::numeric, 2) else 0 end,
      'linked', o.linked,
      'linked_lead', o.linked_lead,
      'linked_prospection', o.linked_prospection,
      'both', o.both,
      'unmatched', o.unmatched,
      'ambiguous', o.ambiguous
    ),
    'professionals', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'professional_id', ps.professional_id,
          'name', ps.professional_name,
          'total', ps.total,
          'budgets', ps.budgets,
          'purchases', ps.purchases,
          'other', ps.other,
          'unique_customers', ps.unique_customers,
          'unique_buyers', ps.unique_buyers,
          'conversion', case when ps.unique_customers > 0 then round((ps.unique_buyers::numeric / ps.unique_customers::numeric) * 100, 1) else 0 end,
          'attendance_conversion', case when ps.total > 0 then round((ps.purchases::numeric / ps.total::numeric) * 100, 1) else 0 end,
          'revenue', ps.revenue,
          'ticket', case when ps.purchases > 0 then round(ps.revenue / ps.purchases::numeric, 2) else 0 end,
          'service_value', ps.service_value
        )
        order by ps.purchases desc, ps.revenue desc, ps.total desc, ps.professional_name
      )
      from professional_summary ps
    ), '[]'::jsonb)
  ) into v_result
  from overall o;

  return v_result;
end;
$$;

-- O workspace inicial usa a mesma listagem V4; assim um cancelado nunca
-- pisca como atendimento "Outro" antes da atualização operacional.
CREATE OR REPLACE FUNCTION app_private.rpc_get_attendance_workspace(p_session_token text, p_store_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'app_private', 'public', 'extensions'
AS $function$
declare
  v_session record;
  v_store_id uuid;
  v_store jsonb;
  v_settings jsonb;
  v_professionals jsonb := '[]'::jsonb;
  v_recent jsonb;
  v_metrics jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente não pode consultar atendimentos de outra loja.';
    end if;
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if v_store_id is null then
    raise exception 'Selecione um cliente para consultar os atendimentos.';
  end if;
  if not app_private.attendance_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, v_store_id
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  select jsonb_build_object(
    'id', st.id,
    'name', st.name,
    'nick', st.nick,
    'avatar_url', st.avatar_url,
    'technician_user_id', st.technician_user_id,
    'is_active', st.is_active
  ), jsonb_build_object(
    'bonus_minimum', coalesce(ps.bonus_minimum, 300),
    'bonus_amount', coalesce(ps.bonus_amount, 20),
    'accent_color', coalesce(ps.accent_color, '#16855f'),
    'retention_years', 2
  )
  into v_store, v_settings
  from public.stores st
  left join public.prospection_store_settings ps
    on ps.store_id = st.id and ps.admin_user_id = st.admin_user_id
  where st.id = v_store_id
    and st.admin_user_id = v_session.admin_user_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', pp.id,
    'name', pp.name,
    'is_active', pp.is_active
  ) order by pp.name), '[]'::jsonb)
  into v_professionals
  from public.prospection_professionals pp
  where pp.store_id = v_store_id
    and pp.admin_user_id = v_session.admin_user_id
    and pp.archived_at is null;

  v_metrics := app_private.attendance_metrics_json(v_session.admin_user_id, v_store_id);
  v_recent := app_private.rpc_list_attendances_v4(
    p_session_token, v_store_id, null, null, null, null, null, null, null, 100, 0
  );

  return jsonb_build_object(
    'store', v_store,
    'settings', v_settings,
    'permissions', jsonb_build_object(
      'role', v_session.user_role::text,
      'can_view', true,
      'can_create', true,
      'can_manage', v_session.user_role::text in ('admin', 'technician')
    ),
    'tags', jsonb_build_array(
      jsonb_build_object('value', 'budget', 'label', 'Orçamento'),
      jsonb_build_object('value', 'purchase', 'label', 'Compra'),
      jsonb_build_object('value', 'other', 'label', 'Outro')
    ),
    'professionals', v_professionals,
    'metrics', v_metrics,
    'summary', coalesce(v_metrics -> 'all', '{}'::jsonb),
    'attendances', coalesce(v_recent -> 'items', '[]'::jsonb),
    'records', coalesce(v_recent -> 'items', '[]'::jsonb),
    'recent_attendances', coalesce(v_recent -> 'items', '[]'::jsonb),
    'total', coalesce((v_recent ->> 'total')::bigint, 0),
    'pagination', jsonb_build_object(
      'limit', coalesce((v_recent ->> 'limit')::integer, 100),
      'offset', coalesce((v_recent ->> 'offset')::integer, 0),
      'has_more', coalesce((v_recent ->> 'has_more')::boolean, false)
    ),
    'retention', jsonb_build_object(
      'years', 2,
      'cutoff', now() - interval '2 years',
      'policy', 'rolling'
    )
  );
end;
$function$;

-- Nenhum helper/tabela privada fica diretamente acessível pelo Data API.
revoke all on function app_private.lock_attendance_store_edit_for_session(
  text, uuid
) from public, anon, authenticated, service_role;

-- Os motores antigos sem o lock de loja deixam de ser entradas públicas. Os
-- wrappers serializados abaixo são os únicos alvos dos RPCs legados públicos.
revoke all on function app_private.rpc_upsert_attendance(
  text, uuid, text, text, text, text, text, numeric, numeric, text, text
) from public, anon, authenticated, service_role;
revoke all on function app_private.rpc_upsert_attendance_v2(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, text
) from public, anon, authenticated, service_role;

revoke all on function app_private.rpc_upsert_attendance_v1_serialized(
  text, uuid, text, text, text, text, text, numeric, numeric, text, text
) from public, anon, authenticated, service_role;
grant execute on function app_private.rpc_upsert_attendance_v1_serialized(
  text, uuid, text, text, text, text, text, numeric, numeric, text, text
) to anon, authenticated, service_role;

revoke all on function app_private.rpc_upsert_attendance_v2_serialized(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, text
) from public, anon, authenticated, service_role;
grant execute on function app_private.rpc_upsert_attendance_v2_serialized(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, text
) to anon, authenticated, service_role;

-- O público V3 é SECURITY INVOKER e, por compatibilidade, continua chamando
-- este guard privado (agora já serializado pelo lock da loja).
revoke all on function app_private.rpc_upsert_attendance_v3_required_date(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, date, text
) from public, anon, authenticated, service_role;
grant execute on function app_private.rpc_upsert_attendance_v3_required_date(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, date, text
) to anon, authenticated, service_role;

revoke all on function app_private.lock_attendance_service_orders(uuid, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_attendance_service_orders_available(uuid, uuid, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app_private.replace_attendance_service_orders(uuid, uuid, uuid, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app_private.normalize_attendance_service_orders(jsonb, boolean)
  from public, anon, authenticated, service_role;
revoke all on function app_private.attendance_service_orders_json(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app_private.attendance_result_v4(uuid, boolean)
  from public, anon, authenticated, service_role;
revoke all on function app_private.rpc_upsert_attendance_v4(
  text, uuid, text, text, text, text, text, text, numeric, jsonb, date, text
) from public, anon, authenticated, service_role;
revoke all on function app_private.rpc_update_attendance_v2(
  text, uuid, uuid, text, date, text, text, text, text, text,
  numeric, jsonb, timestamptz
) from public, anon, authenticated, service_role;
revoke all on function app_private.rpc_cancel_attendance_v1(
  text, uuid, uuid, timestamptz, text
) from public, anon, authenticated, service_role;
revoke all on function app_private.rpc_list_attendances_v4(
  text, uuid, text, text, uuid, text, text, date, date, integer, integer
) from public, anon, authenticated, service_role;
revoke all on function app_private.prevent_attendance_history_mutation()
  from public, anon, authenticated, service_role;
revoke all on function app_private.prevent_canceled_attendance_mutation()
  from public, anon, authenticated, service_role;
revoke all on function app_private.prevent_legacy_multiple_order_update()
  from public, anon, authenticated, service_role;
revoke all on function app_private.sync_attendance_service_orders()
  from public, anon, authenticated, service_role;

revoke all on function public.lc_upsert_attendance(
  text, uuid, text, text, text, text, text, numeric, numeric, text, text
) from public, anon, authenticated, service_role;
grant execute on function public.lc_upsert_attendance(
  text, uuid, text, text, text, text, text, numeric, numeric, text, text
) to anon, authenticated, service_role;

revoke all on function public.lc_upsert_attendance_v2(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, text
) from public, anon, authenticated, service_role;
grant execute on function public.lc_upsert_attendance_v2(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, text
) to anon, authenticated, service_role;

revoke all on function public.lc_upsert_attendance_v4(
  text, uuid, text, text, text, text, text, text, numeric, jsonb, date, text
) from public, anon, authenticated, service_role;
grant execute on function public.lc_upsert_attendance_v4(
  text, uuid, text, text, text, text, text, text, numeric, jsonb, date, text
) to anon, authenticated, service_role;

revoke all on function public.lc_update_attendance_v2(
  text, uuid, uuid, text, date, text, text, text, text, text,
  numeric, jsonb, timestamptz
) from public, anon, authenticated, service_role;
grant execute on function public.lc_update_attendance_v2(
  text, uuid, uuid, text, date, text, text, text, text, text,
  numeric, jsonb, timestamptz
) to anon, authenticated, service_role;

revoke all on function public.lc_cancel_attendance_v1(
  text, uuid, uuid, timestamptz, text
) from public, anon, authenticated, service_role;
grant execute on function public.lc_cancel_attendance_v1(
  text, uuid, uuid, timestamptz, text
) to anon, authenticated, service_role;

revoke all on function public.lc_list_attendances_v4(
  text, uuid, text, text, uuid, text, text, date, date, integer, integer
) from public, anon, authenticated, service_role;
grant execute on function public.lc_list_attendances_v4(
  text, uuid, text, text, uuid, text, text, date, date, integer, integer
) to anon, authenticated, service_role;

comment on table app_private.attendance_service_orders is
  'OS normalizadas por atendimento; acesso somente pelos RPCs autorizados.';
comment on table app_private.attendance_service_order_audit is
  'Histórico imutável das alterações na composição de OS.';
comment on table app_private.attendance_cancellation_audit is
  'Histórico imutável do cancelamento e da reversão comercial.';
comment on column public.attendances.canceled_at is
  'Cancelamento permanente; o registro segue visível e sai de metas/métricas.';
comment on function public.lc_upsert_attendance_v4(
  text, uuid, text, text, text, text, text, text, numeric, jsonb, date, text
) is
  'Cria atendimento; Compra recebe até 12 OS e deriva o total pela soma exata.';
comment on function public.lc_update_attendance_v2(
  text, uuid, uuid, text, date, text, text, text, text, text,
  numeric, jsonb, timestamptz
) is
  'Edita atendimento e sua composição auditável de múltiplas OS.';
comment on function public.lc_cancel_attendance_v1(
  text, uuid, uuid, timestamptz, text
) is
  'Cancela permanentemente, preserva snapshot e reverte metas/projeções.';
comment on function public.lc_list_attendances_v4(
  text, uuid, text, text, uuid, text, text, date, date, integer, integer
) is
  'Lista ativos/cancelados, inclui múltiplas OS e busca OS secundária.';

do $$
begin
  if pg_catalog.has_table_privilege(
    'anon', 'app_private.attendance_service_orders', 'SELECT'
  ) or pg_catalog.has_table_privilege(
    'authenticated', 'app_private.attendance_service_orders', 'SELECT'
  ) then
    raise exception 'A tabela privada de OS não pode ser exposta aos clientes.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class relations
    join pg_catalog.pg_namespace schemas on schemas.oid = relations.relnamespace
    where schemas.nspname = 'app_private'
      and relations.relname = 'attendance_service_orders'
      and relations.relrowsecurity
      and relations.relforcerowsecurity
  ) then
    raise exception 'RLS defensivo não foi ativado na tabela privada de OS.';
  end if;

  if pg_catalog.to_regprocedure(
       'public.lc_upsert_attendance(text,uuid,text,text,text,text,text,numeric,numeric,text,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_upsert_attendance_v2(text,uuid,text,text,text,text,text,text,numeric,numeric,text,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_upsert_attendance_v3(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_upsert_attendance_v4(text,uuid,text,text,text,text,text,text,numeric,jsonb,date,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_update_attendance_v1(text,uuid,uuid,text,date,text,text,text,text,text,numeric,numeric,text,timestamptz)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_update_attendance_v2(text,uuid,uuid,text,date,text,text,text,text,text,numeric,jsonb,timestamptz)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_cancel_attendance_v1(text,uuid,uuid,timestamptz,text)'
     ) is null then
    raise exception 'Um contrato público de escrita de atendimento foi perdido.';
  end if;

  -- V1/V2 públicos roteiam somente para guards serializados. Os motores
  -- antigos continuam internos para manter semântica, mas não são executáveis
  -- diretamente pelos papéis do Data API.
  if pg_catalog.strpos(
       pg_catalog.pg_get_functiondef(
         pg_catalog.to_regprocedure(
           'public.lc_upsert_attendance(text,uuid,text,text,text,text,text,numeric,numeric,text,text)'
         )
       ),
       'rpc_upsert_attendance_v1_serialized'
     ) = 0
     or pg_catalog.strpos(
       pg_catalog.pg_get_functiondef(
         pg_catalog.to_regprocedure(
           'public.lc_upsert_attendance_v2(text,uuid,text,text,text,text,text,text,numeric,numeric,text,text)'
         )
       ),
       'rpc_upsert_attendance_v2_serialized'
     ) = 0
     or pg_catalog.strpos(
       pg_catalog.pg_get_functiondef(
         pg_catalog.to_regprocedure(
           'app_private.rpc_upsert_attendance_v1_serialized(text,uuid,text,text,text,text,text,numeric,numeric,text,text)'
         )
       ),
       'lock_attendance_store_edit_for_session'
     ) = 0
     or pg_catalog.strpos(
       pg_catalog.pg_get_functiondef(
         pg_catalog.to_regprocedure(
           'app_private.rpc_upsert_attendance_v2_serialized(text,uuid,text,text,text,text,text,text,numeric,numeric,text,text)'
         )
       ),
       'lock_attendance_store_edit_for_session'
     ) = 0 then
    raise exception 'V1/V2 legados não estão roteados pelo lock global.';
  end if;

  if pg_catalog.has_function_privilege(
       'anon',
       'app_private.rpc_upsert_attendance(text,uuid,text,text,text,text,text,numeric,numeric,text,text)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'authenticated',
       'app_private.rpc_upsert_attendance(text,uuid,text,text,text,text,text,numeric,numeric,text,text)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'service_role',
       'app_private.rpc_upsert_attendance(text,uuid,text,text,text,text,text,numeric,numeric,text,text)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'anon',
       'app_private.rpc_upsert_attendance_v2(text,uuid,text,text,text,text,text,text,numeric,numeric,text,text)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'authenticated',
       'app_private.rpc_upsert_attendance_v2(text,uuid,text,text,text,text,text,text,numeric,numeric,text,text)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'service_role',
       'app_private.rpc_upsert_attendance_v2(text,uuid,text,text,text,text,text,text,numeric,numeric,text,text)',
       'EXECUTE'
     ) then
    raise exception 'Um motor legado sem lock global ainda está exposto.';
  end if;

  if not pg_catalog.has_function_privilege(
       'anon',
       'public.lc_upsert_attendance(text,uuid,text,text,text,text,text,numeric,numeric,text,text)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'authenticated',
       'public.lc_upsert_attendance_v2(text,uuid,text,text,text,text,text,text,numeric,numeric,text,text)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'service_role',
       'public.lc_update_attendance_v1(text,uuid,uuid,text,date,text,text,text,text,text,numeric,numeric,text,timestamptz)',
       'EXECUTE'
     ) then
    raise exception 'ACL público legado de atendimento foi alterado.';
  end if;

  -- Toda escrita de linha/OS começa pelo mesmo lock da loja. O update V1 já
  -- possuía o guard internamente; esta asserção impede regressão silenciosa.
  if pg_catalog.strpos(
       pg_catalog.pg_get_functiondef(
         pg_catalog.to_regprocedure(
           'app_private.lock_attendance_store_edit_for_session(text,uuid)'
         )
       ),
       'attendance:store-edit:'
     ) = 0
     or pg_catalog.strpos(
       pg_catalog.pg_get_functiondef(
         pg_catalog.to_regprocedure(
           'app_private.rpc_upsert_attendance_v3_required_date(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)'
         )
       ),
       'attendance:store-edit:'
     ) = 0
     or pg_catalog.strpos(
       pg_catalog.pg_get_functiondef(
         pg_catalog.to_regprocedure(
           'app_private.rpc_upsert_attendance_v4(text,uuid,text,text,text,text,text,text,numeric,jsonb,date,text)'
         )
       ),
       'attendance:store-edit:'
     ) = 0
     or pg_catalog.strpos(
       pg_catalog.pg_get_functiondef(
         pg_catalog.to_regprocedure(
           'app_private.rpc_update_attendance_v1(text,uuid,uuid,text,date,text,text,text,text,text,numeric,numeric,text,timestamptz)'
         )
       ),
       'attendance:store-edit:'
     ) = 0
     or pg_catalog.strpos(
       pg_catalog.pg_get_functiondef(
         pg_catalog.to_regprocedure(
           'app_private.rpc_update_attendance_v2(text,uuid,uuid,text,date,text,text,text,text,text,numeric,jsonb,timestamptz)'
         )
       ),
       'attendance:store-edit:'
     ) = 0
     or pg_catalog.strpos(
       pg_catalog.pg_get_functiondef(
         pg_catalog.to_regprocedure(
           'app_private.rpc_cancel_attendance_v1(text,uuid,uuid,timestamptz,text)'
         )
       ),
       'attendance:store-edit:'
     ) = 0 then
    raise exception 'A hierarquia global store -> row/OS está incompleta.';
  end if;
end;
$$;

notify pgrst, 'reload schema';

commit;
