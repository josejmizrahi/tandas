-- R.5Z.fix.SETTLEMENT.HANDSHAKE (2026-06-10 founder) — 2-way confirmation
-- en pagos de settlement. Antes: debtor marca pagado → status='paid' directo.
-- Ahora: debtor marca pagado → status='pending_confirmation'. Creditor (o
-- admin) confirma o rechaza.
--
-- Cambios:
--   * status nuevo 'pending_confirmation' permitido en settlement_items.
--   * mark_settlement_paid: cuando lo llama el debtor → pending_confirmation
--     + emit attention al creditor. Cuando lo llama el creditor o admin →
--     paid directo (admin override / self-pay).
--   * confirm_settlement_paid(item_id): nuevo. Solo creditor o admin. Aplica
--     todas las side effects (transaction + novation + obligation close +
--     batch finalize + activity).
--   * reject_settlement_paid(item_id, reason?): nuevo. Creditor only. Vuelve
--     a status='pending' + emite attention al debtor.

create or replace function public._settlement_finalize_item(
  p_settlement_item_id uuid,
  p_caller uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_item public.settlement_items%rowtype;
  v_batch public.settlement_batches%rowtype;
  v_txn uuid;
  v_iou uuid;
  v_closed integer := 0;
  v_sources_closed integer := 0;
  v_batch_finalized boolean := false;
begin
  select * into v_item from public.settlement_items where id = p_settlement_item_id for update;
  select * into v_batch from public.settlement_batches where id = v_item.settlement_batch_id for update;

  insert into public.money_transactions
    (context_actor_id, from_actor_id, to_actor_id, transaction_type, amount, currency, created_by_actor_id, metadata)
  values
    (v_batch.context_actor_id, v_item.from_actor_id, v_item.to_actor_id, 'settlement',
     v_item.amount, v_item.currency, p_caller,
     jsonb_build_object('settlement_item_id', p_settlement_item_id, 'settlement_batch_id', v_batch.id))
  returning id into v_txn;

  update public.settlement_items
     set status = 'paid',
         settled_transaction_id = v_txn,
         metadata = coalesce(metadata, '{}'::jsonb)
                    || jsonb_build_object('confirmed_by', p_caller, 'confirmed_at', now())
   where id = p_settlement_item_id;

  v_iou := (v_item.metadata->>'obligation_id')::uuid;
  if v_iou is not null then
    update public.obligations
       set status = 'settled',
           metadata = metadata || jsonb_build_object('settled_by_item', p_settlement_item_id, 'settled_by_batch', v_batch.id)
     where id = v_iou and status = 'open';
    get diagnostics v_closed = row_count;
  end if;

  if not exists (select 1 from public.settlement_items
                 where settlement_batch_id = v_batch.id and status in ('pending','pending_confirmation')) then
    update public.settlement_batches set status = 'finalized', finalized_at = now()
     where id = v_batch.id;
    v_batch_finalized := true;
    update public.obligations
       set status = 'settled',
           metadata = metadata || jsonb_build_object('settled_by_batch', v_batch.id)
     where id in (select (jsonb_array_elements_text(coalesce(v_batch.metadata->'obligation_ids', '[]'::jsonb)))::uuid)
       and status = 'open';
    get diagnostics v_sources_closed = row_count;
    v_sources_closed := v_sources_closed + coalesce(
      jsonb_array_length(v_batch.metadata->'source_obligation_ids'), 0);
  end if;

  v_closed := v_closed + v_sources_closed;

  perform public._emit_activity(v_batch.context_actor_id, p_caller, 'settlement.paid', 'settlement_item', p_settlement_item_id,
    jsonb_build_object('settlement_item_id', p_settlement_item_id, 'settlement_batch_id', v_batch.id,
                       'amount', v_item.amount, 'currency', v_item.currency, 'transaction_id', v_txn,
                       'batch_finalized', v_batch_finalized, 'obligations_closed', v_closed));

  return jsonb_build_object('item_id', p_settlement_item_id, 'transaction_id', v_txn,
    'batch_finalized', v_batch_finalized, 'obligations_closed', v_closed);
end;
$function$;

create or replace function public.mark_settlement_paid(p_settlement_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_item public.settlement_items%rowtype;
  v_batch public.settlement_batches%rowtype;
  v_is_creditor boolean;
  v_is_debtor boolean;
  v_is_admin boolean;
  v_debtor_name text;
  v_idem text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_item from public.settlement_items where id = p_settlement_item_id for update;
  if v_item.id is null then raise exception 'settlement item not found' using errcode = 'P0002'; end if;
  if v_item.status = 'paid' then
    return jsonb_build_object('item_id', p_settlement_item_id, 'already_paid', true,
      'transaction_id', v_item.settled_transaction_id);
  end if;
  if v_item.status = 'cancelled' then
    raise exception 'cannot pay a cancelled settlement item' using errcode = '22023';
  end if;

  select * into v_batch from public.settlement_batches where id = v_item.settlement_batch_id;
  v_is_creditor := (v_item.to_actor_id = v_caller);
  v_is_debtor := (v_item.from_actor_id = v_caller);
  v_is_admin := public.has_actor_authority(v_batch.context_actor_id, v_caller, 'money.settle');

  if not (v_is_creditor or v_is_debtor or v_is_admin) then
    raise exception 'not authorized to mark this settlement as paid' using errcode = '42501';
  end if;

  if v_is_creditor or v_is_admin then
    return public._settlement_finalize_item(p_settlement_item_id, v_caller);
  end if;

  if v_item.status = 'pending_confirmation' then
    return jsonb_build_object('item_id', p_settlement_item_id, 'already_marked', true,
      'status', 'pending_confirmation');
  end if;

  update public.settlement_items
     set status = 'pending_confirmation',
         metadata = coalesce(metadata, '{}'::jsonb)
                    || jsonb_build_object('marked_paid_by', v_caller, 'marked_paid_at', now())
   where id = p_settlement_item_id;

  select display_name into v_debtor_name from public.actors where id = v_caller;
  v_idem := 'settlement_pending_confirm:' || p_settlement_item_id::text;

  insert into public.rule_attention_items
    (context_actor_id, subject_actor_id,
     kind, title, reason, priority,
     cta_action_key, cta_scope_kind, cta_scope_id,
     source_rule_id, source_event_id, idempotency_key, metadata)
  values
    (v_batch.context_actor_id, v_item.to_actor_id,
     'settlement_payment_claimed',
     format('%s dice que te pagó %s %s',
            coalesce(v_debtor_name, 'Alguien'),
            to_char(v_item.amount, 'FM999G999G990D00'),
            v_item.currency),
     'Confirma o reporta un problema con el pago.',
     'normal',
     'confirm_settlement_paid',
     'settlement_item',
     p_settlement_item_id,
     null, null,
     v_idem,
     jsonb_build_object('settlement_item_id', p_settlement_item_id,
                        'amount', v_item.amount, 'currency', v_item.currency,
                        'from_actor_id', v_item.from_actor_id))
  on conflict (idempotency_key) do nothing;

  perform public._emit_activity(v_batch.context_actor_id, v_caller, 'settlement.payment_claimed',
    'settlement_item', p_settlement_item_id,
    jsonb_build_object('amount', v_item.amount, 'currency', v_item.currency));

  return jsonb_build_object('item_id', p_settlement_item_id, 'status', 'pending_confirmation',
    'requires_confirmation_from', v_item.to_actor_id);
end;
$function$;

create or replace function public.confirm_settlement_paid(p_settlement_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_item public.settlement_items%rowtype;
  v_batch public.settlement_batches%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_item from public.settlement_items where id = p_settlement_item_id;
  if v_item.id is null then raise exception 'settlement item not found' using errcode = 'P0002'; end if;
  if v_item.status = 'paid' then
    return jsonb_build_object('item_id', p_settlement_item_id, 'already_paid', true);
  end if;
  if v_item.status not in ('pending_confirmation', 'pending') then
    raise exception 'item is not in a confirmable state' using errcode = '22023';
  end if;
  select * into v_batch from public.settlement_batches where id = v_item.settlement_batch_id;
  if v_item.to_actor_id <> v_caller
     and not public.has_actor_authority(v_batch.context_actor_id, v_caller, 'money.settle') then
    raise exception 'not authorized (solo el acreedor o admin)' using errcode = '42501';
  end if;
  return public._settlement_finalize_item(p_settlement_item_id, v_caller);
end;
$function$;

create or replace function public.reject_settlement_paid(
  p_settlement_item_id uuid,
  p_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_item public.settlement_items%rowtype;
  v_batch public.settlement_batches%rowtype;
  v_creditor_name text;
  v_idem text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_item from public.settlement_items where id = p_settlement_item_id for update;
  if v_item.id is null then raise exception 'settlement item not found' using errcode = 'P0002'; end if;
  if v_item.status <> 'pending_confirmation' then
    raise exception 'item is not pending confirmation' using errcode = '22023';
  end if;
  select * into v_batch from public.settlement_batches where id = v_item.settlement_batch_id;
  if v_item.to_actor_id <> v_caller
     and not public.has_actor_authority(v_batch.context_actor_id, v_caller, 'money.settle') then
    raise exception 'not authorized (solo el acreedor o admin)' using errcode = '42501';
  end if;
  update public.settlement_items
     set status = 'pending',
         metadata = coalesce(metadata, '{}'::jsonb)
                    || jsonb_build_object('rejected_by', v_caller, 'rejected_at', now(),
                                          'reject_reason', p_reason)
                    - 'marked_paid_by' - 'marked_paid_at'
   where id = p_settlement_item_id;

  select display_name into v_creditor_name from public.actors where id = v_caller;
  v_idem := 'settlement_rejected:' || p_settlement_item_id::text || ':' || extract(epoch from now())::text;

  insert into public.rule_attention_items
    (context_actor_id, subject_actor_id,
     kind, title, reason, priority,
     cta_action_key, cta_scope_kind, cta_scope_id,
     source_rule_id, source_event_id, idempotency_key, metadata)
  values
    (v_batch.context_actor_id, v_item.from_actor_id,
     'settlement_payment_rejected',
     format('%s reportó un problema con tu pago de %s %s',
            coalesce(v_creditor_name, 'El acreedor'),
            to_char(v_item.amount, 'FM999G999G990D00'),
            v_item.currency),
     coalesce(p_reason, 'Hablen y vuelvan a marcar como pagado.'),
     'high',
     'mark_settlement_paid',
     'settlement_item',
     p_settlement_item_id,
     null, null,
     v_idem,
     jsonb_build_object('settlement_item_id', p_settlement_item_id, 'reason', p_reason))
  on conflict (idempotency_key) do nothing;

  perform public._emit_activity(v_batch.context_actor_id, v_caller, 'settlement.payment_rejected',
    'settlement_item', p_settlement_item_id,
    jsonb_build_object('reason', p_reason));

  return jsonb_build_object('item_id', p_settlement_item_id, 'status', 'pending');
end;
$function$;

grant execute on function public._settlement_finalize_item(uuid, uuid) to authenticated;
grant execute on function public.confirm_settlement_paid(uuid) to authenticated;
grant execute on function public.reject_settlement_paid(uuid, text) to authenticated;
