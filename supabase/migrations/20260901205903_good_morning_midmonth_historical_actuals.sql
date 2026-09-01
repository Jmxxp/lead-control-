-- Bom Dia Vendedor | realizado anterior à primeira configuração mensal.
--
-- O realizado sempre vem de TODOS os atendimentos operacionais do mês,
-- inclusive os gravados antes de existir configuração. No dia da primeira
-- configuração do mês, vendas já registradas também entram no saldo diário
-- inicial; vendas posteriores continuam sem mover o alvo durante o expediente.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';

alter table public.good_morning_seller_settings
  add column if not exists goal_configured_at timestamptz,
  add column if not exists goal_configuration_actuals_cents jsonb
    not null default '{"month":0,"week":0,"today":0,"professionals":{}}'::jsonb;

create or replace function app_private.capture_good_morning_actuals_cents(
  p_store_id uuid,
  p_admin_user_id uuid,
  p_day date,
  p_created_before timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month_start date;
  v_month_end date;
  v_iso_week_start date;
  v_iso_week_end date;
  v_week_start date;
  v_week_end date;
  v_month_cents bigint := 0;
  v_week_cents bigint := 0;
  v_today_cents bigint := 0;
  v_professionals jsonb := '{}'::jsonb;
begin
  if p_store_id is null or p_admin_user_id is null or p_day is null then
    raise exception 'Cliente, administrador e data são obrigatórios para o snapshot.';
  end if;

  v_month_start := pg_catalog.date_trunc('month', p_day)::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;
  v_iso_week_start := p_day - (extract(isodow from p_day)::integer - 1);
  v_iso_week_end := p_day + (7 - extract(isodow from p_day)::integer);
  v_week_start := greatest(v_month_start, v_iso_week_start);
  v_week_end := least(v_month_end, v_iso_week_end);

  select
    coalesce(pg_catalog.sum(
      pg_catalog.round(attendance.purchase_value * 100)::bigint
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round(attendance.purchase_value * 100)::bigint
    ) filter (
      where pg_catalog.timezone(
        'America/Sao_Paulo', attendance.attended_at
      )::date between v_week_start and v_week_end
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round(attendance.purchase_value * 100)::bigint
    ) filter (
      where pg_catalog.timezone(
        'America/Sao_Paulo', attendance.attended_at
      )::date = p_day
    ), 0)::bigint
  into v_month_cents, v_week_cents, v_today_cents
  from public.attendances attendance
  where attendance.store_id = p_store_id
    and attendance.admin_user_id = p_admin_user_id
    and attendance.tag = 'purchase'
    and attendance.purchase_value > 0
    and attendance.attended_at >= (
      v_month_start::timestamp at time zone 'America/Sao_Paulo'
    )
    and attendance.attended_at < (
      (v_month_end + 1)::timestamp at time zone 'America/Sao_Paulo'
    )
    and (
      p_created_before is null
      or attendance.created_at < p_created_before
    );

  with actuals as (
    select
      attendance.professional_id,
      coalesce(pg_catalog.sum(
        pg_catalog.round(attendance.purchase_value * 100)::bigint
      ), 0)::bigint as month_cents,
      coalesce(pg_catalog.sum(
        pg_catalog.round(attendance.purchase_value * 100)::bigint
      ) filter (
        where pg_catalog.timezone(
          'America/Sao_Paulo', attendance.attended_at
        )::date between v_week_start and v_week_end
      ), 0)::bigint as week_cents,
      coalesce(pg_catalog.sum(
        pg_catalog.round(attendance.purchase_value * 100)::bigint
      ) filter (
        where pg_catalog.timezone(
          'America/Sao_Paulo', attendance.attended_at
        )::date = p_day
      ), 0)::bigint as today_cents
    from public.attendances attendance
    where attendance.store_id = p_store_id
      and attendance.admin_user_id = p_admin_user_id
      and attendance.professional_id is not null
      and attendance.tag = 'purchase'
      and attendance.purchase_value > 0
      and attendance.attended_at >= (
        v_month_start::timestamp at time zone 'America/Sao_Paulo'
      )
      and attendance.attended_at < (
        (v_month_end + 1)::timestamp at time zone 'America/Sao_Paulo'
      )
      and (
        p_created_before is null
        or attendance.created_at < p_created_before
      )
    group by attendance.professional_id
  )
  select coalesce(pg_catalog.jsonb_object_agg(
    actuals.professional_id::text,
    pg_catalog.jsonb_build_object(
      'month', actuals.month_cents,
      'week', actuals.week_cents,
      'today', actuals.today_cents
    )
    order by actuals.professional_id::text
  ), '{}'::jsonb)
  into v_professionals
  from actuals;

  return pg_catalog.jsonb_build_object(
    'month', v_month_cents,
    'week', v_week_cents,
    'today', v_today_cents,
    'professionals', v_professionals
  );
end;
$$;

-- Uma linha de settings pode existir sem ser uma configuracao valida (por
-- exemplo, depois de pausar um participante). O cutoff so existe quando meta,
-- participantes, valores e fila fecham de fato. Para configuracoes historicas
-- sem timestamp proprio usamos um instante conservador: criacao da linha se
-- ela ocorreu no mes da meta; caso contrario, o inicio daquele mes. Assim
-- avancos de rotacao e re-saves legados nao fingem uma primeira configuracao.
alter table public.good_morning_seller_settings
  disable trigger good_morning_seller_settings_updated_at;

with validity as (
  select
    settings.store_id,
    settings.admin_user_id,
    settings.goal_month,
    settings.created_at,
    (
      exists (
        select 1
        from public.prospection_professionals professional
        where professional.store_id = settings.store_id
          and professional.admin_user_id = settings.admin_user_id
          and professional.is_active = true
          and professional.archived_at is null
          and professional.good_morning_seller_enabled = true
      )
      and (
        select pg_catalog.count(*)
        from public.good_morning_seller_allocations allocation
        where allocation.store_id = settings.store_id
          and allocation.admin_user_id = settings.admin_user_id
      ) = (
        select pg_catalog.count(*)
        from public.prospection_professionals professional
        where professional.store_id = settings.store_id
          and professional.admin_user_id = settings.admin_user_id
          and professional.is_active = true
          and professional.archived_at is null
          and professional.good_morning_seller_enabled = true
      )
      and not exists (
        select 1
        from public.prospection_professionals professional
        left join public.good_morning_seller_allocations allocation
          on allocation.store_id = professional.store_id
         and allocation.admin_user_id = professional.admin_user_id
         and allocation.professional_id = professional.id
        where professional.store_id = settings.store_id
          and professional.admin_user_id = settings.admin_user_id
          and professional.is_active = true
          and professional.archived_at is null
          and professional.good_morning_seller_enabled = true
          and allocation.professional_id is null
      )
      and not exists (
        select 1
        from public.good_morning_seller_allocations allocation
        left join public.prospection_professionals professional
          on professional.id = allocation.professional_id
         and professional.store_id = allocation.store_id
         and professional.admin_user_id = allocation.admin_user_id
         and professional.is_active = true
         and professional.archived_at is null
         and professional.good_morning_seller_enabled = true
        where allocation.store_id = settings.store_id
          and allocation.admin_user_id = settings.admin_user_id
          and professional.id is null
      )
      and coalesce((
        select pg_catalog.sum(
          pg_catalog.round(allocation.goal_amount * 100)::bigint
        )
        from public.good_morning_seller_allocations allocation
        where allocation.store_id = settings.store_id
          and allocation.admin_user_id = settings.admin_user_id
      ), 0) = pg_catalog.round(settings.monthly_goal * 100)::bigint
      and coalesce((
        select pg_catalog.min(allocation.queue_position)
        from public.good_morning_seller_allocations allocation
        where allocation.store_id = settings.store_id
          and allocation.admin_user_id = settings.admin_user_id
      ), 0) = 1
      and coalesce((
        select pg_catalog.max(allocation.queue_position)
        from public.good_morning_seller_allocations allocation
        where allocation.store_id = settings.store_id
          and allocation.admin_user_id = settings.admin_user_id
      ), 0) = (
        select pg_catalog.count(*)
        from public.good_morning_seller_allocations allocation
        where allocation.store_id = settings.store_id
          and allocation.admin_user_id = settings.admin_user_id
      )
      and exists (
        select 1
        from public.good_morning_seller_allocations allocation
        join public.prospection_professionals professional
          on professional.id = allocation.professional_id
         and professional.store_id = allocation.store_id
         and professional.admin_user_id = allocation.admin_user_id
         and professional.is_active = true
         and professional.archived_at is null
         and professional.good_morning_seller_enabled = true
        where allocation.store_id = settings.store_id
          and allocation.admin_user_id = settings.admin_user_id
          and allocation.professional_id = settings.current_professional_id
      )
    ) as is_configured
  from public.good_morning_seller_settings settings
), inferred as (
  select
    validity.store_id,
    validity.admin_user_id,
    case
      when validity.is_configured then
        case
          when pg_catalog.date_trunc(
            'month',
            pg_catalog.timezone('America/Sao_Paulo', validity.created_at)
          )::date = validity.goal_month
            then validity.created_at
          else validity.goal_month::timestamp
            at time zone 'America/Sao_Paulo'
        end
      else null::timestamptz
    end as configured_at
  from validity
)
update public.good_morning_seller_settings settings
set goal_configured_at = inferred.configured_at,
    goal_configuration_actuals_cents = case
      when inferred.configured_at is null then
        '{"month":0,"week":0,"today":0,"professionals":{}}'::jsonb
      else app_private.capture_good_morning_actuals_cents(
        inferred.store_id,
        inferred.admin_user_id,
        pg_catalog.timezone(
          'America/Sao_Paulo', inferred.configured_at
        )::date,
        inferred.configured_at
      )
    end
from inferred
where inferred.store_id = settings.store_id
  and settings.goal_configured_at is null;

alter table public.good_morning_seller_settings
  enable trigger good_morning_seller_settings_updated_at;

alter table public.good_morning_seller_settings
  add constraint good_morning_seller_settings_configuration_actuals_check
  check (
    pg_catalog.jsonb_typeof(goal_configuration_actuals_cents) = 'object'
    and coalesce(goal_configuration_actuals_cents->>'month', '') ~ '^[0-9]+$'
    and coalesce(goal_configuration_actuals_cents->>'week', '') ~ '^[0-9]+$'
    and coalesce(goal_configuration_actuals_cents->>'today', '') ~ '^[0-9]+$'
    and pg_catalog.jsonb_typeof(
      goal_configuration_actuals_cents->'professionals'
    ) = 'object'
  );

create or replace function app_private.stamp_good_morning_goal_configuration()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    -- A linha so se torna configurada depois que as alocacoes fecham.
    new.goal_configured_at := null;
    new.goal_configuration_actuals_cents :=
      '{"month":0,"week":0,"today":0,"professionals":{}}'::jsonb;
  elsif new.goal_month is distinct from old.goal_month then
    -- O primeiro save valido do novo mes gravara o instante logo depois.
    new.goal_configured_at := null;
    new.goal_configuration_actuals_cents :=
      '{"month":0,"week":0,"today":0,"professionals":{}}'::jsonb;
  else
    new.goal_configured_at := old.goal_configured_at;
    new.goal_configuration_actuals_cents :=
      old.goal_configuration_actuals_cents;
  end if;
  return new;
end;
$$;


drop trigger if exists good_morning_seller_settings_goal_configured_at
  on public.good_morning_seller_settings;
create trigger good_morning_seller_settings_goal_configured_at
before insert or update of goal_month
on public.good_morning_seller_settings
for each row execute function app_private.stamp_good_morning_goal_configuration();

create or replace function app_private.mark_good_morning_goal_configured(
  p_session_token text,
  p_store_id uuid,
  p_workspace jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_workspace jsonb := coalesce(p_workspace, '{}'::jsonb);
  v_authoritative_workspace jsonb;
  v_goal_month date;
  v_configuration_day date;
  v_goal_configured_at timestamptz;
  v_configuration_actuals_cents jsonb;
begin
  if not app_private.good_morning_seller_settings_manage_allowed(
    p_session_token,
    p_store_id
  ) then
    raise exception 'Somente o Admin ou a própria loja podem configurar o Bom Dia Vendedor.';
  end if;

  select *
  into v_session
  from app_private.session_user(p_session_token);

  -- Nao confiamos no JSON recebido: a helper possui EXECUTE para os papeis que
  -- chamam os wrappers SECURITY INVOKER. A configuracao e revalidada no banco
  -- antes de gravar o cutoff.
  v_authoritative_workspace :=
    app_private.rpc_get_good_morning_seller_workspace(
      p_session_token,
      p_store_id
    );

  if not coalesce(
    nullif(v_authoritative_workspace->>'configured', '')::boolean,
    false
  ) then
    return v_workspace || pg_catalog.jsonb_build_object(
      'goal_configured_at', null
    );
  end if;

  v_goal_month := coalesce(
    nullif(v_authoritative_workspace->>'goal_month', '')::date,
    pg_catalog.date_trunc(
      'month',
      pg_catalog.timezone('America/Sao_Paulo', pg_catalog.now())
    )::date
  );
  v_configuration_day := coalesce(
    nullif(v_authoritative_workspace->>'today', '')::date,
    pg_catalog.timezone('America/Sao_Paulo', pg_catalog.now())::date
  );

  select
    settings.goal_configured_at,
    settings.goal_configuration_actuals_cents
  into v_goal_configured_at, v_configuration_actuals_cents
  from public.good_morning_seller_settings settings
  where settings.store_id = p_store_id
    and settings.admin_user_id = v_session.admin_user_id
    and settings.goal_month = v_goal_month
  for update;

  if not found then
    raise exception 'A configuração válida do Bom Dia Vendedor não foi encontrada.';
  end if;

  if v_goal_configured_at is null then
    -- now() usa o mesmo instante transacional empregado pelas RPCs base. O
    -- snapshot inclui todas as linhas visiveis nesta captura; created_at nao e
    -- usado para decidir o que pertence ao saldo inicial.
    v_goal_configured_at := pg_catalog.now();
    v_configuration_actuals_cents :=
      app_private.capture_good_morning_actuals_cents(
        p_store_id,
        v_session.admin_user_id,
        v_configuration_day,
        null::timestamptz
      );

    update public.good_morning_seller_settings settings
    set goal_configured_at = v_goal_configured_at,
        goal_configuration_actuals_cents = v_configuration_actuals_cents
    where settings.store_id = p_store_id
      and settings.admin_user_id = v_session.admin_user_id
      and settings.goal_month = v_goal_month
      and settings.goal_configured_at is null;
  end if;

  return v_workspace || pg_catalog.jsonb_build_object(
    'goal_configured_at', v_goal_configured_at,
    'goal_configuration_actuals_cents', v_configuration_actuals_cents
  );
end;
$$;

create or replace function app_private.refresh_good_morning_historical_actuals(
  p_session_token text,
  p_store_id uuid,
  p_workspace jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_workspace jsonb := coalesce(p_workspace, '{}'::jsonb);
  v_today date;
  v_month_start date;
  v_month_end date;
  v_week_start date;
  v_week_end date;
  v_goal_configured_at timestamptz;
  v_configuration_snapshot jsonb :=
    '{"month":0,"week":0,"today":0,"professionals":{}}'::jsonb;
  v_snapshot_active boolean := false;
  v_snapshot_month_actual numeric := 0;
  v_snapshot_week_actual numeric := 0;
  v_snapshot_today_actual numeric := 0;
  v_month_actual numeric := 0;
  v_week_actual numeric := 0;
  v_today_actual numeric := 0;
  v_professionals jsonb := '[]'::jsonb;
  v_goals jsonb := '{}'::jsonb;
  v_month_goal jsonb := '{}'::jsonb;
  v_week_goal jsonb := '{}'::jsonb;
  v_today_goal jsonb := '{}'::jsonb;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if not app_private.good_morning_seller_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  v_today := coalesce(
    nullif(v_workspace->>'today', '')::date,
    pg_catalog.timezone('America/Sao_Paulo', pg_catalog.now())::date
  );
  v_month_start := pg_catalog.date_trunc('month', v_today)::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;
  v_week_start := greatest(
    v_month_start,
    coalesce(
      nullif(v_workspace->>'week_start', '')::date,
      v_today - (extract(isodow from v_today)::integer - 1)
    )
  );
  v_week_end := least(
    v_month_end,
    coalesce(
      nullif(v_workspace->>'week_end', '')::date,
      v_today + (7 - extract(isodow from v_today)::integer)
    )
  );

  select
    settings.goal_configured_at,
    settings.goal_configuration_actuals_cents
  into v_goal_configured_at, v_configuration_snapshot
  from public.good_morning_seller_settings settings
  where settings.store_id = p_store_id
    and settings.admin_user_id = v_session.admin_user_id
    and settings.goal_month = v_month_start;

  if pg_catalog.jsonb_typeof(v_configuration_snapshot) is distinct from 'object'
     or pg_catalog.jsonb_typeof(
       v_configuration_snapshot->'professionals'
     ) is distinct from 'object' then
    v_configuration_snapshot :=
      '{"month":0,"week":0,"today":0,"professionals":{}}'::jsonb;
  end if;

  v_snapshot_active :=
    coalesce(nullif(v_workspace->>'configured', '')::boolean, false)
    and pg_catalog.timezone(
      'America/Sao_Paulo', v_goal_configured_at
    )::date = v_today;

  if v_snapshot_active then
    v_snapshot_month_actual := coalesce(
      nullif(v_configuration_snapshot->>'month', '')::bigint,
      0
    )::numeric / 100;
    v_snapshot_week_actual := coalesce(
      nullif(v_configuration_snapshot->>'week', '')::bigint,
      0
    )::numeric / 100;
    v_snapshot_today_actual := coalesce(
      nullif(v_configuration_snapshot->>'today', '')::bigint,
      0
    )::numeric / 100;
  end if;

  -- Estes tres valores permanecem vivos para exibicao e para o recalculo dos
  -- dias seguintes. Nao existe filtro por instante de configuracao.
  select
    coalesce(pg_catalog.sum(attendance.purchase_value), 0),
    coalesce(pg_catalog.sum(attendance.purchase_value) filter (
      where pg_catalog.timezone(
        'America/Sao_Paulo', attendance.attended_at
      )::date between v_week_start and v_week_end
    ), 0),
    coalesce(pg_catalog.sum(attendance.purchase_value) filter (
      where pg_catalog.timezone(
        'America/Sao_Paulo', attendance.attended_at
      )::date = v_today
    ), 0)
  into v_month_actual, v_week_actual, v_today_actual
  from public.attendances attendance
  where attendance.store_id = p_store_id
    and attendance.admin_user_id = v_session.admin_user_id
    and attendance.tag = 'purchase'
    and attendance.purchase_value > 0
    and attendance.attended_at >= (
      v_month_start::timestamp at time zone 'America/Sao_Paulo'
    )
    and attendance.attended_at < (
      (v_month_end + 1)::timestamp at time zone 'America/Sao_Paulo'
    );

  with entries as (
    select
      items.ordinality,
      items.professional,
      case
        when coalesce(items.professional->>'id', '')
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          then (items.professional->>'id')::uuid
        else null::uuid
      end as professional_id
    from pg_catalog.jsonb_array_elements(
      case
        when pg_catalog.jsonb_typeof(v_workspace->'professionals') = 'array'
          then v_workspace->'professionals'
        else '[]'::jsonb
      end
    ) with ordinality as items(professional, ordinality)
  ), actuals as (
    select
      attendance.professional_id,
      coalesce(pg_catalog.sum(attendance.purchase_value), 0) as actual_month,
      coalesce(pg_catalog.sum(attendance.purchase_value) filter (
        where pg_catalog.timezone(
          'America/Sao_Paulo', attendance.attended_at
        )::date between v_week_start and v_week_end
      ), 0) as actual_week,
      coalesce(pg_catalog.sum(attendance.purchase_value) filter (
        where pg_catalog.timezone(
          'America/Sao_Paulo', attendance.attended_at
        )::date = v_today
      ), 0) as actual_today
    from public.attendances attendance
    where attendance.store_id = p_store_id
      and attendance.admin_user_id = v_session.admin_user_id
      and attendance.tag = 'purchase'
      and attendance.purchase_value > 0
      and attendance.attended_at >= (
        v_month_start::timestamp at time zone 'America/Sao_Paulo'
      )
      and attendance.attended_at < (
        (v_month_end + 1)::timestamp at time zone 'America/Sao_Paulo'
      )
    group by attendance.professional_id
  ), enriched as (
    select
      entries.ordinality,
      entries.professional,
      entries.professional_id,
      coalesce(actuals.actual_month, 0) as actual_month,
      coalesce(actuals.actual_week, 0) as actual_week,
      coalesce(actuals.actual_today, 0) as actual_today,
      case
        when v_snapshot_active and entries.professional_id is not null then
          coalesce(
            (v_configuration_snapshot->'professionals')
              ->entries.professional_id::text,
            '{}'::jsonb
          )
        else '{}'::jsonb
      end as configuration_actuals
    from entries
    left join actuals on actuals.professional_id = entries.professional_id
  )
  select coalesce(pg_catalog.jsonb_agg(
    enriched.professional || pg_catalog.jsonb_build_object(
      'actual_month', enriched.actual_month,
      'actual_week', enriched.actual_week,
      'actual_today', enriched.actual_today,
      'actual_month_at_configuration', coalesce(
        nullif(enriched.configuration_actuals->>'month', '')::bigint,
        0
      )::numeric / 100,
      'actual_week_at_configuration', coalesce(
        nullif(enriched.configuration_actuals->>'week', '')::bigint,
        0
      )::numeric / 100,
      'actual_today_before_configuration', coalesce(
        nullif(enriched.configuration_actuals->>'today', '')::bigint,
        0
      )::numeric / 100
    ) order by enriched.ordinality
  ), '[]'::jsonb)
  into v_professionals
  from enriched;

  v_goals := case
    when pg_catalog.jsonb_typeof(v_workspace->'goals') = 'object'
      then v_workspace->'goals'
    else '{}'::jsonb
  end;
  v_month_goal := case
    when pg_catalog.jsonb_typeof(v_goals->'month') = 'object'
      then v_goals->'month'
    else '{}'::jsonb
  end;
  v_week_goal := case
    when pg_catalog.jsonb_typeof(v_goals->'week') = 'object'
      then v_goals->'week'
    else '{}'::jsonb
  end;
  v_today_goal := case
    when pg_catalog.jsonb_typeof(v_goals->'today') = 'object'
      then v_goals->'today'
    else '{}'::jsonb
  end;

  v_goals := v_goals || pg_catalog.jsonb_build_object(
    'month', v_month_goal || pg_catalog.jsonb_build_object('actual', v_month_actual),
    'week', v_week_goal || pg_catalog.jsonb_build_object('actual', v_week_actual),
    'today', v_today_goal || pg_catalog.jsonb_build_object('actual', v_today_actual)
  );

  return v_workspace || pg_catalog.jsonb_build_object(
    'goals', v_goals,
    'professionals', v_professionals,
    'goal_configured_at', v_goal_configured_at,
    'goal_configuration_actuals_cents', v_configuration_snapshot,
    'configuration_actual_snapshot_active', v_snapshot_active,
    'actual_month_at_configuration', v_snapshot_month_actual,
    'actual_week_at_configuration', v_snapshot_week_actual,
    'actual_today_before_configuration', v_snapshot_today_actual,
    'configuration_actual_snapshot_strategy',
      'immutable_month_week_today_cents_v1',
    'historical_actuals_strategy',
      'full_operational_month_with_initial_configuration_cutoff_v1',
    'historical_actuals_include_preconfiguration', true
  );
end;
$$;

create or replace function app_private.rebalance_good_morning_with_configuration_cutoff(
  p_workspace jsonb
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_workspace jsonb := coalesce(p_workspace, '{}'::jsonb);
  v_calculation_workspace jsonb;
  v_result jsonb;
  v_original_professionals jsonb;
  v_calculation_professionals jsonb;
  v_restored_professionals jsonb;
  v_snapshot_active boolean := false;
  v_original_month_actual numeric := 0;
  v_original_week_actual numeric := 0;
  v_original_today_actual numeric := 0;
  v_snapshot_month_actual numeric := 0;
  v_snapshot_week_actual numeric := 0;
  v_snapshot_today_actual numeric := 0;
  v_goals jsonb;
  v_month_goal jsonb;
  v_week_goal jsonb;
  v_today_goal jsonb;
begin
  v_snapshot_active :=
    coalesce(
      nullif(v_workspace->>'configuration_actual_snapshot_active', '')::boolean,
      false
    )
    and coalesce(nullif(v_workspace->>'configured', '')::boolean, false);

  v_original_month_actual := coalesce(
    nullif(v_workspace #>> '{goals,month,actual}', '')::numeric,
    0
  );
  v_original_week_actual := coalesce(
    nullif(v_workspace #>> '{goals,week,actual}', '')::numeric,
    0
  );
  v_original_today_actual := coalesce(
    nullif(v_workspace #>> '{goals,today,actual}', '')::numeric,
    0
  );
  v_snapshot_month_actual := coalesce(
    nullif(v_workspace->>'actual_month_at_configuration', '')::numeric,
    0
  );
  v_snapshot_week_actual := coalesce(
    nullif(v_workspace->>'actual_week_at_configuration', '')::numeric,
    0
  );
  v_snapshot_today_actual := coalesce(
    nullif(v_workspace->>'actual_today_before_configuration', '')::numeric,
    0
  );

  v_calculation_workspace := v_workspace;
  v_original_professionals := case
    when pg_catalog.jsonb_typeof(v_workspace->'professionals') = 'array'
      then v_workspace->'professionals'
    else '[]'::jsonb
  end;

  if v_snapshot_active then
    v_goals := case
      when pg_catalog.jsonb_typeof(v_calculation_workspace->'goals') = 'object'
        then v_calculation_workspace->'goals'
      else '{}'::jsonb
    end;
    v_month_goal := case
      when pg_catalog.jsonb_typeof(v_goals->'month') = 'object'
        then v_goals->'month'
      else '{}'::jsonb
    end;
    v_week_goal := case
      when pg_catalog.jsonb_typeof(v_goals->'week') = 'object'
        then v_goals->'week'
      else '{}'::jsonb
    end;
    v_today_goal := case
      when pg_catalog.jsonb_typeof(v_goals->'today') = 'object'
        then v_goals->'today'
      else '{}'::jsonb
    end;
    v_goals := v_goals || pg_catalog.jsonb_build_object(
      'month', v_month_goal || pg_catalog.jsonb_build_object(
        'actual', v_snapshot_month_actual
      ),
      'week', v_week_goal || pg_catalog.jsonb_build_object(
        'actual', v_snapshot_week_actual
      ),
      -- Todo o realizado do snapshot semanal ja existia antes do alvo inicial.
      'today', v_today_goal || pg_catalog.jsonb_build_object('actual', 0)
    );
    v_calculation_workspace := v_calculation_workspace
      || pg_catalog.jsonb_build_object('goals', v_goals);

    select coalesce(pg_catalog.jsonb_agg(
      entries.professional || pg_catalog.jsonb_build_object(
        'actual_month', coalesce(
          nullif(
            entries.professional->>'actual_month_at_configuration',
            ''
          )::numeric,
          0
        ),
        'actual_week', coalesce(
          nullif(
            entries.professional->>'actual_week_at_configuration',
            ''
          )::numeric,
          0
        ),
        'actual_today', 0
      ) order by entries.ordinality
    ), '[]'::jsonb)
    into v_calculation_professionals
    from pg_catalog.jsonb_array_elements(v_original_professionals)
      with ordinality as entries(professional, ordinality);

    v_calculation_workspace := v_calculation_workspace
      || pg_catalog.jsonb_build_object(
        'professionals', v_calculation_professionals
      );
  else
    v_calculation_professionals := v_original_professionals;
  end if;

  v_result := app_private.rebalance_good_morning_daily_goals(
    v_calculation_workspace
  );

  select coalesce(pg_catalog.jsonb_agg(
    result_entries.professional || pg_catalog.jsonb_build_object(
      'actual_month', coalesce(
        nullif(original_entries.professional->>'actual_month', '')::numeric,
        0
      ),
      'actual_week', coalesce(
        nullif(original_entries.professional->>'actual_week', '')::numeric,
        0
      ),
      'actual_today', coalesce(
        nullif(original_entries.professional->>'actual_today', '')::numeric,
        0
      ),
      'actual_month_at_configuration', coalesce(
        nullif(
          original_entries.professional->>'actual_month_at_configuration',
          ''
        )::numeric,
        0
      ),
      'actual_week_at_configuration', coalesce(
        nullif(
          original_entries.professional->>'actual_week_at_configuration',
          ''
        )::numeric,
        0
      ),
      'actual_today_before_configuration', coalesce(
        nullif(
          original_entries.professional->>'actual_today_before_configuration',
          ''
        )::numeric,
        0
      )
    ) order by result_entries.ordinality
  ), '[]'::jsonb)
  into v_restored_professionals
  from pg_catalog.jsonb_array_elements(
    coalesce(v_result->'professionals', '[]'::jsonb)
  ) with ordinality as result_entries(professional, ordinality)
  join pg_catalog.jsonb_array_elements(v_original_professionals)
    with ordinality as original_entries(professional, ordinality)
    on original_entries.ordinality = result_entries.ordinality;

  v_goals := case
    when pg_catalog.jsonb_typeof(v_result->'goals') = 'object'
      then v_result->'goals'
    else '{}'::jsonb
  end;
  v_month_goal := case
    when pg_catalog.jsonb_typeof(v_goals->'month') = 'object'
      then v_goals->'month'
    else '{}'::jsonb
  end;
  v_week_goal := case
    when pg_catalog.jsonb_typeof(v_goals->'week') = 'object'
      then v_goals->'week'
    else '{}'::jsonb
  end;
  v_today_goal := case
    when pg_catalog.jsonb_typeof(v_goals->'today') = 'object'
      then v_goals->'today'
    else '{}'::jsonb
  end;
  v_goals := v_goals || pg_catalog.jsonb_build_object(
    'month', v_month_goal || pg_catalog.jsonb_build_object(
      'actual', v_original_month_actual
    ),
    'week', v_week_goal || pg_catalog.jsonb_build_object(
      'actual', v_original_week_actual
    ),
    'today', v_today_goal || pg_catalog.jsonb_build_object(
      'actual', v_original_today_actual
    )
  );

  return v_result || pg_catalog.jsonb_build_object(
    'goals', v_goals,
    'professionals', v_restored_professionals,
    'initial_configuration_today_actual', case
      when v_snapshot_active then v_snapshot_today_actual
      else 0
    end,
    'initial_configuration_cutoff_applied', v_snapshot_active,
    'configuration_actual_snapshot_active', v_snapshot_active,
    'configuration_actual_snapshot_strategy',
      'immutable_month_week_today_cents_v1'
  );
end;
$$;

-- Todas as saidas publicas seguem a mesma ordem: operacao original, calendario,
-- realizado autoritativo e, por ultimo, o calculo hierarquico em centavos.
create or replace function public.lc_get_good_morning_seller_workspace(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rebalance_good_morning_with_configuration_cutoff(
    app_private.refresh_good_morning_historical_actuals(
      p_session_token,
      p_store_id,
      app_private.attach_good_morning_seller_closed_days(
        p_session_token,
        p_store_id,
        app_private.rpc_get_good_morning_seller_workspace(
          p_session_token,
          p_store_id
        )
      )
    )
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', app_private.good_morning_seller_settings_manage_allowed(
      p_session_token,
      p_store_id
    )
  );
$$;

create or replace function public.lc_save_good_morning_seller_settings(
  p_session_token text,
  p_store_id uuid,
  p_monthly_goal numeric,
  p_allocation_mode text,
  p_allocations jsonb
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rebalance_good_morning_with_configuration_cutoff(
    app_private.refresh_good_morning_historical_actuals(
      p_session_token,
      p_store_id,
      app_private.attach_good_morning_seller_closed_days(
        p_session_token,
        p_store_id,
        app_private.mark_good_morning_goal_configured(
          p_session_token,
          p_store_id,
          app_private.rpc_save_good_morning_seller_settings_store_only(
            p_session_token,
            p_store_id,
            p_monthly_goal,
            p_allocation_mode,
            p_allocations
          )
        )
      )
    )
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', true
  );
$$;

create or replace function public.lc_save_good_morning_seller_settings_v2(
  p_session_token text,
  p_store_id uuid,
  p_monthly_goal numeric,
  p_allocation_mode text,
  p_allocations jsonb,
  p_closed_days jsonb default '[]'::jsonb
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rebalance_good_morning_with_configuration_cutoff(
    app_private.refresh_good_morning_historical_actuals(
      p_session_token,
      p_store_id,
      app_private.attach_good_morning_seller_closed_days(
        p_session_token,
        p_store_id,
        app_private.mark_good_morning_goal_configured(
          p_session_token,
          p_store_id,
          app_private.rpc_save_good_morning_seller_settings_with_closed_days(
            p_session_token,
            p_store_id,
            p_monthly_goal,
            p_allocation_mode,
            p_allocations,
            p_closed_days
          )
        )
      )
    )
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', true
  );
$$;

create or replace function public.lc_advance_good_morning_seller_turn(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rebalance_good_morning_with_configuration_cutoff(
    app_private.refresh_good_morning_historical_actuals(
      p_session_token,
      p_store_id,
      app_private.attach_good_morning_seller_closed_days(
        p_session_token,
        p_store_id,
        app_private.rpc_advance_good_morning_seller_turn_store_only(
          p_session_token,
          p_store_id
        )
      )
    )
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', true
  );
$$;

create or replace function public.lc_set_good_morning_seller_participation(
  p_session_token text,
  p_store_id uuid,
  p_professional_id uuid,
  p_enabled boolean
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rebalance_good_morning_with_configuration_cutoff(
    app_private.refresh_good_morning_historical_actuals(
      p_session_token,
      p_store_id,
      app_private.attach_good_morning_seller_closed_days(
        p_session_token,
        p_store_id,
        app_private.rpc_set_good_morning_seller_participation(
          p_session_token,
          p_store_id,
          p_professional_id,
          p_enabled
        )
      )
    )
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', true
  );
$$;

revoke all on function app_private.capture_good_morning_actuals_cents(
  uuid, uuid, date, timestamptz
) from public, anon, authenticated;

revoke all on function app_private.stamp_good_morning_goal_configuration()
  from public, anon, authenticated;

revoke all on function app_private.mark_good_morning_goal_configured(text, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function app_private.mark_good_morning_goal_configured(text, uuid, jsonb)
  to anon, authenticated;

revoke all on function app_private.refresh_good_morning_historical_actuals(text, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function app_private.refresh_good_morning_historical_actuals(text, uuid, jsonb)
  to anon, authenticated;

revoke all on function app_private.rebalance_good_morning_with_configuration_cutoff(jsonb)
  from public, anon, authenticated;
grant execute on function app_private.rebalance_good_morning_with_configuration_cutoff(jsonb)
  to anon, authenticated;

revoke all on function public.lc_get_good_morning_seller_workspace(text, uuid)
  from public;
grant execute on function public.lc_get_good_morning_seller_workspace(text, uuid)
  to anon, authenticated;

revoke all on function public.lc_save_good_morning_seller_settings(
  text, uuid, numeric, text, jsonb
) from public;
grant execute on function public.lc_save_good_morning_seller_settings(
  text, uuid, numeric, text, jsonb
) to anon, authenticated;

revoke all on function public.lc_save_good_morning_seller_settings_v2(
  text, uuid, numeric, text, jsonb, jsonb
) from public;
grant execute on function public.lc_save_good_morning_seller_settings_v2(
  text, uuid, numeric, text, jsonb, jsonb
) to anon, authenticated;

revoke all on function public.lc_advance_good_morning_seller_turn(text, uuid)
  from public;
grant execute on function public.lc_advance_good_morning_seller_turn(text, uuid)
  to anon, authenticated;

revoke all on function public.lc_set_good_morning_seller_participation(
  text, uuid, uuid, boolean
) from public;
grant execute on function public.lc_set_good_morning_seller_participation(
  text, uuid, uuid, boolean
) to anon, authenticated;

comment on column public.good_morning_seller_settings.goal_configured_at is
  'Instante da primeira configuracao valida da meta no goal_month; preservado em re-saves do mesmo mes e reiniciado na troca mensal.';

comment on column public.good_morning_seller_settings.goal_configuration_actuals_cents is
  'Snapshot imutavel em centavos dos realizados de mes, semana e dia do time e por profissional na primeira configuracao valida do mes.';

comment on function app_private.capture_good_morning_actuals_cents(
  uuid, uuid, date, timestamptz
) is
  'Captura interna dos realizados do mes/semana/dia em centavos; sem EXECUTE para papeis da Data API.';

comment on function app_private.refresh_good_morning_historical_actuals(text, uuid, jsonb) is
  'Reconsulta os realizados vivos para exibicao e anexa o snapshot imutavel de mes/semana/dia capturado na primeira configuracao valida.';

comment on function app_private.rebalance_good_morning_with_configuration_cutoff(jsonb) is
  'No dia inicial calcula semana/dia integralmente pelo snapshot imutavel e restaura os realizados vivos apenas para exibicao; nos dias seguintes usa os realizados atuais.';

comment on function public.lc_get_good_morning_seller_workspace(text, uuid) is
  'Workspace do Bom Dia Vendedor com realizados autoritativos do mes/semana/dia, calendario da loja e metas hierarquicas em centavos.';

comment on function public.lc_save_good_morning_seller_settings_v2(
  text, uuid, numeric, text, jsonb, jsonb
) is
  'Salva meta, rotacao e calendario; a primeira configuracao valida do mes incorpora imediatamente todo realizado anterior.';

do $qa$
declare
  v_workspace jsonb;
  v_result jsonb;
  v_sum_week numeric;
  v_sum_today numeric;
begin
  if greatest(
       '2026-09-01'::date,
       '2026-09-01'::date
         - (extract(isodow from '2026-09-01'::date)::integer - 1)
     ) <> '2026-09-01'::date
     or least(
       '2026-09-30'::date,
       '2026-09-01'::date
         + (7 - extract(isodow from '2026-09-01'::date)::integer)
     ) <> '2026-09-06'::date then
    raise exception 'QA snapshot: primeira semana parcial nao termina no domingo ISO.';
  end if;

  -- Snapshot inicial: quarta-feira 16/09/2026, mes 26k, realizado 9k/3k/1k.
  v_workspace := pg_catalog.jsonb_build_object(
    'configured', true,
    'configuration_actual_snapshot_active', true,
    'today', '2026-09-16',
    'week_start', '2026-09-14',
    'week_end', '2026-09-20',
    'monthly_goal', 26000,
    'closed_days', '[]'::jsonb,
    'actual_month_at_configuration', 9000,
    'actual_week_at_configuration', 3000,
    'actual_today_before_configuration', 1000,
    'goals', pg_catalog.jsonb_build_object(
      'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 9000),
      'week', pg_catalog.jsonb_build_object('target', 0, 'actual', 3000),
      'today', pg_catalog.jsonb_build_object('target', 0, 'actual', 1000)
    ),
    'professionals', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000001',
        'name', 'A',
        'good_morning_seller_enabled', true,
        'goal_month', 13000,
        'actual_month', 4500,
        'actual_week', 1500,
        'actual_today', 700,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 700
      ),
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000002',
        'name', 'B',
        'good_morning_seller_enabled', true,
        'goal_month', 13000,
        'actual_month', 4500,
        'actual_week', 1500,
        'actual_today', 300,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 300
      )
    )
  );

  v_result := app_private.rebalance_good_morning_with_configuration_cutoff(
    v_workspace
  );

  select
    coalesce(pg_catalog.sum((entry.value->>'goal_week')::numeric), 0),
    coalesce(pg_catalog.sum((entry.value->>'goal_today')::numeric), 0)
  into v_sum_week, v_sum_today
  from pg_catalog.jsonb_array_elements(v_result->'professionals') entry(value);

  if (v_result #>> '{goals,week,target}')::numeric <> 8000
     or (v_result #>> '{goals,today,target}')::numeric <> 1250
     or v_sum_week <> 8000
     or v_sum_today <> 1250
     or (v_result #>> '{professionals,0,goal_today}')::numeric <> 625
     or (v_result #>> '{professionals,1,goal_today}')::numeric <> 625 then
    raise exception 'QA snapshot: alvo inicial ou soma individual incorretos.';
  end if;
  if (v_result #>> '{goals,today,actual}')::numeric <> 1000
     or (v_result->>'initial_configuration_today_actual')::numeric <> 1000
     or (v_result->>'workdays_in_week')::integer <> 6
     or (v_result->>'remaining_workdays_in_week')::integer <> 4 then
    raise exception 'QA snapshot: realizado exibido, baseline ou calendario incorreto.';
  end if;

  -- Insercao depois do cutoff altera todos os actuals vivos, mas nenhum alvo.
  v_workspace := pg_catalog.jsonb_set(
    v_workspace,
    '{goals}',
    pg_catalog.jsonb_build_object(
      'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 9500),
      'week', pg_catalog.jsonb_build_object('target', 0, 'actual', 3500),
      'today', pg_catalog.jsonb_build_object('target', 0, 'actual', 1500)
    ),
    true
  );
  v_workspace := pg_catalog.jsonb_set(
    v_workspace,
    '{professionals,0,actual_month}', '5000'::jsonb,
    false
  );
  v_workspace := pg_catalog.jsonb_set(
    v_workspace,
    '{professionals,0,actual_week}', '2000'::jsonb,
    false
  );
  v_workspace := pg_catalog.jsonb_set(
    v_workspace,
    '{professionals,0,actual_today}', '1200'::jsonb,
    false
  );
  v_result := app_private.rebalance_good_morning_with_configuration_cutoff(
    v_workspace
  );
  if (v_result #>> '{goals,week,target}')::numeric <> 8000
     or (v_result #>> '{goals,today,target}')::numeric <> 1250
     or (v_result #>> '{goals,today,actual}')::numeric <> 1500 then
    raise exception 'QA snapshot: venda pos-cutoff moveu o alvo ou sumiu do realizado.';
  end if;

  -- Simula, de uma vez, editar valor/tag/data (inclusive para outra semana) e
  -- reatribuir A -> B em linhas pre-cutoff. Os actuals vivos mudam; os tres
  -- snapshots do time e de cada UUID continuam governando o alvo inicial.
  v_workspace := pg_catalog.jsonb_set(
    v_workspace,
    '{goals}',
    pg_catalog.jsonb_build_object(
      'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 8400),
      'week', pg_catalog.jsonb_build_object('target', 0, 'actual', 2400),
      'today', pg_catalog.jsonb_build_object('target', 0, 'actual', 400)
    ),
    true
  );
  v_workspace := pg_catalog.jsonb_set(
    v_workspace,
    '{professionals}',
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000001',
        'name', 'A',
        'good_morning_seller_enabled', true,
        'goal_month', 13000,
        'actual_month', 2000,
        'actual_week', 100,
        'actual_today', 0,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 700
      ),
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000002',
        'name', 'B',
        'good_morning_seller_enabled', true,
        'goal_month', 13000,
        'actual_month', 6400,
        'actual_week', 2300,
        'actual_today', 400,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 300
      )
    ),
    true
  );
  v_result := app_private.rebalance_good_morning_with_configuration_cutoff(
    v_workspace
  );
  if (v_result #>> '{goals,week,target}')::numeric <> 8000
     or (v_result #>> '{goals,today,target}')::numeric <> 1250
     or (v_result #>> '{professionals,0,goal_today}')::numeric <> 625
     or (v_result #>> '{professionals,1,goal_today}')::numeric <> 625
     or (v_result #>> '{goals,month,actual}')::numeric <> 8400
     or (v_result #>> '{professionals,0,actual_week}')::numeric <> 100 then
    raise exception 'QA snapshot: edicao pre-cutoff moveu alvo ou congelou exibicao.';
  end if;

  -- No dia seguinte o snapshot fica inativo: o realizado vivo ate ontem volta
  -- a alimentar o calculo normal.
  v_workspace := v_workspace || pg_catalog.jsonb_build_object(
    'configuration_actual_snapshot_active', false,
    'today', '2026-09-17',
    'goals', pg_catalog.jsonb_build_object(
      'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 9500),
      'week', pg_catalog.jsonb_build_object('target', 0, 'actual', 3500),
      'today', pg_catalog.jsonb_build_object('target', 0, 'actual', 0)
    ),
    'professionals', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000001',
        'name', 'A',
        'good_morning_seller_enabled', true,
        'goal_month', 13000,
        'actual_month', 5000,
        'actual_week', 2000,
        'actual_today', 0,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 700
      ),
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000002',
        'name', 'B',
        'good_morning_seller_enabled', true,
        'goal_month', 13000,
        'actual_month', 4500,
        'actual_week', 1500,
        'actual_today', 0,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 300
      )
    )
  );
  v_result := app_private.rebalance_good_morning_with_configuration_cutoff(
    v_workspace
  );
  if (v_result #>> '{goals,week,target}')::numeric <> 8000
     or (v_result #>> '{goals,today,target}')::numeric <> 1500
     or coalesce(
       (v_result->>'initial_configuration_cutoff_applied')::boolean,
       true
     ) then
    raise exception 'QA snapshot: dia seguinte nao voltou ao calculo dinamico.';
  end if;

  -- Snapshot do time inclui venda sem vinculo e profissional fora da rotacao.
  -- O mapa individual pode somar menos que o total sem perder centavos.
  v_workspace := v_workspace || pg_catalog.jsonb_build_object(
    'configuration_actual_snapshot_active', true,
    'today', '2026-09-16',
    'actual_month_at_configuration', 9100,
    'actual_week_at_configuration', 3100,
    'actual_today_before_configuration', 1100,
    'goals', pg_catalog.jsonb_build_object(
      'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 9100),
      'week', pg_catalog.jsonb_build_object('target', 0, 'actual', 3100),
      'today', pg_catalog.jsonb_build_object('target', 0, 'actual', 1100)
    ),
    'professionals', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000001',
        'name', 'A',
        'good_morning_seller_enabled', true,
        'goal_month', 13000,
        'actual_month', 4500,
        'actual_week', 1500,
        'actual_today', 700,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 700
      ),
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000002',
        'name', 'B',
        'good_morning_seller_enabled', true,
        'goal_month', 13000,
        'actual_month', 4500,
        'actual_week', 1500,
        'actual_today', 300,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 300
      )
    )
  );
  v_result := app_private.rebalance_good_morning_with_configuration_cutoff(
    v_workspace
  );
  select coalesce(pg_catalog.sum((entry.value->>'goal_today')::numeric), 0)
  into v_sum_today
  from pg_catalog.jsonb_array_elements(v_result->'professionals') entry(value);
  if (v_result #>> '{goals,week,target}')::numeric <> 8000
     or (v_result #>> '{goals,today,target}')::numeric <> 1225
     or v_sum_today <> 1225 then
    raise exception 'QA snapshot: venda sem vinculo foi perdida no total ou duplicada no mapa.';
  end if;

  -- Se A sair da rotacao, o snapshot total continua reduzindo o alvo do time;
  -- B absorve exatamente o valor coletivo. Reativar A e o mesmo mapa volta a
  -- produzir a distribuicao 625 + 625 testada no primeiro cenario.
  v_workspace := pg_catalog.jsonb_set(
    v_workspace,
    '{professionals}',
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000001',
        'name', 'A',
        'good_morning_seller_enabled', false,
        'goal_month', 0,
        'actual_month', 4500,
        'actual_week', 1500,
        'actual_today', 700,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 700
      ),
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000002',
        'name', 'B',
        'good_morning_seller_enabled', true,
        'goal_month', 26000,
        'actual_month', 4500,
        'actual_week', 1500,
        'actual_today', 300,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 300
      )
    ),
    true
  );
  -- Retira a venda sem vinculo apenas deste subcenario.
  v_workspace := v_workspace || pg_catalog.jsonb_build_object(
    'actual_month_at_configuration', 9000,
    'actual_week_at_configuration', 3000,
    'actual_today_before_configuration', 1000
  );
  v_result := app_private.rebalance_good_morning_with_configuration_cutoff(
    v_workspace
  );
  if (v_result #>> '{goals,today,target}')::numeric <> 1250
     or (v_result #>> '{professionals,0,goal_today}')::numeric <> 0
     or (v_result #>> '{professionals,1,goal_today}')::numeric <> 1250 then
    raise exception 'QA snapshot: profissional fora da rotacao reduziu o total do time.';
  end if;

  -- Feriado/dia sem expediente continua zerando apenas o alvo de hoje.
  v_workspace := v_workspace || pg_catalog.jsonb_build_object(
    'closed_days', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('date', '2026-09-16', 'reason', 'Fechado')
    )
  );
  v_result := app_private.rebalance_good_morning_with_configuration_cutoff(
    v_workspace
  );
  if (v_result #>> '{goals,today,target}')::numeric <> 0
     or coalesce((v_result->>'today_is_closed')::boolean, false) is not true
     or (v_result #>> '{goals,month,actual}')::numeric <> 9100 then
    raise exception 'QA snapshot: dia fechado alterou realizado ou manteve alvo.';
  end if;

  if app_private.good_morning_seller_apportion_cents(
       1,
       array[1::bigint, 1::bigint, 1::bigint]
     ) <> array[1::bigint, 0::bigint, 0::bigint] then
    raise exception 'QA snapshot: centavo residual nao foi deterministico.';
  end if;

  v_workspace := v_workspace || pg_catalog.jsonb_build_object(
    'configured', false,
    'closed_days', '[]'::jsonb
  );
  v_result := app_private.rebalance_good_morning_with_configuration_cutoff(
    v_workspace
  );
  if (v_result #>> '{goals,week,target}')::numeric <> 0
     or (v_result #>> '{goals,today,target}')::numeric <> 0 then
    raise exception 'QA snapshot: configuracao invalida recebeu alvo.';
  end if;

  if v_result->>'goal_strategy'
       is distinct from 'hierarchical_weekly_daily_team_balance_v1'
     or v_result->>'configuration_actual_snapshot_strategy'
       is distinct from 'immutable_month_week_today_cents_v1' then
    raise exception 'QA snapshot: markers de estrategia ficaram inconsistentes.';
  end if;
end;
$qa$;

-- Exercita o trigger sem tocar em nenhuma loja real: insert/configuracao
-- invalida limpa; re-save no mesmo mes preserva bytes; novo mes limpa tudo.
create temporary table good_morning_snapshot_trigger_qa (
  goal_month date not null,
  monthly_goal numeric not null,
  goal_configured_at timestamptz,
  goal_configuration_actuals_cents jsonb not null
) on commit drop;

create trigger good_morning_snapshot_trigger_qa_guard
before insert or update of goal_month
on good_morning_snapshot_trigger_qa
for each row execute function app_private.stamp_good_morning_goal_configuration();

insert into good_morning_snapshot_trigger_qa values (
  '2026-09-01',
  26000,
  '2026-09-16 10:00:00-03'::timestamptz,
  '{"month":900000,"week":300000,"today":100000,"professionals":{}}'::jsonb
);

do $trigger_qa$
declare
  v_cutoff timestamptz;
  v_snapshot jsonb;
begin
  select goal_configured_at, goal_configuration_actuals_cents
  into v_cutoff, v_snapshot
  from good_morning_snapshot_trigger_qa;

  if v_cutoff is not null
     or v_snapshot <> '{"month":0,"week":0,"today":0,"professionals":{}}'::jsonb then
    raise exception 'QA trigger: insert invalido capturou snapshot.';
  end if;

  update good_morning_snapshot_trigger_qa
  set goal_configured_at = '2026-09-16 10:00:00-03'::timestamptz,
      goal_configuration_actuals_cents =
        '{"month":900000,"week":300000,"today":100000,"professionals":{"a":{"month":1,"week":1,"today":1}}}'::jsonb;

  update good_morning_snapshot_trigger_qa
  set goal_month = goal_month,
      monthly_goal = 30000;

  select goal_configured_at, goal_configuration_actuals_cents
  into v_cutoff, v_snapshot
  from good_morning_snapshot_trigger_qa;

  if v_cutoff is distinct from '2026-09-16 10:00:00-03'::timestamptz
     or v_snapshot <> '{"month":900000,"week":300000,"today":100000,"professionals":{"a":{"month":1,"week":1,"today":1}}}'::jsonb then
    raise exception 'QA trigger: re-save do mesmo mes recapturou snapshot.';
  end if;

  update good_morning_snapshot_trigger_qa
  set goal_month = '2026-10-01';

  select goal_configured_at, goal_configuration_actuals_cents
  into v_cutoff, v_snapshot
  from good_morning_snapshot_trigger_qa;

  if v_cutoff is not null
     or v_snapshot <> '{"month":0,"week":0,"today":0,"professionals":{}}'::jsonb then
    raise exception 'QA trigger: novo mes nao limpou cutoff e snapshot.';
  end if;
end;
$trigger_qa$;

drop table good_morning_snapshot_trigger_qa;

do $acl$
begin
  if pg_catalog.has_function_privilege(
       'anon',
       'app_private.stamp_good_morning_goal_configuration()',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'authenticated',
       'app_private.stamp_good_morning_goal_configuration()',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'anon',
       'app_private.capture_good_morning_actuals_cents(uuid,uuid,date,timestamptz)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'authenticated',
       'app_private.capture_good_morning_actuals_cents(uuid,uuid,date,timestamptz)',
       'EXECUTE'
     ) then
    raise exception 'QA ACL: helper interna ficou executavel pela Data API.';
  end if;

  if not pg_catalog.has_function_privilege(
       'anon',
       'public.lc_get_good_morning_seller_workspace(text,uuid)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'authenticated',
       'public.lc_save_good_morning_seller_settings_v2(text,uuid,numeric,text,jsonb,jsonb)',
       'EXECUTE'
     ) then
    raise exception 'QA ACL: wrappers publicos perderam permissao esperada.';
  end if;
end;
$acl$;

notify pgrst, 'reload schema';

commit;
