-- Listagem paginada v2 de Atendimentos.
--
-- Mantem a RPC v1 intacta para compatibilidade e acrescenta filtros que a
-- interface operacional precisa sem relaxar o isolamento por sessao/loja.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '60s';
set local search_path = public, extensions;

do $$
begin
  if to_regclass('public.attendances') is null
     or to_regprocedure(
       'app_private.rpc_list_attendances(text,uuid,text,text,uuid,text,date,date,integer,integer)'
     ) is null
     or to_regprocedure('app_private.session_user(text)') is null then
    raise exception 'Instale primeiro o modulo de Atendimentos do Lead Control.';
  end if;
end $$;

create or replace function app_private.rpc_list_attendances_v2(
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
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_search text := nullif(left(btrim(coalesce(p_search, '')), 200), '');
  v_search_digits text := nullif(
    regexp_replace(coalesce(p_search, ''), '[^0-9]', '', 'g'),
    ''
  );
  v_tag text;
  v_professional_name text := nullif(
    left(btrim(coalesce(p_professional_name, '')), 200),
    ''
  );
  v_link_status text := lower(nullif(btrim(coalesce(p_link_status, '')), ''));
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_total bigint := 0;
  v_items jsonb := '[]'::jsonb;
begin
  select *
  into v_session
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

  -- Uma unica relacao filtrada alimenta o total e a pagina. Assim, total e
  -- has_more representam o conjunto completo antes de LIMIT/OFFSET e nao
  -- podem divergir por duplicacao acidental das regras de filtro.
  with filtered as materialized (
    select
      a.*,
      l.name as lead_name,
      l.visited as lead_visited,
      l.bought as lead_bought,
      pr.name as prospection_name,
      pr.returned_at as prospection_returned_at,
      pr.purchased_at as prospection_purchased_at
    from public.attendances a
    left join public.leads l
      on l.id = a.lead_id
      and l.store_id = a.store_id
      and l.admin_user_id = a.admin_user_id
    left join public.prospections pr
      on pr.id = a.prospection_id
      and pr.store_id = a.store_id
      and pr.admin_user_id = a.admin_user_id
    where a.store_id = v_store_id
      and a.admin_user_id = v_session.admin_user_id
      and a.attended_at >= now() - interval '2 years'
      and (v_tag is null or a.tag = v_tag)
      and (p_professional_id is null or a.professional_id = p_professional_id)
      and (
        v_professional_name is null
        or a.professional_name_snapshot = v_professional_name
      )
      and (
        p_start_date is null
        or a.attended_at >= (p_start_date::timestamp at time zone 'America/Sao_Paulo')
      )
      and (
        p_end_date is null
        or a.attended_at < ((p_end_date + 1)::timestamp at time zone 'America/Sao_Paulo')
      )
      and (
        v_link_status is null
        or v_link_status = 'all'
        or (v_link_status = 'matched' and a.match_status <> 'unmatched')
        or (
          v_link_status = 'standalone'
          and a.match_status = 'unmatched'
          and not a.match_ambiguous
        )
        or (v_link_status = 'review' and a.match_ambiguous)
        or (
          v_link_status in ('unmatched', 'lead', 'prospection', 'both')
          and a.match_status = v_link_status
        )
      )
      and (
        v_search is null
        or a.customer_name ilike '%' || v_search || '%'
        or a.description ilike '%' || v_search || '%'
        or a.professional_name_snapshot ilike '%' || v_search || '%'
        or coalesce(a.credited_professional_name_snapshot, '') ilike '%' || v_search || '%'
        or coalesce(a.service_order, '') ilike '%' || v_search || '%'
        or (
          v_search_digits is not null
          and a.phone_normalized like '%' || v_search_digits || '%'
        )
      )
  ),
  page as (
    select *
    from filtered
    order by attended_at desc, id desc
    limit v_limit
    offset v_offset
  )
  select
    (select count(*) from filtered),
    (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', q.id,
            'store_id', q.store_id,
            'professional_id', q.professional_id,
            'professional_name', q.professional_name_snapshot,
            'credited_professional_id', q.credited_professional_id,
            'credited_professional_name', q.credited_professional_name_snapshot,
            'prospection_professional_id', q.prospection_professional_id,
            'prospection_professional_name', q.prospection_professional_name_snapshot,
            'bonus_minimum_snapshot', q.bonus_minimum_snapshot,
            'bonus_amount_snapshot', q.bonus_amount_snapshot,
            'bonus_eligible', q.bonus_eligible,
            'bonus_awarded_amount', q.bonus_awarded_amount,
            'bonus_credit_status', q.bonus_credit_status,
            'bonus_review_required', q.bonus_credit_status in (
              'ambiguous_prospection', 'missing_professional'
            ),
            'bonus_credit_reason', app_private.attendance_bonus_credit_reason(
              q.bonus_credit_status
            ),
            'bonus_reason', app_private.attendance_bonus_credit_reason(
              q.bonus_credit_status
            ),
            'customer_name', q.customer_name,
            'phone', q.phone,
            'phone_normalized', q.phone_normalized,
            'description', q.description,
            'tag', q.tag,
            'tag_label', case q.tag
              when 'budget' then 'Orçamento'
              when 'purchase' then 'Compra'
              else 'Outro'
            end,
            'service_value', q.service_value,
            'purchase_value', q.purchase_value,
            'service_order', q.service_order,
            'match_status', q.match_status,
            'purchase_credit_applied', q.purchase_credit_applied,
            'attended_at', q.attended_at,
            'created_at', q.created_at,
            'links', jsonb_build_object(
              'status', q.match_status,
              'lead_match_count', q.lead_match_count,
              'prospection_match_count', q.prospection_match_count,
              'ambiguous', q.match_ambiguous,
              'lead_candidates', q.lead_candidates,
              'prospection_candidates', q.prospection_candidates,
              'lead', case
                when q.lead_id is null then null
                else jsonb_build_object(
                  'id', q.lead_id,
                  'name', q.lead_name,
                  'visited', q.lead_visited,
                  'purchased', q.lead_bought,
                  'visit_applied', q.lead_visit_applied,
                  'purchase_applied', q.lead_purchase_applied
                )
              end,
              'prospection', case
                when q.prospection_id is null then null
                else jsonb_build_object(
                  'id', q.prospection_id,
                  'name', q.prospection_name,
                  'returned_at', q.prospection_returned_at,
                  'purchased_at', q.prospection_purchased_at,
                  'visit_applied', q.prospection_visit_applied,
                  'purchase_applied', q.prospection_purchase_applied,
                  'purchase_credit_applied', q.purchase_credit_applied,
                  'bonus_credit_status', q.bonus_credit_status,
                  'bonus_credit_reason', app_private.attendance_bonus_credit_reason(
                    q.bonus_credit_status
                  )
                )
              end
            )
          )
          order by q.attended_at desc, q.id desc
        ),
        '[]'::jsonb
      )
      from page q
    )
  into v_total, v_items;

  return jsonb_build_object(
    'store_id', v_store_id,
    'items', v_items,
    'attendances', v_items,
    'total', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'has_more', v_offset::bigint + jsonb_array_length(v_items)::bigint < v_total
  );
