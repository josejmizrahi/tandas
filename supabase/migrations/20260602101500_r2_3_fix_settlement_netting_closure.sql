-- ============================================================================
-- R.2-3 — FIX: cierre de obligations en settlements neteados
-- ============================================================================
-- Bug encontrado por _smoke_r2_cena_semanal (R.2K acceptance):
--
-- Cuando el neteo greedy redirige pagos (Daniel debe a David, David debe al
-- Grupo → Daniel paga 225 a David + 100 al Grupo), el cierre FIFO por-item
-- no encuentra las obligations originales (mismatch de acreedor / cobertura
-- parcial) → quedan abiertas después de pagar todo.
--
-- Fix de comportamiento (cero cambios de schema):
--   1. generate_settlement_batch registra en metadata.obligation_ids las
--      obligations que fueron neteadas en el batch.
--   2. mark_settlement_paid ya NO cierra por-item; cuando el ÚLTIMO item del
--      batch se paga (batch → finalized), cierra TODAS las obligations del
--      batch atómicamente. Esa es la semántica correcta de un acuerdo de neteo:
--      el conjunto de pagos netos es equivalente al conjunto de deudas brutas.
-- ============================================================================

create or replace function public.generate_settlement_batch(
  p_context_actor_id uuid,
  p_currency text
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_batch uuid;
  v_items jsonb := '[]'::jsonb;
  v_amount numeric;
  v_obligation_ids uuid[];
  v_net_debtors uuid[];  v_net_debtor_amounts numeric[];
  v_net_creditors uuid[]; v_net_creditor_amounts numeric[];
  i integer; j integer;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'money.settle') then
    raise exception 'not authorized to settle in context %', p_context_actor_id using errcode = '42501';
  end if;

  -- R.2-3: capturar exactamente qué obligations se netean en este batch
  select array_agg(id) into v_obligation_ids
    from public.obligations
   where context_actor_id = p_context_actor_id and status = 'open' and currency = p_currency;

  if v_obligation_ids is null then
    return jsonb_build_object('batch_id', null, 'items', '[]'::jsonb, 'message', 'nothing to settle');
  end if;

  drop table if exists _net;
  create temp table _net on commit drop as
  select actor_id, sum(net) as net from (
    select creditor_actor_id as actor_id, sum(amount) as net
      from public.obligations
     where id = any(v_obligation_ids)
     group by creditor_actor_id
    union all
    select debtor_actor_id, -sum(amount)
      from public.obligations
     where id = any(v_obligation_ids)
     group by debtor_actor_id
  ) x group by actor_id having abs(sum(net)) > 0.01;

  if not exists (select 1 from _net) then
    -- todo se cancela mutuamente: cerrar las obligations directamente
    update public.obligations set status = 'settled',
      metadata = metadata || '{"settled_reason": "mutual_netting_zero"}'::jsonb
     where id = any(v_obligation_ids);
    return jsonb_build_object('batch_id', null, 'items', '[]'::jsonb,
      'message', 'all obligations net to zero — settled directly',
      'obligations_settled', array_length(v_obligation_ids, 1));
  end if;

  insert into public.settlement_batches (context_actor_id, currency, created_by_actor_id, metadata)
  values (p_context_actor_id, p_currency, v_caller,
          jsonb_build_object('obligation_ids', to_jsonb(v_obligation_ids)))
  returning id into v_batch;

  select array_agg(actor_id order by net), array_agg(-net order by net)
    into v_net_debtors, v_net_debtor_amounts
    from _net where net < 0;
  select array_agg(actor_id order by net desc), array_agg(net order by net desc)
    into v_net_creditors, v_net_creditor_amounts
    from _net where net > 0;

  i := 1; j := 1;
  while i <= coalesce(array_length(v_net_debtors, 1), 0)
    and j <= coalesce(array_length(v_net_creditors, 1), 0) loop
    v_amount := least(v_net_debtor_amounts[i], v_net_creditor_amounts[j]);
    if v_amount > 0.01 then
      insert into public.settlement_items
        (settlement_batch_id, from_actor_id, to_actor_id, amount, currency)
      values (v_batch, v_net_debtors[i], v_net_creditors[j], round(v_amount, 2), p_currency);
      v_items := v_items || jsonb_build_object(
        'from', v_net_debtors[i], 'to', v_net_creditors[j], 'amount', round(v_amount, 2));
    end if;
    v_net_debtor_amounts[i] := v_net_debtor_amounts[i] - v_amount;
    v_net_creditor_amounts[j] := v_net_creditor_amounts[j] - v_amount;
    if v_net_debtor_amounts[i] <= 0.01 then i := i + 1; end if;
    if v_net_creditor_amounts[j] <= 0.01 then j := j + 1; end if;
  end loop;

  perform public._emit_activity(p_context_actor_id, v_caller, 'money.settlement_generated', 'settlement_batch', v_batch,
    jsonb_build_object('currency', p_currency, 'items', jsonb_array_length(v_items),
                       'obligations_netted', array_length(v_obligation_ids, 1)));

  return jsonb_build_object('batch_id', v_batch, 'items', v_items,
    'obligations_netted', array_length(v_obligation_ids, 1));
