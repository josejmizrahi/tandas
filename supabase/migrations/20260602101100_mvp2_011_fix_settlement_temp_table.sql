-- ============================================================================
-- MVP 2.0 — M.11 FIX: generate_settlement_batch temp table collision
-- ============================================================================
-- Bug encontrado por _smoke_mvp2_contract: `create temp table _net on commit drop`
-- explota si el RPC se llama 2+ veces en la misma transacción (42P07 relation
-- already exists). Fix: drop table if exists antes de crear.
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
  v_net_debtors uuid[];  v_net_debtor_amounts numeric[];
  v_net_creditors uuid[]; v_net_creditor_amounts numeric[];
  i integer; j integer;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'money.settle') then
    raise exception 'not authorized to settle in context %', p_context_actor_id using errcode = '42501';
  end if;

  -- FIX M.11: la temp table puede existir de una llamada anterior en la misma transacción
  drop table if exists _net;
  create temp table _net on commit drop as
  select actor_id, sum(net) as net from (
    select creditor_actor_id as actor_id, sum(amount) as net
      from public.obligations
     where context_actor_id = p_context_actor_id and status = 'open' and currency = p_currency
     group by creditor_actor_id
    union all
    select debtor_actor_id, -sum(amount)
      from public.obligations
     where context_actor_id = p_context_actor_id and status = 'open' and currency = p_currency
     group by debtor_actor_id
  ) x group by actor_id having abs(sum(net)) > 0.01;

  if not exists (select 1 from _net) then
    return jsonb_build_object('batch_id', null, 'items', '[]'::jsonb, 'message', 'nothing to settle');
  end if;

  insert into public.settlement_batches (context_actor_id, currency, created_by_actor_id)
  values (p_context_actor_id, p_currency, v_caller)
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
    jsonb_build_object('currency', p_currency, 'items', jsonb_array_length(v_items)));

  return jsonb_build_object('batch_id', v_batch, 'items', v_items);
end; $$;

revoke all on function public.generate_settlement_batch(uuid, text) from public, anon;
grant execute on function public.generate_settlement_batch(uuid, text) to authenticated, service_role;