end;
$$;

create or replace function public.lc_list_attendances_v2(
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
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_list_attendances_v2(
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

-- CREATE FUNCTION concede EXECUTE a PUBLIC por padrao. A RPC privada precisa
-- continuar executavel pelos papeis do frontend porque o wrapper e invoker,
-- mas nenhuma outra funcao ou permissao de tabela e liberada.
revoke all on function app_private.rpc_list_attendances_v2(
  text, uuid, text, text, uuid, text, text, date, date, integer, integer
) from public, anon, authenticated;
grant execute on function app_private.rpc_list_attendances_v2(
  text, uuid, text, text, uuid, text, text, date, date, integer, integer
) to anon, authenticated;

revoke all on function public.lc_list_attendances_v2(
  text, uuid, text, text, uuid, text, text, date, date, integer, integer
) from public, anon, authenticated;
grant execute on function public.lc_list_attendances_v2(
  text, uuid, text, text, uuid, text, text, date, date, integer, integer
) to anon, authenticated;

comment on function public.lc_list_attendances_v2(
  text, uuid, text, text, uuid, text, text, date, date, integer, integer
) is
  'Busca paginada v2 de atendimentos, isolada por cliente, com profissional por snapshot e vínculos matched/standalone/review.';

notify pgrst, 'reload schema';

commit;
