-- Bom Dia Vendedor | reconcilia os saldos individuais com o saldo da equipe.
--
-- A meta da equipe continua sendo calculada pela funcao hierarquica existente.
-- Esta camada somente reparte, em centavos, o saldo coletivo de cada periodo
-- entre os participantes habilitados. O peso e o deficit mensal vivo de cada
-- vendedor; portanto, vender mais reduz a propria parcela sem permitir que a
-- soma individual ultrapasse o que ainda falta para a loja.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';

create or replace function app_private.personalize_good_morning_individual_balances(
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
  v_configured boolean := false;
  v_snapshot_active boolean := false;
  v_team_month_target_cents bigint := 0;
  v_team_month_actual_cents bigint := 0;
  v_team_week_target_cents bigint := 0;
  v_team_week_actual_cents bigint := 0;
  v_team_today_target_cents bigint := 0;
  v_team_today_actual_cents bigint := 0;
  v_snapshot_today_actual_cents bigint := 0;
  v_effective_today_actual_cents bigint := 0;
  v_remaining_month_cents bigint := 0;
  v_remaining_week_cents bigint := 0;
  v_remaining_today_cents bigint := 0;
  v_weights bigint[] := array[]::bigint[];
  v_month_shares bigint[] := array[]::bigint[];
  v_week_shares bigint[] := array[]::bigint[];
  v_today_shares bigint[] := array[]::bigint[];
  v_professionals jsonb := '[]'::jsonb;
  v_has_enabled_participant boolean := false;
begin
  if pg_catalog.jsonb_typeof(v_workspace) is distinct from 'object' then
    return v_workspace;
  end if;

  v_configured := coalesce(
    nullif(v_workspace->>'configured', '')::boolean,
    false
  );
  v_snapshot_active := v_configured and (
    coalesce(
      nullif(
        v_workspace->>'configuration_actual_snapshot_active',
        ''
      )::boolean,
      false
    )
    or coalesce(
      nullif(v_workspace->>'initial_configuration_cutoff_applied', '')::boolean,
      false
    )
  );

  v_team_month_target_cents := greatest(
    pg_catalog.round(coalesce(
      nullif(v_workspace #>> '{goals,month,target}', '')::numeric,
      nullif(v_workspace->>'monthly_goal', '')::numeric,
      0
    ) * 100)::bigint,
    0
  );
  v_team_month_actual_cents := greatest(
    pg_catalog.round(coalesce(
      nullif(v_workspace #>> '{goals,month,actual}', '')::numeric,
      0
    ) * 100)::bigint,
    0
  );
  v_team_week_target_cents := greatest(
    pg_catalog.round(coalesce(
      nullif(v_workspace #>> '{goals,week,target}', '')::numeric,
      0
    ) * 100)::bigint,
    0
  );
  v_team_week_actual_cents := greatest(
    pg_catalog.round(coalesce(
      nullif(v_workspace #>> '{goals,week,actual}', '')::numeric,
      0
    ) * 100)::bigint,
    0
  );
  v_team_today_target_cents := greatest(
    pg_catalog.round(coalesce(
      nullif(v_workspace #>> '{goals,today,target}', '')::numeric,
      0
    ) * 100)::bigint,
    0
  );
  v_team_today_actual_cents := greatest(
    pg_catalog.round(coalesce(
      nullif(v_workspace #>> '{goals,today,actual}', '')::numeric,
      0
    ) * 100)::bigint,
    0
  );
  v_snapshot_today_actual_cents := greatest(
    pg_catalog.round(coalesce(
      nullif(v_workspace->>'actual_today_before_configuration', '')::numeric,
      nullif(v_workspace->>'initial_configuration_today_actual', '')::numeric,
      0
    ) * 100)::bigint,
    0
  );

  -- O alvo criado durante o expediente ja incorporou o snapshot. Depois do
  -- corte, somente vendas liquidas posteriores o consomem. Uma correcao que
  -- deixe o realizado abaixo do snapshot nao pode elevar o saldo acima do alvo
  -- imutavel do dia; ela repercute no proximo recalculo, sem dupla subtracao.
  v_effective_today_actual_cents := case
    when v_snapshot_active then greatest(
      v_team_today_actual_cents - v_snapshot_today_actual_cents,
      0
    )
    else v_team_today_actual_cents
  end;

  if v_configured then
    v_remaining_month_cents := greatest(
      v_team_month_target_cents - v_team_month_actual_cents,
      0
    );
    v_remaining_week_cents := greatest(
      v_team_week_target_cents - v_team_week_actual_cents,
      0
    );
    v_remaining_today_cents := greatest(
      v_team_today_target_cents - v_effective_today_actual_cents,
      0
    );
  end if;

  -- A ordem usada pelo maior resto e independente da fila. O identificador e o
  -- primeiro desempate; a ordinalidade original e apenas o fallback para
  -- payload legado sem identificador. Isso tambem cobre novas versoes de UUID
  -- sem acoplar a regra financeira ao formato atual dos IDs.
  with source as (
    select
      entries.ordinality,
      entries.professional,
      coalesce(nullif(entries.professional->>'id', ''), '') as professional_id,
      v_configured and coalesce(
        nullif(
          entries.professional->>'good_morning_seller_enabled',
          ''
        )::boolean,
        true
      ) as enabled,
      case
        when v_configured and coalesce(
          nullif(
            entries.professional->>'good_morning_seller_enabled',
            ''
          )::boolean,
          true
        ) then greatest(
          pg_catalog.round(coalesce(
            nullif(entries.professional->>'goal_amount', '')::numeric,
            nullif(
              entries.professional->>'goal_month_target',
              ''
            )::numeric,
            nullif(entries.professional->>'goal_month', '')::numeric,
            0
          ) * 100)::bigint,
          0
        )
        else 0::bigint
      end as month_target_cents,
      case
        when v_configured and coalesce(
          nullif(
            entries.professional->>'good_morning_seller_enabled',
            ''
          )::boolean,
          true
        ) then greatest(
          pg_catalog.round(coalesce(
            nullif(
              entries.professional->>'goal_week_target',
              ''
            )::numeric,
            nullif(entries.professional->>'goal_week', '')::numeric,
            0
          ) * 100)::bigint,
          0
        )
        else 0::bigint
      end as week_target_cents,
      case
        when v_configured and coalesce(
          nullif(
            entries.professional->>'good_morning_seller_enabled',
            ''
          )::boolean,
          true
        ) then greatest(
          pg_catalog.round(coalesce(
            nullif(
              entries.professional->>'goal_today_target',
              ''
            )::numeric,
            nullif(entries.professional->>'goal_today', '')::numeric,
            0
          ) * 100)::bigint,
          0
        )
        else 0::bigint
      end as today_target_cents,
      greatest(pg_catalog.round(coalesce(
        nullif(entries.professional->>'actual_month', '')::numeric,
        0
      ) * 100)::bigint, 0) as live_month_actual_cents,
      greatest(pg_catalog.round(coalesce(
        nullif(entries.professional->>'actual_today', '')::numeric,
        0
      ) * 100)::bigint, 0) as live_today_actual_cents,
      greatest(pg_catalog.round(coalesce(
        nullif(
          entries.professional->>'actual_today_before_configuration',
          ''
        )::numeric,
        0
      ) * 100)::bigint, 0) as snapshot_today_actual_cents
    from pg_catalog.jsonb_array_elements(
      case
        when pg_catalog.jsonb_typeof(v_workspace->'professionals') = 'array'
          then v_workspace->'professionals'
        else '[]'::jsonb
      end
    ) with ordinality as entries(professional, ordinality)
  ), balances as (
    select
      source.*,
      case
        when source.enabled then greatest(
          source.month_target_cents - source.live_month_actual_cents,
          0
        )
        else 0::bigint
      end as month_deficit_cents
    from source
  ), totals as (
    select
      balances.*,
      coalesce(pg_catalog.sum(balances.month_deficit_cents) over (), 0)::bigint
        as total_month_deficit_cents,
      coalesce(pg_catalog.sum(balances.month_target_cents) filter (
        where balances.enabled
      ) over (), 0)::bigint as total_month_target_cents,
      pg_catalog.count(*) filter (where balances.enabled) over ()::integer
        as enabled_count
    from balances
  ), weighted as (
    select
      totals.*,
      case
        when totals.total_month_deficit_cents > 0
          then totals.month_deficit_cents
        when totals.total_month_target_cents > 0 and totals.enabled
          then totals.month_target_cents
        when totals.enabled_count > 0 and totals.enabled
          then 1::bigint
        else 0::bigint
      end as allocation_weight,
      pg_catalog.row_number() over (
        order by
          case when totals.professional_id <> '' then 0 else 1 end,
          case when totals.professional_id <> ''
            then pg_catalog.lower(totals.professional_id)
            else ''
          end,
          totals.ordinality
      )::integer as allocation_index
    from totals
  )
  select
    coalesce(
      pg_catalog.array_agg(
        weighted.allocation_weight order by weighted.allocation_index
      ),
      array[]::bigint[]
    ),
    coalesce(pg_catalog.bool_or(weighted.enabled), false)
  into v_weights, v_has_enabled_participant
  from weighted;

  -- Um workspace marcado como configurado sem participante e um estado
  -- contabilmente impossivel. Falhar fechado evita publicar um contrato v3
  -- cuja soma individual nao poderia reconciliar com o saldo coletivo.
  if v_configured and not v_has_enabled_participant then
    raise exception using
      errcode = '23514',
      message = 'Bom Dia Vendedor inconsistente: configurado sem participante habilitado.';
  end if;

  v_month_shares := app_private.good_morning_seller_apportion_cents(
    v_remaining_month_cents,
    v_weights
  );
  v_week_shares := app_private.good_morning_seller_apportion_cents(
    v_remaining_week_cents,
    v_weights
  );
  v_today_shares := app_private.good_morning_seller_apportion_cents(
    v_remaining_today_cents,
    v_weights
  );

  with source as (
    select
      entries.ordinality,
      entries.professional,
      coalesce(nullif(entries.professional->>'id', ''), '') as professional_id,
      v_configured and coalesce(
        nullif(
          entries.professional->>'good_morning_seller_enabled',
          ''
        )::boolean,
        true
      ) as enabled,
      case
        when v_configured and coalesce(
          nullif(
            entries.professional->>'good_morning_seller_enabled',
            ''
          )::boolean,
          true
        ) then greatest(pg_catalog.round(coalesce(
          nullif(entries.professional->>'goal_amount', '')::numeric,
          nullif(
            entries.professional->>'goal_month_target',
            ''
          )::numeric,
          nullif(entries.professional->>'goal_month', '')::numeric,
          0
        ) * 100)::bigint, 0)
        else 0::bigint
      end as month_target_cents,
      case
        when v_configured and coalesce(
          nullif(
            entries.professional->>'good_morning_seller_enabled',
            ''
          )::boolean,
          true
        ) then greatest(pg_catalog.round(coalesce(
          nullif(
            entries.professional->>'goal_week_target',
            ''
          )::numeric,
          nullif(entries.professional->>'goal_week', '')::numeric,
          0
        ) * 100)::bigint, 0)
        else 0::bigint
      end as week_target_cents,
      case
        when v_configured and coalesce(
          nullif(
            entries.professional->>'good_morning_seller_enabled',
            ''
          )::boolean,
          true
        ) then greatest(pg_catalog.round(coalesce(
          nullif(
            entries.professional->>'goal_today_target',
            ''
          )::numeric,
          nullif(entries.professional->>'goal_today', '')::numeric,
          0
        ) * 100)::bigint, 0)
        else 0::bigint
      end as today_target_cents,
      greatest(pg_catalog.round(coalesce(
        nullif(entries.professional->>'actual_month', '')::numeric,
        0
      ) * 100)::bigint, 0) as live_month_actual_cents,
      greatest(pg_catalog.round(coalesce(
        nullif(entries.professional->>'actual_today', '')::numeric,
        0
      ) * 100)::bigint, 0) as live_today_actual_cents,
      greatest(pg_catalog.round(coalesce(
        nullif(
          entries.professional->>'actual_today_before_configuration',
          ''
        )::numeric,
        0
      ) * 100)::bigint, 0) as snapshot_today_actual_cents
    from pg_catalog.jsonb_array_elements(
      case
        when pg_catalog.jsonb_typeof(v_workspace->'professionals') = 'array'
          then v_workspace->'professionals'
        else '[]'::jsonb
      end
    ) with ordinality as entries(professional, ordinality)
  ), indexed as (
    select
      source.*,
      pg_catalog.row_number() over (
        order by
          case when source.professional_id <> '' then 0 else 1 end,
          case when source.professional_id <> ''
            then pg_catalog.lower(source.professional_id)
            else ''
          end,
          source.ordinality
      )::integer as allocation_index
    from source
  )
  select coalesce(
    pg_catalog.jsonb_agg(
      indexed.professional || pg_catalog.jsonb_build_object(
        -- Os alvos permanecem alvos. Somente remaining_* representa o saldo
        -- dinamico que deve fechar com o card geral da equipe.
        'goal_month', indexed.month_target_cents::numeric / 100,
        'goal_week', indexed.week_target_cents::numeric / 100,
        'goal_today', indexed.today_target_cents::numeric / 100,
        'goal_month_target', indexed.month_target_cents::numeric / 100,
        'goal_week_target', indexed.week_target_cents::numeric / 100,
        'goal_today_target', indexed.today_target_cents::numeric / 100,
        'remaining_month', coalesce(
          v_month_shares[indexed.allocation_index],
          0
        )::numeric / 100,
        'remaining_week', coalesce(
          v_week_shares[indexed.allocation_index],
          0
        )::numeric / 100,
        'remaining_today', coalesce(
          v_today_shares[indexed.allocation_index],
          0
        )::numeric / 100,
        'goal_month_target_cents', indexed.month_target_cents,
        'goal_week_target_cents', indexed.week_target_cents,
        'goal_today_target_cents', indexed.today_target_cents,
        'remaining_month_cents', coalesce(
          v_month_shares[indexed.allocation_index],
          0
        ),
        'remaining_week_cents', coalesce(
          v_week_shares[indexed.allocation_index],
          0
        ),
        'remaining_today_cents', coalesce(
          v_today_shares[indexed.allocation_index],
          0
        ),
        'actual_today_against_target', case
          when v_snapshot_active then greatest(
            indexed.live_today_actual_cents
              - indexed.snapshot_today_actual_cents,
            0
          )::numeric / 100
          else indexed.live_today_actual_cents::numeric / 100
        end,
        'actual_today_against_target_cents', case
          when v_snapshot_active then greatest(
            indexed.live_today_actual_cents
              - indexed.snapshot_today_actual_cents,
            0
          )
          else indexed.live_today_actual_cents
        end
      )
      order by indexed.ordinality
    ),
    '[]'::jsonb
  )
  into v_professionals
  from indexed;

  return v_workspace || pg_catalog.jsonb_build_object(
    'professionals', v_professionals,
    'individual_goal_strategy', 'team_remaining_personalized_v3',
    'individual_goal_amounts_in_cents', true,
    'individual_remaining_allocation_strategy',
      'live_month_deficit_largest_remainder_stable_uuid_v1',
    'individual_daily_cutoff_strategy',
      'nonnegative_live_delta_from_initial_configuration_v1',
    'individual_remaining_totals_cents', pg_catalog.jsonb_build_object(
      'month', v_remaining_month_cents,
      'week', v_remaining_week_cents,
      'today', v_remaining_today_cents
    ),
    'rotation_affects_individual_goals', false
  );
end;
$$;

-- Guardas deterministicas: a migration aborta antes do commit se perder um
-- centavo, usar a rotacao como peso, incluir pausados ou errar o cutoff.
do $reconciliation_qa$
declare
  v_a text := '00000000-0000-4000-8000-000000000001';
  v_b text := '00000000-0000-4000-8000-000000000002';
  v_disabled text := '00000000-0000-4000-8000-000000000003';
  v_workspace jsonb;
  v_result jsonb;
  v_changed jsonb;
  v_professionals jsonb;
  v_projection jsonb;
  v_changed_projection jsonb;
  v_sums bigint[];
  v_cutoff_remaining bigint;
  v_cutoff_actual bigint;
begin
  -- Caso real anonimizado de 04/09/2026. A ordem da fila esta invertida em
  -- relacao aos UUIDs para provar que ela nao decide o maior resto.
  v_workspace := pg_catalog.jsonb_build_object(
    'configured', true,
    'current_professional_id', v_b,
    'configuration_actual_snapshot_active', false,
    'goals', pg_catalog.jsonb_build_object(
      'month', pg_catalog.jsonb_build_object(
        'target', 130800,
        'actual', 18454
      ),
      'week', pg_catalog.jsonb_build_object(
        'target', 26160,
        'actual', 18454
      ),
      'today', pg_catalog.jsonb_build_object(
        'target', 3853,
        'actual', 0
      )
    ),
    'professionals', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', v_b,
        'queue_position', 1,
        'is_current', true,
        'good_morning_seller_enabled', true,
        'goal_amount', 65400,
        'goal_month', 65400,
        'goal_week', 13080,
        'goal_today', 4470.50,
        'actual_month', 4139,
        'actual_week', 4139,
        'actual_today', 0
      ),
      pg_catalog.jsonb_build_object(
        'id', v_a,
        'queue_position', 2,
        'is_current', false,
        'good_morning_seller_enabled', true,
        'goal_amount', 65400,
        'goal_month', 65400,
        'goal_week', 13080,
        'goal_today', 0,
        'actual_month', 14315,
        'actual_week', 14315,
        'actual_today', 0
      ),
      pg_catalog.jsonb_build_object(
        'id', v_disabled,
        'queue_position', 3,
        'is_current', false,
        'good_morning_seller_enabled', false,
        'goal_amount', 50000,
        'goal_month', 50000,
        'goal_week', 10000,
        'goal_today', 2000,
        'actual_month', 0,
        'actual_week', 0,
        'actual_today', 0
      )
    )
  );
  v_result := app_private.personalize_good_morning_individual_balances(
    v_workspace
  );

  if v_result->>'individual_goal_strategy'
       is distinct from 'team_remaining_personalized_v3'
     or coalesce(
       (v_result->>'rotation_affects_individual_goals')::boolean,
       true
     ) then
    raise exception 'QA reconciliacao: contrato v3 invalido.';
  end if;

  select pg_catalog.jsonb_object_agg(
    entry.value->>'id',
    pg_catalog.jsonb_build_array(
      entry.value->'remaining_month_cents',
      entry.value->'remaining_week_cents',
      entry.value->'remaining_today_cents'
    )
  )
  into v_projection
  from pg_catalog.jsonb_array_elements(v_result->'professionals') entry(value);

  if v_projection is distinct from pg_catalog.jsonb_build_object(
    v_a, pg_catalog.jsonb_build_array(5108500, 350401, 175200),
    v_b, pg_catalog.jsonb_build_array(6126100, 420199, 210100),
    v_disabled, pg_catalog.jsonb_build_array(0, 0, 0)
  ) then
    raise exception 'QA reconciliacao: caso real divergiu: %', v_projection;
  end if;

  select array[
    coalesce(pg_catalog.sum(
      (entry.value->>'remaining_month_cents')::bigint
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      (entry.value->>'remaining_week_cents')::bigint
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      (entry.value->>'remaining_today_cents')::bigint
    ), 0)::bigint
  ]
  into v_sums
  from pg_catalog.jsonb_array_elements(v_result->'professionals') entry(value)
  where coalesce(
    (entry.value->>'good_morning_seller_enabled')::boolean,
    true
  );

  if v_sums is distinct from array[
    11234600::bigint,
    770600::bigint,
    385300::bigint
  ] then
    raise exception 'QA reconciliacao: somas nao fecham: %', v_sums;
  end if;
  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(v_result->'professionals') entry(value)
    where coalesce(
      (entry.value->>'good_morning_seller_enabled')::boolean,
      true
    )
      and (
        (entry.value->>'remaining_month_cents')::bigint > 11234600
        or (entry.value->>'remaining_week_cents')::bigint > 770600
        or (entry.value->>'remaining_today_cents')::bigint > 385300
      )
  ) then
    raise exception 'QA reconciliacao: saldo individual maior que coletivo.';
  end if;

  -- Trocar quem esta na vez nao altera nenhuma parcela.
  select coalesce(pg_catalog.jsonb_agg(
    entry.value || pg_catalog.jsonb_build_object(
      'is_current', entry.value->>'id' = v_a
    )
    order by entry.ordinality
  ), '[]'::jsonb)
  into v_professionals
  from pg_catalog.jsonb_array_elements(v_workspace->'professionals')
    with ordinality as entry(value, ordinality);
  v_changed := app_private.personalize_good_morning_individual_balances(
    pg_catalog.jsonb_set(
      pg_catalog.jsonb_set(
        v_workspace,
        '{current_professional_id}',
        pg_catalog.to_jsonb(v_a)
      ),
      '{professionals}',
      v_professionals
    )
  );
  select pg_catalog.jsonb_object_agg(
    entry.value->>'id',
    pg_catalog.jsonb_build_array(
      entry.value->'remaining_month_cents',
      entry.value->'remaining_week_cents',
      entry.value->'remaining_today_cents'
    )
  )
  into v_changed_projection
  from pg_catalog.jsonb_array_elements(v_changed->'professionals') entry(value);
  if v_changed_projection is distinct from v_projection then
    raise exception 'QA reconciliacao: rotacao alterou saldos.';
  end if;

  -- Reordenar o payload tambem nao muda o centavo de maior resto: UUID e a
  -- chave estavel; ordinalidade so serve para registros legados sem UUID.
  select coalesce(
    pg_catalog.jsonb_agg(entry.value order by entry.ordinality desc),
    '[]'::jsonb
  )
  into v_professionals
  from pg_catalog.jsonb_array_elements(v_workspace->'professionals')
    with ordinality as entry(value, ordinality);
  v_changed := app_private.personalize_good_morning_individual_balances(
    pg_catalog.jsonb_set(v_workspace, '{professionals}', v_professionals)
  );
  select pg_catalog.jsonb_object_agg(
    entry.value->>'id',
    pg_catalog.jsonb_build_array(
      entry.value->'remaining_month_cents',
      entry.value->'remaining_week_cents',
      entry.value->'remaining_today_cents'
    )
  )
  into v_changed_projection
  from pg_catalog.jsonb_array_elements(v_changed->'professionals') entry(value);
  if v_changed_projection is distinct from v_projection then
    raise exception 'QA reconciliacao: ordem do payload alterou saldos.';
  end if;

  -- Cutoff: realizado abaixo do snapshot nao eleva saldo acima do alvo; uma
  -- venda liquida posterior ao corte o reduz exatamente uma vez.
  v_workspace := pg_catalog.jsonb_build_object(
    'configured', true,
    'configuration_actual_snapshot_active', true,
    'actual_today_before_configuration', 300,
    'goals', pg_catalog.jsonb_build_object(
      'month', pg_catalog.jsonb_build_object('target', 10000, 'actual', 0),
      'week', pg_catalog.jsonb_build_object('target', 5000, 'actual', 0),
      'today', pg_catalog.jsonb_build_object('target', 1000, 'actual', 200)
    ),
    'professionals', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', v_a,
        'good_morning_seller_enabled', true,
        'goal_amount', 10000,
        'goal_month', 10000,
        'goal_week', 5000,
        'goal_today', 1000,
        'actual_month', 0,
        'actual_today', 200,
        'actual_today_before_configuration', 300
      )
    )
  );
  v_result := app_private.personalize_good_morning_individual_balances(
    v_workspace
  );
  select
    (entry.value->>'remaining_today_cents')::bigint,
    (entry.value->>'actual_today_against_target_cents')::bigint
  into v_cutoff_remaining, v_cutoff_actual
  from pg_catalog.jsonb_array_elements(v_result->'professionals') entry(value);
  if (v_cutoff_remaining, v_cutoff_actual)
       is distinct from (100000::bigint, 0::bigint) then
    raise exception 'QA reconciliacao: cutoff abaixo do snapshot incorreto.';
  end if;

  v_workspace := pg_catalog.jsonb_set(
    pg_catalog.jsonb_set(
      v_workspace,
      '{goals,today,actual}',
      '500'::jsonb
    ),
    '{professionals,0,actual_today}',
    '500'::jsonb
  );
  v_result := app_private.personalize_good_morning_individual_balances(
    v_workspace
  );
  select
    (entry.value->>'remaining_today_cents')::bigint,
    (entry.value->>'actual_today_against_target_cents')::bigint
  into v_cutoff_remaining, v_cutoff_actual
  from pg_catalog.jsonb_array_elements(v_result->'professionals') entry(value);
  if (v_cutoff_remaining, v_cutoff_actual)
       is distinct from (80000::bigint, 20000::bigint) then
    raise exception 'QA reconciliacao: delta posterior ao cutoff incorreto.';
  end if;

  -- Um unico centavo usa desempate UUID deterministico, nunca a fila.
  v_workspace := pg_catalog.jsonb_build_object(
    'configured', true,
    'goals', pg_catalog.jsonb_build_object(
      'month', pg_catalog.jsonb_build_object('target', 0.01, 'actual', 0),
      'week', pg_catalog.jsonb_build_object('target', 0.01, 'actual', 0),
      'today', pg_catalog.jsonb_build_object('target', 0.01, 'actual', 0)
    ),
    'professionals', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', v_b,
        'queue_position', 1,
        'good_morning_seller_enabled', true,
        'goal_amount', 1,
        'actual_month', 0
      ),
      pg_catalog.jsonb_build_object(
        'id', v_a,
        'queue_position', 2,
        'good_morning_seller_enabled', true,
        'goal_amount', 1,
        'actual_month', 0
      )
    )
  );
  v_result := app_private.personalize_good_morning_individual_balances(
    v_workspace
  );
  select pg_catalog.jsonb_object_agg(
    entry.value->>'id',
    pg_catalog.jsonb_build_array(
      entry.value->'remaining_month_cents',
      entry.value->'remaining_week_cents',
      entry.value->'remaining_today_cents'
    )
  )
  into v_projection
  from pg_catalog.jsonb_array_elements(v_result->'professionals') entry(value);
  if v_projection is distinct from pg_catalog.jsonb_build_object(
    v_a, pg_catalog.jsonb_build_array(1, 1, 1),
    v_b, pg_catalog.jsonb_build_array(0, 0, 0)
  ) then
    raise exception 'QA reconciliacao: desempate de um centavo instavel.';
  end if;

  -- Estado configurado sem participante deve falhar fechado, nunca publicar
  -- saldo coletivo positivo acompanhado por soma individual zero.
  begin
    perform app_private.personalize_good_morning_individual_balances(
      pg_catalog.jsonb_build_object(
        'configured', true,
        'goals', pg_catalog.jsonb_build_object(
          'month', pg_catalog.jsonb_build_object('target', 100, 'actual', 0),
          'week', pg_catalog.jsonb_build_object('target', 20, 'actual', 0),
          'today', pg_catalog.jsonb_build_object('target', 5, 'actual', 0)
        ),
        'professionals', pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object(
            'id', v_disabled,
            'good_morning_seller_enabled', false,
            'goal_amount', 0,
            'actual_month', 0
          )
        )
      )
    );
    raise exception 'QA reconciliacao: estado sem participante nao foi bloqueado.';
  exception
    when check_violation then null;
  end;
end;
$reconciliation_qa$;

revoke all on function app_private.personalize_good_morning_individual_balances(jsonb)
  from public, anon, authenticated;
grant execute on function app_private.personalize_good_morning_individual_balances(jsonb)
  to anon, authenticated;

comment on function app_private.personalize_good_morning_individual_balances(jsonb) is
  'Reparte em centavos os saldos coletivos de mes, semana e dia entre participantes habilitados, ponderando pelo deficit mensal vivo e ignorando a rotacao.';
comment on function app_private.rebalance_good_morning_with_configuration_cutoff(jsonb) is
  'Preserva os cards gerais e o cutoff; reconcilia cada soma individual exatamente com o saldo coletivo, independente da rotacao.';

notify pgrst, 'reload schema';

commit;
