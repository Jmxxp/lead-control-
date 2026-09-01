-- Bonificacoes semanais sem corte por mes, agenda de pagamento e participantes
-- independentes para a fila do Bom Dia Vendedor.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';

alter table public.prospection_store_settings
  add column if not exists bonus_payment_weekday smallint not null default 1;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'prospection_store_settings_bonus_payment_weekday_check'
      and conrelid = 'public.prospection_store_settings'::regclass
  ) then
    alter table public.prospection_store_settings
      add constraint prospection_store_settings_bonus_payment_weekday_check
      check (bonus_payment_weekday between 1 and 7);
  end if;
end;
$$;

alter table public.prospection_professionals
  add column if not exists good_morning_seller_enabled boolean not null default true;

alter table public.prospections
  add column if not exists bonus_professional_id_snapshot uuid,
  add column if not exists bonus_professional_name_snapshot text,
  add column if not exists bonus_minimum_snapshot numeric(12,2),
  add column if not exists bonus_amount_snapshot numeric(12,2),
  add column if not exists bonus_eligible_snapshot boolean,
  add column if not exists bonus_awarded_amount_snapshot numeric(12,2),
  add column if not exists bonus_credit_status_snapshot text;

create index if not exists prospections_admin_purchased_at_idx
  on public.prospections (admin_user_id, purchased_at desc, store_id)
  where purchased_at is not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'prospections_bonus_snapshot_check'
      and conrelid = 'public.prospections'::regclass
  ) then
    alter table public.prospections
      add constraint prospections_bonus_snapshot_check
      check (
        (bonus_minimum_snapshot is null or bonus_minimum_snapshot >= 0)
        and (bonus_amount_snapshot is null or bonus_amount_snapshot >= 0)
        and (bonus_awarded_amount_snapshot is null or bonus_awarded_amount_snapshot >= 0)
        and (
          bonus_professional_name_snapshot is null
          or length(btrim(bonus_professional_name_snapshot)) between 1 and 200
        )
        and (
          bonus_credit_status_snapshot is null
          or bonus_credit_status_snapshot in (
            'awarded', 'below_minimum', 'missing_professional',
            'ambiguous_prospection', 'already_converted', 'not_applicable'
          )
        )
      );
  end if;
end;
$$;

-- Congela a regra dos registros historicos que ainda dependiam da configuracao
-- atual. O snapshot de Atendimento continua tendo precedencia no relatorio.
-- A trigger de updated_at e suspensa apenas durante este backfill para nao
-- transformar uma migracao tecnica em alteracao aparente do historico.
alter table public.prospections disable trigger prospections_updated_at;

with bonus_snapshot as (
  select
    pr.id,
    coalesce(pr.bonus_professional_id_snapshot, pr.professional_id) as professional_id,
    coalesce(
      nullif(left(btrim(pr.bonus_professional_name_snapshot), 200), ''),
      nullif(left(btrim(pr.professional_name_snapshot), 200), ''),
      nullif(left(btrim(pp.name), 200), '')
    ) as professional_name,
    coalesce(pr.bonus_minimum_snapshot, ps.bonus_minimum, 300)::numeric(12,2) as minimum_amount,
    coalesce(pr.bonus_amount_snapshot, ps.bonus_amount, 20)::numeric(12,2) as bonus_amount,
    (
      (
        coalesce(pr.bonus_professional_id_snapshot, pr.professional_id) is not null
        or coalesce(
          nullif(left(btrim(pr.bonus_professional_name_snapshot), 200), ''),
          nullif(left(btrim(pr.professional_name_snapshot), 200), ''),
          nullif(left(btrim(pp.name), 200), '')
        ) is not null
      )
      and coalesce(pr.purchase_amount, 0) >= coalesce(pr.bonus_minimum_snapshot, ps.bonus_minimum, 300)
    ) as eligible
  from public.prospections pr
  left join public.prospection_store_settings ps
   on ps.store_id = pr.store_id
   and ps.admin_user_id = pr.admin_user_id
  left join public.prospection_professionals pp
    on pp.id = pr.professional_id
   and pp.store_id = pr.store_id
   and pp.admin_user_id = pr.admin_user_id
  where pr.purchased_at is not null
)
update public.prospections pr
set bonus_professional_id_snapshot = snapshot.professional_id,
    bonus_professional_name_snapshot = snapshot.professional_name,
    bonus_minimum_snapshot = snapshot.minimum_amount,
    bonus_amount_snapshot = snapshot.bonus_amount,
    bonus_eligible_snapshot = snapshot.eligible,
    bonus_awarded_amount_snapshot = case when snapshot.eligible then snapshot.bonus_amount else 0 end,
    bonus_credit_status_snapshot = case
      when snapshot.professional_id is null
       and snapshot.professional_name is null
        then 'missing_professional'
      when snapshot.eligible then 'awarded'
      else 'below_minimum'
    end
from bonus_snapshot snapshot
where pr.id = snapshot.id
  and (
    pr.bonus_minimum_snapshot is null
    or pr.bonus_professional_id_snapshot is null
    or pr.bonus_professional_name_snapshot is null
    or pr.bonus_amount_snapshot is null
    or pr.bonus_eligible_snapshot is null
    or pr.bonus_awarded_amount_snapshot is null
    or pr.bonus_credit_status_snapshot is null
  );

alter table public.prospections enable trigger prospections_updated_at;

create or replace function app_private.prospection_configuration_revision(
  p_store_id uuid
)
returns text
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  select encode(
    extensions.digest(
      jsonb_build_object(
        'settings', jsonb_build_object(
          'daily_goal', coalesce(ps.daily_goal, 15),
          'bonus_minimum', coalesce(ps.bonus_minimum, 300),
          'bonus_amount', coalesce(ps.bonus_amount, 20),
          'bonus_payment_weekday', coalesce(ps.bonus_payment_weekday, 1),
          'accent_color', coalesce(ps.accent_color, '#16855f'),
          'logo_background_color', coalesce(ps.logo_background_color, '#ffffff')
        ),
        'categories', coalesce((
          select jsonb_agg(jsonb_build_array(pc.id, pc.name, pc.sort_order) order by pc.id)
          from public.prospection_tag_categories pc
          where pc.store_id = p_store_id
        ), '[]'::jsonb),
        'tags', coalesce((
          select jsonb_agg(jsonb_build_array(pt.id, pt.category_id, pt.label, pt.sort_order) order by pt.id)
          from public.prospection_tags pt
          where pt.store_id = p_store_id
        ), '[]'::jsonb),
        'professionals', coalesce((
          select jsonb_agg(
            jsonb_build_array(pp.id, pp.name, pp.is_active)
            order by pp.id
          )
          from public.prospection_professionals pp
          where pp.store_id = p_store_id
            and pp.archived_at is null
        ), '[]'::jsonb)
      )::text,
      'sha256'
    ),
    'hex'
  )
  from (select 1) seed
  left join public.prospection_store_settings ps on ps.store_id = p_store_id;
