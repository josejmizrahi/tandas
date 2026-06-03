-- ============================================================================
-- R.2N-2 — FIX: el recálculo de settlement no debe re-emitir settlement.item_created
-- ============================================================================
-- Regresión introducida por R.2N (neteo vivo por novación): _recalculate_settlement
-- emite `settlement.item_created` por cada item en CADA recálculo. Como lo invocan
-- el trigger de obligations (en cada deuda nueva) y el re-generate de un draft
-- existente, el feed de actividad se llena de item_created duplicados y se rompe la
-- idempotencia de actividad (_smoke_r2j_activity_idempotency: settlement.item_created
-- 3 → 5 al re-generar).
--
-- Fix: settlement.item_created se emite SOLO en la generación inicial del batch
-- (generate_settlement_batch sobre un contexto sin draft). Los recálculos (trigger
-- o re-generate) novan/recrean los items en silencio — el dato sigue vivo, pero la
-- actividad no se duplica. La firma de las RPCs públicas no cambia.
--
-- (El smoke de R.2N no asienta sobre settlement.item_created; valida filas de items,
-- ious y balances → no se ve afectado.)
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. _recalculate_settlement v2 — +p_emit_items (default false: silencioso)
-- ────────────────────────────────────────────────────────────────────────────
-- 3-arg → 4-arg con default: los callers existentes (trigger, mark_settlement_paid,
-- re-generate) siguen llamando con 3 args y resuelven a emit=false.
drop function if exists public._recalculate_settlement(uuid, text, uuid);

