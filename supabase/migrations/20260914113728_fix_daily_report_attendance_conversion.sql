-- A taxa exibida no resumo diario pertence ao funil de Atendimentos:
-- todo atendimento do dia forma o denominador e cada resultado "purchase"
-- forma o numerador. Prospecções continuam sendo informadas separadamente.
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

revoke all on function app_private.build_daily_report_payload(
  uuid, uuid, date, text
) from public, anon, authenticated, service_role;

comment on function app_private.build_daily_report_payload(
  uuid, uuid, date, text
) is
  'Monta o resumo diario: conversao = atendimentos com compra / todos os atendimentos do dia.';