$$;

create or replace function app_private.rpc_get_prospection_configuration_with_bonus_schedule(
  p_session_token text
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_result jsonb;
  v_settings jsonb;
begin
  v_result := app_private.rpc_get_prospection_configuration(p_session_token);

  select coalesce(jsonb_agg(
    setting.value || jsonb_build_object(
      'bonus_payment_weekday', coalesce(ps.bonus_payment_weekday, 1)
    )
    order by setting.position
  ), '[]'::jsonb)
  into v_settings
  from jsonb_array_elements(coalesce(v_result->'settings', '[]'::jsonb))
       with ordinality setting(value, position)
  left join public.prospection_store_settings ps
    on ps.store_id = (setting.value->>'store_id')::uuid;

  return jsonb_set(v_result, '{settings}', v_settings, true);
end;
$$;

create or replace function app_private.rpc_save_prospection_configuration_with_bonus_schedule(
  p_session_token text,
  p_store_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_result jsonb;
  v_payment_value jsonb := p_payload #> '{settings,bonus_payment_weekday}';
  v_payment_weekday smallint;
  v_current_payment_weekday smallint := 1;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_payment_value is not null and v_payment_value <> 'null'::jsonb then
    if jsonb_typeof(v_payment_value) is distinct from 'number'
       or coalesce(p_payload #>> '{settings,bonus_payment_weekday}', '') !~ '^[1-7]$' then
      raise exception 'Escolha um dia válido para o pagamento semanal.';
    end if;
    v_payment_weekday := (p_payload #>> '{settings,bonus_payment_weekday}')::smallint;
    select coalesce(ps.bonus_payment_weekday, 1)::smallint
    into v_current_payment_weekday
    from (select 1) seed
    left join public.prospection_store_settings ps on ps.store_id = p_store_id;

    if v_payment_weekday is distinct from v_current_payment_weekday then
      if v_session.user_role::text not in ('admin', 'technician') then
        raise exception 'Somente o Admin ou a Agência responsável pode definir o pagamento da bonificação.';
      end if;
      if v_session.user_role::text = 'technician' and not exists (
        select 1
        from public.stores st
        where st.id = p_store_id
          and st.admin_user_id = v_session.admin_user_id
          and st.is_active = true
          and st.technician_user_id = v_session.user_id
      ) then
        raise exception 'Somente a Agência principal responsável por este cliente pode definir o pagamento da bonificação.';
      end if;
    end if;
  end if;

  -- A funcao consolidada existente continua validando escopo, revisao e todo o
  -- snapshot. Qualquer erro posterior reverte esta mesma transacao.
  v_result := app_private.rpc_save_prospection_configuration(
    p_session_token,
    p_store_id,
    p_payload
  );

  -- A funcao consolidada acima mantem a linha do cliente bloqueada ate o
  -- commit. Revalidamos a Agencia principal sob esse lock antes de alterar o
  -- calendario financeiro.
  if v_payment_weekday is not null
     and v_payment_weekday is distinct from v_current_payment_weekday
     and v_session.user_role::text = 'technician'
     and not exists (
       select 1
       from public.stores st
       where st.id = p_store_id
         and st.admin_user_id = v_session.admin_user_id
         and st.is_active = true
         and st.technician_user_id = v_session.user_id
     ) then
    raise exception 'Somente a Agência principal responsável por este cliente pode definir o pagamento da bonificação.';
  end if;

  if v_payment_weekday is not null then
    update public.prospection_store_settings ps
    set bonus_payment_weekday = v_payment_weekday
    where ps.store_id = p_store_id
      and ps.admin_user_id = v_session.admin_user_id;
    if not found then
      raise exception 'Configuração de bonificação não encontrada para este cliente.';
    end if;
  end if;

  return v_result || jsonb_build_object(
    'bonus_payment_weekday', coalesce(v_payment_weekday, (
      select ps.bonus_payment_weekday
      from public.prospection_store_settings ps
      where ps.store_id = p_store_id
    ), 1),
    'revision', app_private.prospection_configuration_revision(p_store_id)
  );
end;
$$;

create or replace function public.lc_get_prospection_configuration(
  p_session_token text
)
returns jsonb
language sql
security invoker
set search_path = public, app_private, extensions
as $$
  select app_private.rpc_get_prospection_configuration_with_bonus_schedule(p_session_token);
$$;

create or replace function public.lc_save_prospection_configuration(
  p_session_token text,
  p_store_id uuid,
  p_payload jsonb
)
returns jsonb
language sql
security invoker
set search_path = public, app_private, extensions
as $$
  select app_private.rpc_save_prospection_configuration_with_bonus_schedule(
    p_session_token,
    p_store_id,
    p_payload
  );
$$;

create or replace function app_private.rpc_set_prospection_outcome(
  p_session_token text,
  p_prospection_id uuid,
  p_returned boolean default null,
  p_purchased boolean default null,
  p_purchase_amount numeric default null,
  p_purchase_order text default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_prospection record;
  v_bonus_minimum numeric(12,2);
  v_bonus_amount numeric(12,2);
  v_purchase_amount numeric(12,2);
  v_bonus_professional_id uuid;
  v_bonus_professional_name text;
  v_bonus_eligible boolean;
  v_bonus_status text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  select
    pr.store_id,
    pr.purchased_at,
    pr.professional_id,
    pr.professional_name_snapshot,
    pr.bonus_professional_id_snapshot,
    pr.bonus_professional_name_snapshot,
    coalesce(pp.name, pr.professional_name_snapshot) as current_professional_name,
    pr.bonus_minimum_snapshot,
    pr.bonus_amount_snapshot,
    coalesce(ps.bonus_minimum, 300)::numeric(12,2) as configured_bonus_minimum,
    coalesce(ps.bonus_amount, 20)::numeric(12,2) as configured_bonus_amount
  into v_prospection
  from public.prospections pr
  left join public.prospection_store_settings ps
   on ps.store_id = pr.store_id
   and ps.admin_user_id = pr.admin_user_id
  left join public.prospection_professionals pp
    on pp.id = pr.professional_id
   and pp.store_id = pr.store_id
   and pp.admin_user_id = pr.admin_user_id
  where pr.id = p_prospection_id
    and pr.admin_user_id = v_session.admin_user_id
  for update of pr;

  if not found or not app_private.prospection_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_prospection.store_id,
    false
  ) then
    raise exception 'Prospecção não encontrada ou sem permissão.';
  end if;

  if p_returned = false and v_prospection.purchased_at is not null and p_purchased is null then
    raise exception 'Remova a compra antes de remover a volta.';
  end if;

  if p_purchased = true then
    begin
      v_purchase_amount := round(coalesce(p_purchase_amount, 0), 2);
    exception
      when numeric_value_out_of_range then
        raise exception 'O valor da compra está fora do limite permitido.';
    end;

    if v_purchase_amount <= 0 then
      raise exception 'Informe um valor de compra maior que zero.';
    end if;
    if length(btrim(coalesce(p_purchase_order, ''))) = 0 then
      raise exception 'Informe o número da OS.';
    end if;

    -- A primeira confirmacao congela a regra. Correcao posterior do valor da
    -- mesma compra usa o mesmo minimo e o mesmo premio historico.
    v_bonus_minimum := coalesce(
      v_prospection.bonus_minimum_snapshot,
      v_prospection.configured_bonus_minimum,
      300
    );
    v_bonus_amount := coalesce(
      v_prospection.bonus_amount_snapshot,
      v_prospection.configured_bonus_amount,
      20
    );
    v_bonus_professional_id := coalesce(
      v_prospection.bonus_professional_id_snapshot,
      v_prospection.professional_id
    );
    v_bonus_professional_name := coalesce(
      nullif(left(btrim(v_prospection.bonus_professional_name_snapshot), 200), ''),
      nullif(left(btrim(v_prospection.current_professional_name), 200), '')
    );
    v_bonus_eligible := (
      v_bonus_professional_id is not null
      or v_bonus_professional_name is not null
    ) and v_purchase_amount >= v_bonus_minimum;
    v_bonus_status := case
      when v_bonus_professional_id is null
       and v_bonus_professional_name is null
        then 'missing_professional'
      when v_bonus_eligible then 'awarded'
      else 'below_minimum'
    end;
  end if;

  update public.prospections pr
  set returned_at = case
        when p_purchased = true then coalesce(pr.returned_at, clock_timestamp())
        when p_returned is null then pr.returned_at
        when p_returned = true then coalesce(pr.returned_at, clock_timestamp())
        else null
      end,
      purchased_at = case
        when p_purchased is null then pr.purchased_at
        when p_purchased = true then coalesce(pr.purchased_at, clock_timestamp())
        else null
      end,
      purchase_amount = case
        when p_purchased is null then pr.purchase_amount
        when p_purchased = true then v_purchase_amount
        else null
      end,
      purchase_order = case
        when p_purchased is null then pr.purchase_order
        when p_purchased = true then btrim(p_purchase_order)
        else null
      end,
      bonus_professional_id_snapshot = case
        when p_purchased is null then pr.bonus_professional_id_snapshot
        when p_purchased = true then v_bonus_professional_id
        else null
      end,
      bonus_professional_name_snapshot = case
        when p_purchased is null then pr.bonus_professional_name_snapshot
        when p_purchased = true then v_bonus_professional_name
        else null
      end,
      bonus_minimum_snapshot = case
        when p_purchased is null then pr.bonus_minimum_snapshot
        when p_purchased = true then v_bonus_minimum
        else null
      end,
      bonus_amount_snapshot = case
        when p_purchased is null then pr.bonus_amount_snapshot
        when p_purchased = true then v_bonus_amount
        else null
      end,
      bonus_eligible_snapshot = case
        when p_purchased is null then pr.bonus_eligible_snapshot
        when p_purchased = true then v_bonus_eligible
        else null
      end,
      bonus_awarded_amount_snapshot = case
        when p_purchased is null then pr.bonus_awarded_amount_snapshot
        when p_purchased = true and v_bonus_eligible then v_bonus_amount
        when p_purchased = true then 0
        else null
      end,
      bonus_credit_status_snapshot = case
        when p_purchased is null then pr.bonus_credit_status_snapshot
        when p_purchased = true then v_bonus_status
        else null
      end,
      updated_by = v_session.user_id
  where pr.id = p_prospection_id
    and pr.admin_user_id = v_session.admin_user_id;

  return true;
end;
$$;

create or replace function app_private.rpc_list_prospection_bonus_purchases(
  p_session_token text,
  p_start_date date default null,
  p_end_date date default null,
  p_store_id uuid default null
)
returns table (
  prospection_id uuid,
  store_id uuid,
  store_name text,
  customer_name text,
  professional_id uuid,
  professional_name text,
  purchased_at timestamptz,
  purchase_amount numeric,
  purchase_order text,
  bonus_minimum numeric,
  bonus_amount numeric,
  bonus_eligible boolean,
  bonus_awarded_amount numeric,
  bonus_credit_status text
)
language plpgsql
volatile
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_today date := timezone('America/Sao_Paulo', now())::date;
  v_start date := coalesce(
    p_start_date,
    timezone('America/Sao_Paulo', now())::date
      - extract(isodow from timezone('America/Sao_Paulo', now()))::integer + 1
  );
  v_end date := coalesce(p_end_date, timezone('America/Sao_Paulo', now())::date);
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_start > v_end then
    raise exception 'Período inválido.';
  end if;
  if v_end > v_today then
    raise exception 'A data final não pode estar no futuro.';
  end if;
  if p_store_id is not null and not app_private.prospection_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id,
    false
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  return query
  select
    pr.id,
    pr.store_id,
    st.name,
    pr.name,
    coalesce(
      a.credited_professional_id,
      pr.bonus_professional_id_snapshot,
      pr.professional_id
    ),
    coalesce(
      a.credited_professional_name_snapshot,
      pr.bonus_professional_name_snapshot,
      pp.name,
      pr.professional_name_snapshot,
      'Sem responsável'
    ),
    pr.purchased_at,
    coalesce(pr.purchase_amount, a.purchase_value, 0)::numeric,
    coalesce(pr.purchase_order, a.service_order),
    coalesce(
      a.bonus_minimum_snapshot,
      pr.bonus_minimum_snapshot,
      ps.bonus_minimum,
      300
    )::numeric,
    coalesce(
      a.bonus_amount_snapshot,
      pr.bonus_amount_snapshot,
      ps.bonus_amount,
      20
    )::numeric,
    coalesce(
      a.bonus_eligible,
      pr.bonus_eligible_snapshot,
      (
        (
          coalesce(pr.bonus_professional_id_snapshot, pr.professional_id) is not null
          or coalesce(
            nullif(btrim(pr.bonus_professional_name_snapshot), ''),
            nullif(btrim(pr.professional_name_snapshot), '')
          ) is not null
        )
        and coalesce(pr.purchase_amount, 0) >= coalesce(pr.bonus_minimum_snapshot, ps.bonus_minimum, 300)
      )
    ),
    coalesce(
      a.bonus_awarded_amount,
      pr.bonus_awarded_amount_snapshot,
      case when (
        coalesce(pr.bonus_professional_id_snapshot, pr.professional_id) is not null
        or coalesce(
          nullif(btrim(pr.bonus_professional_name_snapshot), ''),
          nullif(btrim(pr.professional_name_snapshot), '')
        ) is not null
      ) and coalesce(pr.purchase_amount, 0) >= coalesce(pr.bonus_minimum_snapshot, ps.bonus_minimum, 300)
        then coalesce(pr.bonus_amount_snapshot, ps.bonus_amount, 20)
        else 0
      end
    )::numeric,
    coalesce(
      a.bonus_credit_status,
      pr.bonus_credit_status_snapshot,
      case
        when coalesce(pr.bonus_professional_id_snapshot, pr.professional_id) is null
         and coalesce(
           nullif(btrim(pr.bonus_professional_name_snapshot), ''),
           nullif(btrim(pr.professional_name_snapshot), '')
         ) is null
          then 'missing_professional'
        when coalesce(pr.purchase_amount, 0) >= coalesce(pr.bonus_minimum_snapshot, ps.bonus_minimum, 300)
          then 'awarded'
        else 'below_minimum'
      end
    )
  from public.prospections pr
  join public.stores st
    on st.id = pr.store_id
   and st.admin_user_id = pr.admin_user_id
  left join public.prospection_store_settings ps
    on ps.store_id = pr.store_id
   and ps.admin_user_id = pr.admin_user_id
  left join public.prospection_professionals pp
    on pp.id = pr.professional_id
   and pp.store_id = pr.store_id
   and pp.admin_user_id = pr.admin_user_id
  left join lateral (
    select attendance.*
    from public.attendances attendance
    where attendance.prospection_id = pr.id
      and attendance.store_id = pr.store_id
      and attendance.admin_user_id = pr.admin_user_id
      and attendance.purchase_credit_applied
    order by attendance.attended_at, attendance.id
    limit 1
  ) a on true
  where pr.admin_user_id = v_session.admin_user_id
    and pr.purchased_at is not null
    and timezone('America/Sao_Paulo', pr.purchased_at)::date between v_start and v_end
    and (p_store_id is null or pr.store_id = p_store_id)
    and app_private.prospection_store_allowed(
      v_session.admin_user_id,
      v_session.user_id,
      v_session.user_role,
      v_session.user_store_id,
      pr.store_id,
      false
    )
  order by pr.purchased_at desc, pr.id desc;
end;
$$;

create or replace function app_private.rpc_get_prospection_weekly_bonus_summary(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  store_id uuid,
  store_name text,
  week_start date,
  week_end date,
  bonus_payment_weekday smallint,
  payment_date date,
  purchase_count bigint,
  eligible_purchase_count bigint,
  total_bonus numeric
)
language plpgsql
volatile
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_today date := timezone('America/Sao_Paulo', now())::date;
  v_week_start date := timezone('America/Sao_Paulo', now())::date
    - extract(isodow from timezone('America/Sao_Paulo', now()))::integer + 1;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if p_store_id is not null and not app_private.prospection_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id,
    false
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  return query
  with purchases as materialized (
    select bonus.*
    from app_private.rpc_list_prospection_bonus_purchases(
      p_session_token,
      v_week_start,
      v_today,
      p_store_id
    ) bonus
  ), totals as (
    select
      purchase.store_id,
      count(purchase.prospection_id)::bigint as purchase_count,
      count(purchase.prospection_id) filter (where purchase.bonus_eligible)::bigint as eligible_purchase_count,
      coalesce(sum(purchase.bonus_awarded_amount) filter (where purchase.bonus_eligible), 0)::numeric as total_bonus
    from purchases purchase
    group by purchase.store_id
  )
  select
    st.id,
    st.name,
    v_week_start,
    v_today,
    coalesce(ps.bonus_payment_weekday, 1)::smallint,
    (
      v_week_start
      + (7 + coalesce(ps.bonus_payment_weekday, 1)::integer - 1)
    )::date,
    coalesce(totals.purchase_count, 0)::bigint,
    coalesce(totals.eligible_purchase_count, 0)::bigint,
    coalesce(totals.total_bonus, 0)::numeric
  from public.stores st
  left join public.prospection_store_settings ps
    on ps.store_id = st.id
   and ps.admin_user_id = st.admin_user_id
  left join totals on totals.store_id = st.id
  where st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and st.prospection_enabled = true
    and (p_store_id is null or st.id = p_store_id)
    and app_private.prospection_store_allowed(
      v_session.admin_user_id,
      v_session.user_id,
      v_session.user_role,
      v_session.user_store_id,
      st.id,
      false
    )
  order by st.name, st.id;
end;
$$;

create or replace function public.lc_get_prospection_weekly_bonus_summary(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  store_id uuid,
  store_name text,
  week_start date,
  week_end date,
  bonus_payment_weekday smallint,
  payment_date date,
  purchase_count bigint,
  eligible_purchase_count bigint,
  total_bonus numeric
)
language sql
security invoker
set search_path = public, app_private, extensions
as $$
  select *
  from app_private.rpc_get_prospection_weekly_bonus_summary(
    p_session_token,
    p_store_id
  );
$$;

create or replace function app_private.rpc_get_good_morning_seller_workspace(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_settings public.good_morning_seller_settings%rowtype;
  v_today date := timezone('America/Sao_Paulo', now())::date;
  v_month_start date;
  v_month_end date;
  v_iso_week_start date;
  v_iso_week_end date;
  v_week_start date;
  v_week_end date;
  v_workdays_in_month integer := 0;
  v_workdays_in_week integer := 0;
  v_today_workday_ordinal integer := 0;
  v_before_today_workdays integer := 0;
  v_before_week_workdays integer := 0;
  v_through_week_workdays integer := 0;
  v_today_is_working_day boolean := false;
  v_has_settings boolean := false;
  v_configured boolean := false;
  v_allocations_match_team boolean := false;
  v_current_professional_valid boolean := false;
  v_queue_min integer := 0;
  v_queue_max integer := 0;
  v_team_professional_count integer := 0;
  v_enabled_professional_count integer := 0;
  v_allocation_count integer := 0;
  v_allocation_sum_cents bigint := 0;
  v_monthly_goal numeric(14, 2) := 0;
  v_monthly_goal_cents bigint := 0;
  v_day_goal_cents bigint := 0;
  v_week_goal_cents bigint := 0;
  v_month_goal_cents bigint := 0;
  v_month_actual numeric(14, 2) := 0;
  v_week_actual numeric(14, 2) := 0;
  v_day_actual numeric(14, 2) := 0;
  v_professionals jsonb := '[]'::jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if not app_private.good_morning_seller_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  v_month_start := date_trunc('month', v_today)::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;
  v_iso_week_start := v_today - (extract(isodow from v_today)::integer - 1);
  v_iso_week_end := v_iso_week_start + 6;
  v_week_start := greatest(v_month_start, v_iso_week_start);
  v_week_end := least(v_month_end, v_iso_week_end);
  v_today_is_working_day := extract(isodow from v_today)::integer between 1 and 6;

  select
    count(*)::integer,
    count(*) filter (where business_day <= v_today)::integer,
    count(*) filter (where business_day < v_today)::integer,
    count(*) filter (where business_day < v_week_start)::integer,
    count(*) filter (where business_day <= v_week_end)::integer
  into
    v_workdays_in_month,
    v_today_workday_ordinal,
    v_before_today_workdays,
    v_before_week_workdays,
    v_through_week_workdays
  from (
    select v_month_start + offsets.day_offset as business_day
    from generate_series(0, v_month_end - v_month_start) as offsets(day_offset)
    where extract(isodow from (v_month_start + offsets.day_offset))::integer between 1 and 6
  ) calendar;

  v_workdays_in_week := greatest(v_through_week_workdays - v_before_week_workdays, 0);

  select *
  into v_settings
  from public.good_morning_seller_settings settings
  where settings.store_id = p_store_id;
  v_has_settings := found;

  if v_has_settings then
    v_monthly_goal := v_settings.monthly_goal;
    v_monthly_goal_cents := round(v_settings.monthly_goal * 100)::bigint;
  end if;

  select
    count(*)::integer,
    count(*) filter (where pp.good_morning_seller_enabled)::integer
  into v_team_professional_count, v_enabled_professional_count
  from public.prospection_professionals pp
  where pp.store_id = p_store_id
    and pp.admin_user_id = v_session.admin_user_id
    and pp.is_active = true
    and pp.archived_at is null;

  select
    count(*)::integer,
    coalesce(sum(round(allocation.goal_amount * 100)::bigint), 0)::bigint,
    coalesce(min(allocation.queue_position), 0)::integer,
    coalesce(max(allocation.queue_position), 0)::integer
  into
    v_allocation_count,
    v_allocation_sum_cents,
    v_queue_min,
    v_queue_max
  from public.good_morning_seller_allocations allocation
  where allocation.store_id = p_store_id;

  select
    not exists (
      select 1
      from public.prospection_professionals pp
      left join public.good_morning_seller_allocations allocation
        on allocation.store_id = pp.store_id
       and allocation.professional_id = pp.id
      where pp.store_id = p_store_id
        and pp.admin_user_id = v_session.admin_user_id
        and pp.is_active = true
        and pp.archived_at is null
        and pp.good_morning_seller_enabled = true
        and allocation.professional_id is null
    )
    and not exists (
      select 1
      from public.good_morning_seller_allocations allocation
      left join public.prospection_professionals pp
        on pp.id = allocation.professional_id
       and pp.store_id = allocation.store_id
       and pp.admin_user_id = allocation.admin_user_id
       and pp.is_active = true
       and pp.archived_at is null
       and pp.good_morning_seller_enabled = true
      where allocation.store_id = p_store_id
        and pp.id is null
    )
  into v_allocations_match_team;

  select exists (
    select 1
    from public.good_morning_seller_allocations allocation
    join public.prospection_professionals pp
      on pp.id = allocation.professional_id
     and pp.store_id = allocation.store_id
     and pp.admin_user_id = allocation.admin_user_id
     and pp.is_active = true
     and pp.archived_at is null
     and pp.good_morning_seller_enabled = true
    where allocation.store_id = p_store_id
      and allocation.professional_id = v_settings.current_professional_id
  ) into v_current_professional_valid;

  v_configured := v_has_settings
    and v_settings.goal_month = v_month_start
    and v_team_professional_count > 0
    and v_enabled_professional_count > 0
    and v_allocation_count = v_enabled_professional_count
    and v_allocations_match_team
    and v_allocation_sum_cents = v_monthly_goal_cents
    and v_queue_min = 1
    and v_queue_max = v_allocation_count
    and v_current_professional_valid;

  select
    coalesce(sum(a.purchase_value) filter (
      where timezone('America/Sao_Paulo', a.attended_at)::date between v_month_start and v_month_end
    ), 0),
    coalesce(sum(a.purchase_value) filter (
      where timezone('America/Sao_Paulo', a.attended_at)::date between v_week_start and v_week_end
    ), 0),
    coalesce(sum(a.purchase_value) filter (
      where timezone('America/Sao_Paulo', a.attended_at)::date = v_today
    ), 0)
  into v_month_actual, v_week_actual, v_day_actual
  from public.attendances a
  where a.store_id = p_store_id
    and a.admin_user_id = v_session.admin_user_id
    and a.tag = 'purchase'
    and a.purchase_value > 0
    and a.attended_at >= (v_month_start::timestamp at time zone 'America/Sao_Paulo')
    and a.attended_at < ((v_month_end + 1)::timestamp at time zone 'America/Sao_Paulo');

  with team as (
    select
      pp.id,
      pp.name,
      pp.is_active,
      pp.good_morning_seller_enabled,
      row_number() over (
        partition by pp.good_morning_seller_enabled
        order by pp.created_at, pp.name, pp.id
      )::integer as default_position,
      coalesce(sum(a.purchase_value) filter (
        where a.tag = 'purchase'
          and a.purchase_value > 0
          and timezone('America/Sao_Paulo', a.attended_at)::date between v_month_start and v_month_end
      ), 0) as actual_month,
      coalesce(sum(a.purchase_value) filter (
        where a.tag = 'purchase'
          and a.purchase_value > 0
          and timezone('America/Sao_Paulo', a.attended_at)::date between v_week_start and v_week_end
      ), 0) as actual_week,
      coalesce(sum(a.purchase_value) filter (
        where a.tag = 'purchase'
          and a.purchase_value > 0
          and timezone('America/Sao_Paulo', a.attended_at)::date = v_today
      ), 0) as actual_today
    from public.prospection_professionals pp
    left join public.attendances a
      on a.professional_id = pp.id
     and a.store_id = pp.store_id
     and a.admin_user_id = pp.admin_user_id
     and a.attended_at >= (v_month_start::timestamp at time zone 'America/Sao_Paulo')
     and a.attended_at < ((v_month_end + 1)::timestamp at time zone 'America/Sao_Paulo')
    where pp.store_id = p_store_id
      and pp.admin_user_id = v_session.admin_user_id
      and pp.is_active = true
      and pp.archived_at is null
    group by
      pp.id,
      pp.name,
      pp.is_active,
      pp.good_morning_seller_enabled,
      pp.created_at
  ), calculated as (
    select
      team.*,
      case
        when team.good_morning_seller_enabled then
          coalesce(allocation.queue_position, team.default_position)
        else v_enabled_professional_count + team.default_position
      end as queue_position,
      case
        when v_configured and team.good_morning_seller_enabled
          then round(coalesce(allocation.goal_amount, 0) * 100)::bigint
        else 0::bigint
      end as goal_month_cents,
      case
        when v_configured
         and team.good_morning_seller_enabled
         and v_today_is_working_day then
          app_private.good_morning_seller_cumulative_goal_cents(
            round(coalesce(allocation.goal_amount, 0) * 100)::bigint,
            v_workdays_in_month,
            v_today_workday_ordinal
          )
          - app_private.good_morning_seller_cumulative_goal_cents(
            round(coalesce(allocation.goal_amount, 0) * 100)::bigint,
            v_workdays_in_month,
            v_before_today_workdays
          )
        else 0::bigint
      end as goal_today_cents,
      case
        when v_configured and team.good_morning_seller_enabled then
          app_private.good_morning_seller_cumulative_goal_cents(
            round(coalesce(allocation.goal_amount, 0) * 100)::bigint,
            v_workdays_in_month,
            v_through_week_workdays
          )
          - app_private.good_morning_seller_cumulative_goal_cents(
            round(coalesce(allocation.goal_amount, 0) * 100)::bigint,
            v_workdays_in_month,
            v_before_week_workdays
          )
        else 0::bigint
      end as goal_week_cents
    from team
    left join public.good_morning_seller_allocations allocation
      on allocation.store_id = p_store_id
     and allocation.professional_id = team.id
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'id', calculated.id,
        'name', calculated.name,
        'is_active', calculated.is_active,
        'good_morning_seller_enabled', calculated.good_morning_seller_enabled,
        'goal_amount', calculated.goal_month_cents::numeric / 100,
        'goal_month', calculated.goal_month_cents::numeric / 100,
        'goal_week', calculated.goal_week_cents::numeric / 100,
        'goal_today', calculated.goal_today_cents::numeric / 100,
        'queue_position', calculated.queue_position,
        'is_current', v_configured
          and calculated.good_morning_seller_enabled
          and calculated.id = v_settings.current_professional_id,
        'actual_month', calculated.actual_month,
        'actual_week', calculated.actual_week,
        'actual_today', calculated.actual_today
      ) order by calculated.good_morning_seller_enabled desc, calculated.queue_position, calculated.name
    ), '[]'::jsonb),
    coalesce(sum(calculated.goal_today_cents), 0)::bigint,
    coalesce(sum(calculated.goal_week_cents), 0)::bigint,
    coalesce(sum(calculated.goal_month_cents), 0)::bigint
  into
    v_professionals,
    v_day_goal_cents,
    v_week_goal_cents,
    v_month_goal_cents
  from calculated;

  return jsonb_build_object(
    'licensed', true,
    'configured', v_configured,
    'participation_control_available', true,
    'goal_month', v_month_start,
    'saved_goal_month', case when v_has_settings then v_settings.goal_month else null end,
    'allocation_mode', coalesce(v_settings.allocation_mode, 'equal'),
    'monthly_goal', case when v_configured then v_month_goal_cents::numeric / 100 else 0 end,
    'last_monthly_goal', v_monthly_goal,
    'today', v_today,
    'week_start', v_week_start,
    'week_end', v_week_end,
    'workdays_in_month', v_workdays_in_month,
    'workdays_in_week', v_workdays_in_week,
    'today_is_working_day', v_today_is_working_day,
    'goals', jsonb_build_object(
      'today', jsonb_build_object('target', v_day_goal_cents::numeric / 100, 'actual', v_day_actual),
      'week', jsonb_build_object('target', v_week_goal_cents::numeric / 100, 'actual', v_week_actual),
      'month', jsonb_build_object('target', v_month_goal_cents::numeric / 100, 'actual', v_month_actual)
    ),
    'current_professional_id', case when v_configured then v_settings.current_professional_id else null end,
    'professionals', v_professionals
  );
end;
$$;

create or replace function app_private.rpc_save_good_morning_seller_settings(
  p_session_token text,
  p_store_id uuid,
  p_monthly_goal numeric,
  p_allocation_mode text,
  p_allocations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_month_start date := date_trunc('month', timezone('America/Sao_Paulo', now()))::date;
  v_goal numeric(14, 2) := round(coalesce(p_monthly_goal, -1), 2);
  v_mode text := lower(btrim(coalesce(p_allocation_mode, '')));
  v_professional_count integer;
  v_payload_count integer;
  v_enabled_count integer;
  v_sum numeric(14, 2);
  v_goal_cents bigint;
  v_base_cents bigint;
  v_remainder_cents integer;
  v_current_professional_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if not app_private.good_morning_seller_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  if v_goal < 0 or v_goal > 999999999999.99 then
    raise exception 'Informe uma meta mensal válida.';
  end if;
  if v_mode not in ('equal', 'custom') then
    raise exception 'Escolha divisão igual ou personalizada.';
  end if;
  if jsonb_typeof(p_allocations) is distinct from 'array'
     or jsonb_array_length(p_allocations) > 500 then
    raise exception 'A lista de vendedores é inválida.';
  end if;

  -- Mantem a mesma ordem de locks usada pela configuracao de equipe:
  -- cliente primeiro, profissionais depois. Assim inclusoes/arquivamentos
  -- concorrentes nao deixam a fila salva pela metade.
  perform 1
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and st.attendance_enabled = true
    and st.good_morning_seller_enabled = true
  for no key update;

  if not found then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  if not app_private.good_morning_seller_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  perform 1
  from public.prospection_professionals pp
  where pp.store_id = p_store_id
    and pp.admin_user_id = v_session.admin_user_id
    and pp.is_active = true
    and pp.archived_at is null
  order by pp.id
  for update;

  select count(*)::integer
  into v_professional_count
  from public.prospection_professionals pp
  where pp.store_id = p_store_id
    and pp.admin_user_id = v_session.admin_user_id
    and pp.is_active = true
    and pp.archived_at is null;

  if v_professional_count = 0 then
    raise exception 'Cadastre ao menos um vendedor ativo em Prospecções.';
  end if;

  select count(*)::integer
  into v_payload_count
  from jsonb_array_elements(p_allocations) item
  where jsonb_typeof(item.value) = 'object'
    and (item.value->>'professional_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    and (
      not (item.value ? 'enabled')
      or jsonb_typeof(item.value->'enabled') = 'boolean'
    );

  if v_payload_count <> v_professional_count
     or v_payload_count <> jsonb_array_length(p_allocations) then
    raise exception 'Inclua todos os vendedores ativos com valores válidos.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_allocations) item
    left join public.prospection_professionals pp
      on pp.id = (item.value->>'professional_id')::uuid
     and pp.store_id = p_store_id
     and pp.admin_user_id = v_session.admin_user_id
     and pp.is_active = true
     and pp.archived_at is null
    where pp.id is null
  ) then
    raise exception 'A lista possui vendedor inválido ou de outro cliente.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_allocations) item
    group by item.value->>'professional_id'
    having count(*) > 1
  ) then
    raise exception 'Não repita vendedores na configuração.';
  end if;

  -- Frontends anteriores nao enviavam "enabled". Nesse caso preservamos a
  -- participacao atual em vez de reativar silenciosamente quem esta pausado.
  select jsonb_agg(
    item.value || jsonb_build_object(
      'enabled', case
        when item.value ? 'enabled' then (item.value->>'enabled')::boolean
        else pp.good_morning_seller_enabled
      end
    )
    order by item.position
  )
  into p_allocations
  from jsonb_array_elements(p_allocations)
       with ordinality as item(value, position)
  join public.prospection_professionals pp
    on pp.id = (item.value->>'professional_id')::uuid
   and pp.store_id = p_store_id
   and pp.admin_user_id = v_session.admin_user_id
   and pp.is_active = true
   and pp.archived_at is null;

  select count(*)::integer
  into v_enabled_count
  from jsonb_array_elements(p_allocations) item
  where coalesce((item.value->>'enabled')::boolean, true);

  if v_enabled_count = 0 then
    raise exception 'Mantenha ao menos um vendedor participando do Bom Dia Vendedor.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_allocations) item
    where coalesce((item.value->>'enabled')::boolean, true)
      and (
        coalesce(item.value->>'queue_position', '') !~ '^[0-9]+$'
        or coalesce(item.value->>'goal_amount', '') !~ '^[0-9]+([.][0-9]{1,2})?$'
      )
  ) then
    raise exception 'Informe meta e posição válidas para todos os participantes.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_allocations) item
    where coalesce((item.value->>'enabled')::boolean, true)
      and (item.value->>'queue_position')::integer not between 1 and v_enabled_count
  ) or (
    select count(distinct (item.value->>'queue_position')::integer)
    from jsonb_array_elements(p_allocations) item
    where coalesce((item.value->>'enabled')::boolean, true)
  ) <> v_enabled_count then
    raise exception 'A ordem da fila dos participantes deve ser contínua e sem repetição.';
  end if;

  if v_mode = 'custom' then
    select round(coalesce(sum((item.value->>'goal_amount')::numeric), 0), 2)
    into v_sum
    from jsonb_array_elements(p_allocations) item
    where coalesce((item.value->>'enabled')::boolean, true);
    if v_sum <> v_goal then
      raise exception 'A soma das metas por vendedor deve ser igual à meta mensal (%).', v_goal;
    end if;
  end if;

  select settings.current_professional_id
  into v_current_professional_id
  from public.good_morning_seller_settings settings
  where settings.store_id = p_store_id
  for update;

  insert into public.good_morning_seller_settings (
    store_id,
    admin_user_id,
    goal_month,
    monthly_goal,
    allocation_mode,
    current_professional_id,
    updated_by
  ) values (
    p_store_id,
    v_session.admin_user_id,
    v_month_start,
    v_goal,
    v_mode,
    null,
    v_session.user_id
  )
  on conflict (store_id) do update
  set goal_month = excluded.goal_month,
      monthly_goal = excluded.monthly_goal,
      allocation_mode = excluded.allocation_mode,
      current_professional_id = null,
      updated_by = excluded.updated_by;

  update public.prospection_professionals pp
  set good_morning_seller_enabled = payload.enabled
  from (
    select
      (item.value->>'professional_id')::uuid as professional_id,
      coalesce((item.value->>'enabled')::boolean, true) as enabled
    from jsonb_array_elements(p_allocations) item
  ) payload
  where pp.id = payload.professional_id
    and pp.store_id = p_store_id
    and pp.admin_user_id = v_session.admin_user_id
    and pp.is_active = true
    and pp.archived_at is null
    and pp.good_morning_seller_enabled is distinct from payload.enabled;

  delete from public.good_morning_seller_allocations allocation
  where allocation.store_id = p_store_id;

  if v_mode = 'equal' then
    v_goal_cents := round(v_goal * 100)::bigint;
    v_base_cents := v_goal_cents / v_enabled_count;
    v_remainder_cents := (v_goal_cents % v_enabled_count)::integer;

    insert into public.good_morning_seller_allocations (
      store_id,
      admin_user_id,
      professional_id,
      goal_amount,
      queue_position
    )
    select
      p_store_id,
      v_session.admin_user_id,
      (item.value->>'professional_id')::uuid,
      (
        v_base_cents
        + case when (item.value->>'queue_position')::integer <= v_remainder_cents then 1 else 0 end
      )::numeric / 100,
      (item.value->>'queue_position')::integer
    from jsonb_array_elements(p_allocations) item
    where coalesce((item.value->>'enabled')::boolean, true);
  else
    insert into public.good_morning_seller_allocations (
      store_id,
      admin_user_id,
      professional_id,
      goal_amount,
      queue_position
    )
    select
      p_store_id,
      v_session.admin_user_id,
      (item.value->>'professional_id')::uuid,
      round((item.value->>'goal_amount')::numeric, 2),
      (item.value->>'queue_position')::integer
    from jsonb_array_elements(p_allocations) item
    where coalesce((item.value->>'enabled')::boolean, true);
  end if;

  if v_current_professional_id is null or not exists (
    select 1
    from public.good_morning_seller_allocations allocation
    join public.prospection_professionals pp
      on pp.id = allocation.professional_id
     and pp.store_id = allocation.store_id
     and pp.admin_user_id = allocation.admin_user_id
     and pp.is_active = true
     and pp.archived_at is null
     and pp.good_morning_seller_enabled = true
    where allocation.store_id = p_store_id
      and allocation.professional_id = v_current_professional_id
  ) then
    select allocation.professional_id
    into v_current_professional_id
    from public.good_morning_seller_allocations allocation
    join public.prospection_professionals pp
      on pp.id = allocation.professional_id
     and pp.store_id = allocation.store_id
     and pp.admin_user_id = allocation.admin_user_id
     and pp.is_active = true
     and pp.archived_at is null
     and pp.good_morning_seller_enabled = true
    where allocation.store_id = p_store_id
    order by allocation.queue_position
    limit 1;
  end if;

  update public.good_morning_seller_settings
  set current_professional_id = v_current_professional_id
  where store_id = p_store_id;

  return app_private.rpc_get_good_morning_seller_workspace(p_session_token, p_store_id);