create or replace function public._recalculate_settlement(
  p_context_actor_id uuid,
  p_currency text,
  p_acting_actor_id uuid default null,
  p_emit_items boolean default false
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_batch public.settlement_batches%rowtype;
  v_obligation_ids uuid[];
  v_iou_ids uuid[] := array[]::uuid[];
  v_items jsonb := '[]'::jsonb;
  v_item_id uuid;
  v_iou_id uuid;
  v_amount numeric;
  v_net_debtors uuid[];  v_net_debtor_amounts numeric[];
  v_net_creditors uuid[]; v_net_creditor_amounts numeric[];
  v_total_debtors integer; v_total_creditors integer;
  i integer; j integer;
begin
  -- Guard de recursión: los inserts de ious que hace esta función no deben
  -- volver a disparar el recálculo vía trigger.
  if coalesce(current_setting('ruul.in_settlement_recalc', true), '') = 'on' then
    return null;
  end if;
  perform set_config('ruul.in_settlement_recalc', 'on', true);

  -- Solo recalcula batches DRAFT existentes (la creación sigue siendo lazy
  -- vía generate_settlement_batch).
  select * into v_batch from public.settlement_batches
   where context_actor_id = p_context_actor_id and currency = p_currency and status = 'draft'
   order by created_at desc limit 1
   for update;
  if v_batch.id is null then
    perform set_config('ruul.in_settlement_recalc', '', true);
    return null;
  end if;

  -- Obligations abiertas del contexto en esa moneda (incluye ious de neteos previos)
  select array_agg(id) into v_obligation_ids
    from public.obligations
   where context_actor_id = p_context_actor_id and status = 'open' and currency = p_currency
     and amount is not null and debtor_actor_id <> creditor_actor_id;

  -- Cancelar los items pendientes actuales (quedan como historia; la activity
  -- que los referencia sigue siendo válida).
  update public.settlement_items
     set status = 'cancelled',
         metadata = metadata || jsonb_build_object('cancelled_reason', 'superseded_by_recalc', 'cancelled_at', now())
   where settlement_batch_id = v_batch.id and status = 'pending';

  -- Sin deudas abiertas → no hay nada que netear.
  if v_obligation_ids is null then
    if exists (select 1 from public.settlement_items
                where settlement_batch_id = v_batch.id and status = 'paid') then
      -- Solo quedan pagos hechos → el batch está completo.
      update public.settlement_batches set status = 'finalized', finalized_at = now()
       where id = v_batch.id and status = 'draft';
    else
      -- Batch vacío → cancelarlo.
      update public.settlement_batches set status = 'cancelled'
       where id = v_batch.id and status = 'draft';
    end if;
    perform set_config('ruul.in_settlement_recalc', '', true);
    return jsonb_build_object('batch_id', v_batch.id, 'items', '[]'::jsonb, 'obligations_netted', 0);
  end if;

  -- Netos por actor
  select array_agg(actor_id order by net), array_agg(-net order by net)
    into v_net_debtors, v_net_debtor_amounts
    from (
      select actor_id, sum(net) as net from (
        select creditor_actor_id as actor_id, sum(amount) as net
          from public.obligations where id = any(v_obligation_ids) group by creditor_actor_id
        union all
        select debtor_actor_id, -sum(amount)
          from public.obligations where id = any(v_obligation_ids) group by debtor_actor_id
      ) x group by actor_id having sum(net) < -0.01
    ) d;
  select array_agg(actor_id order by net desc), array_agg(net order by net desc)
    into v_net_creditors, v_net_creditor_amounts
    from (
      select actor_id, sum(net) as net from (
        select creditor_actor_id as actor_id, sum(amount) as net
          from public.obligations where id = any(v_obligation_ids) group by creditor_actor_id
        union all
        select debtor_actor_id, -sum(amount)
          from public.obligations where id = any(v_obligation_ids) group by debtor_actor_id
      ) x group by actor_id having sum(net) > 0.01
    ) c;

  v_total_debtors := coalesce(array_length(v_net_debtors, 1), 0);
  v_total_creditors := coalesce(array_length(v_net_creditors, 1), 0);

  -- NOVACIÓN: cerrar las obligations origen — quedan reemplazadas por los ious.
  update public.obligations
     set status = 'settled',
         metadata = metadata || jsonb_build_object(
           'settled_reason', 'netted_into_settlement',
           'netted_into_batch', v_batch.id,
           'netted_at', now())
   where id = any(v_obligation_ids);

  -- Todo se cancela mutuamente → nada que transferir.
  if v_total_debtors = 0 or v_total_creditors = 0 then
    if exists (select 1 from public.settlement_items
                where settlement_batch_id = v_batch.id and status = 'paid') then
      update public.settlement_batches set status = 'finalized', finalized_at = now()
       where id = v_batch.id and status = 'draft';
    else
      update public.settlement_batches set status = 'cancelled'
       where id = v_batch.id and status = 'draft';
    end if;
    perform set_config('ruul.in_settlement_recalc', '', true);
    return jsonb_build_object('batch_id', v_batch.id, 'items', '[]'::jsonb,
      'obligations_netted', array_length(v_obligation_ids, 1),
      'message', 'all obligations net to zero — settled directly');
  end if;

  -- Greedy min-cashflow: cada transferencia neta se materializa como un iou
  -- nuevo + su settlement_item (mapeo 1:1 → el pago cierra el iou).
  i := 1; j := 1;
  while i <= v_total_debtors and j <= v_total_creditors loop
    v_amount := least(v_net_debtor_amounts[i], v_net_creditor_amounts[j]);
    if v_amount > 0.01 then
      insert into public.obligations
        (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type,
         amount, currency, status, metadata)
      values
        (p_context_actor_id, v_net_debtors[i], v_net_creditors[j], 'iou',
         round(v_amount, 2), p_currency, 'open',
         jsonb_build_object(
           'netted', true,
           'settlement_batch_id', v_batch.id,
           'source_obligation_ids', to_jsonb(v_obligation_ids)))
      returning id into v_iou_id;
      v_iou_ids := v_iou_ids || v_iou_id;

      insert into public.settlement_items
        (settlement_batch_id, from_actor_id, to_actor_id, amount, currency, metadata)
      values
        (v_batch.id, v_net_debtors[i], v_net_creditors[j], round(v_amount, 2), p_currency,
         jsonb_build_object('obligation_id', v_iou_id))
      returning id into v_item_id;

      v_items := v_items || jsonb_build_object(
        'item_id', v_item_id,
        'from', v_net_debtors[i], 'to', v_net_creditors[j], 'amount', round(v_amount, 2));

      -- R.2N-2: solo la generación inicial emite item_created en la actividad.
      -- Los recálculos (trigger / re-generate) recrean items en silencio para no
      -- duplicar el feed ni romper la idempotencia de actividad.
      if p_emit_items then
        perform public._emit_activity(p_context_actor_id, p_acting_actor_id, 'settlement.item_created', 'settlement_item', v_item_id,
          jsonb_build_object('settlement_batch_id', v_batch.id, 'batch_id', v_batch.id,
                             'from', v_net_debtors[i], 'to', v_net_creditors[j],
                             'amount', round(v_amount, 2), 'currency', p_currency),
          p_obligation_id := v_iou_id);
      end if;
    end if;
    v_net_debtor_amounts[i] := v_net_debtor_amounts[i] - v_amount;
    v_net_creditor_amounts[j] := v_net_creditor_amounts[j] - v_amount;
    if v_net_debtor_amounts[i] <= 0.01 then i := i + 1; end if;
    if v_net_creditor_amounts[j] <= 0.01 then j := j + 1; end if;
  end loop;

  -- Metadata del batch: los ious vigentes + las obligations origen acumuladas
  update public.settlement_batches
     set metadata = metadata || jsonb_build_object(
       'obligation_ids', to_jsonb(v_iou_ids),
       'source_obligation_ids',
         coalesce(metadata->'source_obligation_ids', '[]'::jsonb) || to_jsonb(v_obligation_ids),
       'total_debtors', v_total_debtors,
       'total_creditors', v_total_creditors,
       'settlement_semantics', 'live_novation_netting',
       'settlement_semantics_note',
         'Las deudas abiertas se novan en ious netos 1:1 con los items. Cada pago cierra su iou al instante; el neteo se recalcula automáticamente cuando entran deudas nuevas.',
       'last_recalculated_at', now())
   where id = v_batch.id;

  perform set_config('ruul.in_settlement_recalc', '', true);

  return jsonb_build_object('batch_id', v_batch.id, 'items', v_items,
    'obligations_netted', array_length(v_obligation_ids, 1));
end; $$;

revoke all on function public._recalculate_settlement(uuid, text, uuid, boolean) from public, anon, authenticated;

comment on function public._recalculate_settlement(uuid, text, uuid, boolean) is
  'R.2N-2: motor de neteo vivo. Nova las obligations abiertas en ious 1:1 con los settlement_items del batch draft. p_emit_items=true solo en la generación inicial (la actividad item_created no se duplica en los recálculos del trigger / re-generate).';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. generate_settlement_batch — la generación inicial emite item_created (true);
--    el re-generate de un draft existente recalcula en silencio (false).
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.generate_settlement_batch(
  p_context_actor_id uuid,
  p_currency text
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_existing public.settlement_batches%rowtype;
  v_batch uuid;
  v_result jsonb;
  v_open_count integer;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'money.settle') then
    raise exception 'not authorized to settle in context %', p_context_actor_id using errcode = '42501';
  end if;
  if p_currency is null or btrim(p_currency) = '' then
    raise exception 'currency is required' using errcode = '22023';
  end if;

  -- Validaciones duras (R.2I.8, se conservan)
  if exists (select 1 from public.obligations
              where context_actor_id = p_context_actor_id and status = 'open'
                and currency = p_currency and amount is null) then
    raise exception 'cannot settle: obligations with null amount exist' using errcode = '22023';
  end if;
  if exists (select 1 from public.obligations
              where context_actor_id = p_context_actor_id and status = 'open'
                and currency = p_currency and debtor_actor_id = creditor_actor_id) then
    raise exception 'cannot settle: obligations with debtor = creditor exist' using errcode = '22023';
  end if;

  select * into v_existing from public.settlement_batches
   where context_actor_id = p_context_actor_id and currency = p_currency and status = 'draft'
   order by created_at desc limit 1;

  if v_existing.id is not null then
    -- Batch vivo: recalcular en silencio (re-generate = recálculo idempotente en
    -- actividad) y devolverlo.
    v_result := public._recalculate_settlement(p_context_actor_id, p_currency, v_caller, false);
    return jsonb_build_object(
      'batch_id', v_existing.id,
      'idempotent_replay', true,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object('item_id', si.id, 'from', si.from_actor_id, 'to', si.to_actor_id, 'amount', si.amount))
        from public.settlement_items si
        where si.settlement_batch_id = v_existing.id and si.status in ('pending', 'paid')), '[]'::jsonb),
      'obligations_netted', coalesce(v_result->>'obligations_netted', '0')::integer);
  end if;

  -- Sin batch: debe haber deudas abiertas que netear.
  select count(*) into v_open_count
    from public.obligations
   where context_actor_id = p_context_actor_id and status = 'open' and currency = p_currency;
  if v_open_count = 0 then
    raise exception 'no open obligations to settle for context % in %', p_context_actor_id, p_currency
      using errcode = '22023';
  end if;

  insert into public.settlement_batches (context_actor_id, currency, created_by_actor_id, metadata)
  values (p_context_actor_id, p_currency, v_caller, '{}'::jsonb)
  returning id into v_batch;

  -- Generación inicial: SÍ emite settlement.item_created por item.
  v_result := public._recalculate_settlement(p_context_actor_id, p_currency, v_caller, true);

  perform public._emit_activity(p_context_actor_id, v_caller, 'settlement.generated', 'settlement_batch', v_batch,
    jsonb_build_object('settlement_batch_id', v_batch, 'currency', p_currency,
                       'items', jsonb_array_length(coalesce(v_result->'items', '[]'::jsonb)),
                       'obligations_netted', coalesce(v_result->>'obligations_netted', '0')::integer));

  return jsonb_build_object(
    'batch_id', v_batch,
    'items', coalesce(v_result->'items', '[]'::jsonb),
    'obligations_netted', coalesce(v_result->>'obligations_netted', '0')::integer);
end; $$;

revoke all on function public.generate_settlement_batch(uuid, text) from public, anon;
grant execute on function public.generate_settlement_batch(uuid, text) to authenticated, service_role;
