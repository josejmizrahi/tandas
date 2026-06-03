-- ============================================================================
-- R.2R-2 — SETTLEMENT REPLAY IDEMPOTENCY (fix engine R.2N)
-- ============================================================================
-- Bug pre-existente (introducido por R.2N, detectado por _smoke_r2j_activity_idempotency
-- y reproducible en main / PRs ajenas como R.2Q):
--
--   Tras un pago parcial, el batch draft sobrevive con items pendientes. Volver a
--   llamar generate_settlement_batch (replay idempotente) entraba a
--   _recalculate_settlement, que SIEMPRE cancelaba los items pendientes y creaba
--   ious+items frescos idénticos, re-emitiendo `settlement.item_created`. Resultado:
--   una operación idempotente generaba activity nueva (3 → 5 item_created), violando
--   la doctrina R.2J ("las operaciones idempotentes no generan activity").
--
-- Doctrina (founder): el replay idempotente NO debe emitir activity ni churnear items.
--
-- Fix: guard de idempotencia en _recalculate_settlement. Si las obligations abiertas
-- ya netean EXACTAMENTE a los items pendientes actuales (mismo neto por actor), no hay
-- nada que hacer → no-op (sin cancelar, sin novar, sin crear, sin emitir). El neteo
-- vivo sigue intacto cuando entran deudas nuevas o tras un pago (el neto cambia → recalc).
--
-- Resto del motor R.2N idéntico (novación, min-cashflow, finalización).
-- ============================================================================

create or replace function public._recalculate_settlement(
  p_context_actor_id uuid,
  p_currency text,
  p_acting_actor_id uuid default null
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
  v_unchanged boolean;
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

  -- R.2R-2: guard de idempotencia. Si las obligations abiertas ya netean exactamente
  -- a los items pendientes actuales, el replay es un no-op (sin churn ni activity).
  if v_obligation_ids is not null
     and exists (select 1 from public.settlement_items
                  where settlement_batch_id = v_batch.id and status = 'pending') then
    with ob as (
      select actor_id, sum(net) as net from (
        select creditor_actor_id as actor_id, sum(amount) as net
          from public.obligations where id = any(v_obligation_ids) group by creditor_actor_id
        union all
        select debtor_actor_id, -sum(amount)
          from public.obligations where id = any(v_obligation_ids) group by debtor_actor_id
      ) x group by actor_id
    ),
    it as (
      select actor_id, sum(net) as net from (
        select to_actor_id as actor_id, sum(amount) as net
          from public.settlement_items
          where settlement_batch_id = v_batch.id and status = 'pending' group by to_actor_id
        union all
        select from_actor_id, -sum(amount)
          from public.settlement_items
          where settlement_batch_id = v_batch.id and status = 'pending' group by from_actor_id
      ) y group by actor_id
    )
    select not exists (
      select 1 from ob full outer join it using (actor_id)
       where abs(coalesce(ob.net, 0) - coalesce(it.net, 0)) > 0.01
    ) into v_unchanged;

    if v_unchanged then
      perform set_config('ruul.in_settlement_recalc', '', true);
      return jsonb_build_object('batch_id', v_batch.id, 'items', '[]'::jsonb,
        'obligations_netted', 0, 'idempotent_noop', true);
    end if;
  end if;

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

      perform public._emit_activity(p_context_actor_id, p_acting_actor_id, 'settlement.item_created', 'settlement_item', v_item_id,
        jsonb_build_object('settlement_batch_id', v_batch.id, 'batch_id', v_batch.id,
                           'from', v_net_debtors[i], 'to', v_net_creditors[j],
                           'amount', round(v_amount, 2), 'currency', p_currency),
        p_obligation_id := v_iou_id);
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

revoke all on function public._recalculate_settlement(uuid, text, uuid) from public, anon, authenticated;

comment on function public._recalculate_settlement(uuid, text, uuid) is
  'R.2N + R.2R-2: motor de neteo vivo con guard de idempotencia. Si las obligations abiertas ya netean a los items pendientes, el replay es no-op (sin churn ni activity).';