end;
$$;

create or replace function app_private.rpc_advance_good_morning_seller_turn(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_workspace jsonb;
  v_current uuid;
  v_current_position integer := 0;
  v_next uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if not app_private.good_morning_seller_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  -- Serializa com alteracoes da equipe e com o salvamento da fila. A ordem
  -- cliente -> profissionais -> configuracao evita deadlocks entre os RPCs.
  perform 1
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and st.attendance_enabled = true
    and st.good_morning_seller_enabled = true
  for no key update;

  if not found then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  if not app_private.good_morning_seller_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  perform 1
  from public.prospection_professionals pp
  where pp.store_id = p_store_id
    and pp.admin_user_id = v_session.admin_user_id
    and pp.is_active = true
    and pp.archived_at is null
  order by pp.id
  for update;

  select settings.current_professional_id
  into v_current
  from public.good_morning_seller_settings settings
  where settings.store_id = p_store_id
    and settings.goal_month = date_trunc('month', timezone('America/Sao_Paulo', now()))::date
  for update;

  if not found then
    raise exception 'Configure a meta deste mês antes de usar a fila.';
  end if;

  v_workspace := app_private.rpc_get_good_morning_seller_workspace(
    p_session_token,
    p_store_id
  );

  if coalesce((v_workspace->>'configured')::boolean, false) is false then
    raise exception 'A equipe mudou. Revise e salve a meta e a fila antes de avançar.';
  end if;

  select coalesce(allocation.queue_position, 0)
  into v_current_position
  from public.good_morning_seller_allocations allocation
  join public.prospection_professionals pp
    on pp.id = allocation.professional_id
   and pp.store_id = allocation.store_id
   and pp.admin_user_id = allocation.admin_user_id
   and pp.is_active = true
   and pp.archived_at is null
   and pp.good_morning_seller_enabled = true
  where allocation.store_id = p_store_id
    and allocation.professional_id = v_current;

  select allocation.professional_id
  into v_next
  from public.good_morning_seller_allocations allocation
  join public.prospection_professionals pp
    on pp.id = allocation.professional_id
   and pp.store_id = allocation.store_id
   and pp.admin_user_id = allocation.admin_user_id
   and pp.is_active = true
   and pp.archived_at is null
   and pp.good_morning_seller_enabled = true
  where allocation.store_id = p_store_id
    and allocation.queue_position > v_current_position
  order by allocation.queue_position
  limit 1;

  if v_next is null then
    select allocation.professional_id
    into v_next
    from public.good_morning_seller_allocations allocation
    join public.prospection_professionals pp
      on pp.id = allocation.professional_id
     and pp.store_id = allocation.store_id
     and pp.admin_user_id = allocation.admin_user_id
     and pp.is_active = true
     and pp.archived_at is null
     and pp.good_morning_seller_enabled = true
    where allocation.store_id = p_store_id
    order by allocation.queue_position
    limit 1;
  end if;

  if v_next is null then
    raise exception 'A fila não possui vendedores participantes.';
  end if;

  update public.good_morning_seller_settings
  set current_professional_id = v_next,
      updated_by = v_session.user_id
  where store_id = p_store_id;

  return app_private.rpc_get_good_morning_seller_workspace(p_session_token, p_store_id);
end;
$$;

revoke all on function app_private.rpc_get_prospection_configuration_with_bonus_schedule(text)
  from public, anon, authenticated;
revoke all on function app_private.prospection_configuration_revision(uuid)
  from public, anon, authenticated;
revoke all on function app_private.rpc_save_prospection_configuration_with_bonus_schedule(text, uuid, jsonb)
  from public, anon, authenticated;
revoke all on function app_private.rpc_get_prospection_weekly_bonus_summary(text, uuid)
  from public, anon, authenticated;

grant execute on function app_private.rpc_get_prospection_configuration_with_bonus_schedule(text)
  to anon, authenticated;
grant execute on function app_private.rpc_save_prospection_configuration_with_bonus_schedule(text, uuid, jsonb)
  to anon, authenticated;
grant execute on function app_private.rpc_get_prospection_weekly_bonus_summary(text, uuid)
  to anon, authenticated;

revoke all on function app_private.rpc_set_prospection_outcome(text, uuid, boolean, boolean, numeric, text)
  from public, anon, authenticated;
revoke all on function app_private.rpc_list_prospection_bonus_purchases(text, date, date, uuid)
  from public, anon, authenticated;
revoke all on function app_private.rpc_get_good_morning_seller_workspace(text, uuid)
  from public, anon, authenticated;
revoke all on function app_private.rpc_save_good_morning_seller_settings(text, uuid, numeric, text, jsonb)
  from public, anon, authenticated;
revoke all on function app_private.rpc_advance_good_morning_seller_turn(text, uuid)
  from public, anon, authenticated;

grant execute on function app_private.rpc_set_prospection_outcome(text, uuid, boolean, boolean, numeric, text)
  to anon, authenticated;
grant execute on function app_private.rpc_list_prospection_bonus_purchases(text, date, date, uuid)
  to anon, authenticated;
grant execute on function app_private.rpc_get_good_morning_seller_workspace(text, uuid)
  to anon, authenticated;
grant execute on function app_private.rpc_save_good_morning_seller_settings(text, uuid, numeric, text, jsonb)
  to anon, authenticated;
grant execute on function app_private.rpc_advance_good_morning_seller_turn(text, uuid)
  to anon, authenticated;

revoke all on function public.lc_get_prospection_configuration(text) from public;
revoke all on function public.lc_save_prospection_configuration(text, uuid, jsonb) from public;
revoke all on function public.lc_get_prospection_weekly_bonus_summary(text, uuid) from public;
grant execute on function public.lc_get_prospection_configuration(text) to anon, authenticated;
grant execute on function public.lc_save_prospection_configuration(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.lc_get_prospection_weekly_bonus_summary(text, uuid) to anon, authenticated;

comment on column public.prospection_store_settings.bonus_payment_weekday is
  'Dia ISO (1=segunda, 7=domingo) para pagar, na semana seguinte, o fechamento semanal anterior.';
comment on column public.prospection_professionals.good_morning_seller_enabled is
  'Participa da fila e do rateio do Bom Dia Vendedor sem alterar o cadastro geral do profissional.';
comment on function public.lc_get_prospection_weekly_bonus_summary(text, uuid) is
  'Resumo semanal agregado, sem dados pessoais, sempre de segunda ate hoje mesmo quando a semana cruza meses.';
comment on function public.lc_save_prospection_configuration(text, uuid, jsonb) is
  'Salva a configuracao atomica de Prospeccoes e a agenda semanal de pagamento autorizada para Admin ou Agencia.';
comment on function public.lc_save_good_morning_seller_settings(text, uuid, numeric, text, jsonb) is
  'Salva meta, fila e participacao individual; enabled ausente permanece true para compatibilidade.';

notify pgrst, 'reload schema';

commit;