end; $$;

revoke all on function public.generate_settlement_batch(uuid, text) from public, anon;
grant execute on function public.generate_settlement_batch(uuid, text) to authenticated, service_role;

-- mark_settlement_paid: cierre por-batch (no por-item)
create or replace function public.mark_settlement_paid(p_settlement_item_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_item public.settlement_items%rowtype;
  v_batch public.settlement_batches%rowtype;
  v_txn uuid;
  v_closed integer := 0;
  v_batch_finalized boolean := false;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_item from public.settlement_items where id = p_settlement_item_id for update;
  if v_item.id is null then raise exception 'settlement item not found' using errcode = 'P0002'; end if;
  if v_item.status = 'paid' then
    return jsonb_build_object('item_id', p_settlement_item_id, 'already_paid', true);
  end if;

  select * into v_batch from public.settlement_batches where id = v_item.settlement_batch_id for update;

  if v_item.from_actor_id <> v_caller
     and not public.has_actor_authority(v_batch.context_actor_id, v_caller, 'money.settle') then
    raise exception 'not authorized to mark this settlement as paid' using errcode = '42501';
  end if;

  -- transacción de settlement
  insert into public.money_transactions
    (context_actor_id, from_actor_id, to_actor_id, transaction_type, amount, currency, created_by_actor_id, metadata)
  values
    (v_batch.context_actor_id, v_item.from_actor_id, v_item.to_actor_id, 'settlement',
     v_item.amount, v_item.currency, v_caller,
     jsonb_build_object('settlement_item_id', p_settlement_item_id))
  returning id into v_txn;

  update public.settlement_items
     set status = 'paid', settled_transaction_id = v_txn
   where id = p_settlement_item_id;

  -- R.2-3: cuando TODOS los items del batch están pagados → finalized + cerrar
  -- TODAS las obligations neteadas en el batch (semántica de acuerdo de neteo)
  if not exists (select 1 from public.settlement_items
                 where settlement_batch_id = v_batch.id and status = 'pending') then
    update public.settlement_batches set status = 'finalized', finalized_at = now()
     where id = v_batch.id;
    v_batch_finalized := true;

    update public.obligations
       set status = 'settled',
           metadata = metadata || jsonb_build_object('settled_by_batch', v_batch.id)
     where id in (select (jsonb_array_elements_text(v_batch.metadata->'obligation_ids'))::uuid)
       and status = 'open';
    get diagnostics v_closed = row_count;
  end if;

  perform public._emit_activity(v_batch.context_actor_id, v_caller, 'money.settlement_paid', 'settlement_item', p_settlement_item_id,
    jsonb_build_object('amount', v_item.amount, 'batch_finalized', v_batch_finalized, 'obligations_closed', v_closed));

  return jsonb_build_object('item_id', p_settlement_item_id, 'transaction_id', v_txn,
    'batch_finalized', v_batch_finalized, 'obligations_closed', v_closed);
end; $$;

revoke all on function public.mark_settlement_paid(uuid) from public, anon;
grant execute on function public.mark_settlement_paid(uuid) to authenticated, service_role;
