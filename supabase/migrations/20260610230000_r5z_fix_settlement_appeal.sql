-- R.5Z.fix.SETTLEMENT.APPEAL (2026-06-10 founder) — debtor puede apelar
-- cuando el creditor reporta su pago. status='disputed'. Admin resuelve.
--
-- Flow:
--   pending → (debtor marca) → pending_confirmation
--     → (creditor confirma) → paid
--     → (creditor rechaza) → pending + attention a debtor
--       → (debtor apela) → disputed + attention a admins (money.settle)
--          → (admin confirm_settlement_paid) → paid
--          → (admin reject_settlement_paid) → pending

create or replace function public.appeal_settlement_paid(
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
  v_debtor_name text;
  v_admin_actor uuid;
  v_idem_base text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_item from public.settlement_items where id = p_settlement_item_id for update;
  if v_item.id is null then raise exception 'settlement item not found' using errcode = 'P0002'; end if;
  if v_item.status = 'disputed' then
    return jsonb_build_object('item_id', p_settlement_item_id, 'already_disputed', true);
  end if;
  if v_item.status not in ('pending', 'pending_confirmation') then
    raise exception 'cannot appeal item in status %', v_item.status using errcode = '22023';
  end if;
  if v_item.from_actor_id <> v_caller then
    raise exception 'only the debtor can appeal' using errcode = '42501';
  end if;
  select * into v_batch from public.settlement_batches where id = v_item.settlement_batch_id;

  update public.settlement_items
     set status = 'disputed',
         metadata = coalesce(metadata, '{}'::jsonb)
                    || jsonb_build_object('appealed_by', v_caller, 'appealed_at', now(),
                                          'appeal_reason', p_reason)
   where id = p_settlement_item_id;

  select display_name into v_debtor_name from public.actors where id = v_caller;
  v_idem_base := 'settlement_appeal:' || p_settlement_item_id::text || ':' || extract(epoch from now())::text;

  insert into public.rule_attention_items
    (context_actor_id, subject_actor_id,
     kind, title, reason, priority,
     cta_action_key, cta_scope_kind, cta_scope_id,
     source_rule_id, source_event_id, idempotency_key, metadata)
  values
    (v_batch.context_actor_id, v_item.to_actor_id,
     'settlement_payment_appealed',
     format('%s apeló tu reporte del pago de %s %s',
            coalesce(v_debtor_name, 'El deudor'),
            to_char(v_item.amount, 'FM999G999G990D00'),
            v_item.currency),
     coalesce(p_reason, 'Un admin va a revisar y decidir.'),
     'high',
     'review_settlement_dispute',
     'settlement_item',
     p_settlement_item_id,
     null, null,
     v_idem_base || ':creditor',
     jsonb_build_object('settlement_item_id', p_settlement_item_id, 'reason', p_reason))
  on conflict (idempotency_key) do nothing;

  for v_admin_actor in
    select distinct ra.member_actor_id
    from public.role_assignments ra
    join public.role_permissions rp on rp.role_id = ra.role_id and rp.allowed
    where ra.context_actor_id = v_batch.context_actor_id
      and rp.permission_key = 'money.settle'
      and ra.member_actor_id not in (v_caller, v_item.to_actor_id)
  loop
    insert into public.rule_attention_items
      (context_actor_id, subject_actor_id,
       kind, title, reason, priority,
       cta_action_key, cta_scope_kind, cta_scope_id,
       source_rule_id, source_event_id, idempotency_key, metadata)
    values
      (v_batch.context_actor_id, v_admin_actor,
       'settlement_dispute_to_review',
       format('Disputa de pago: %s vs %s',
              coalesce(v_debtor_name, 'Deudor'),
              (select display_name from public.actors where id = v_item.to_actor_id)),
       coalesce(p_reason, 'Revisa y resuelve la disputa.'),
       'high',
       'review_settlement_dispute',
       'settlement_item',
       p_settlement_item_id,
       null, null,
       v_idem_base || ':admin:' || v_admin_actor::text,
       jsonb_build_object('settlement_item_id', p_settlement_item_id, 'reason', p_reason))
    on conflict (idempotency_key) do nothing;
  end loop;

  perform public._emit_activity(v_batch.context_actor_id, v_caller, 'settlement.payment_appealed',
    'settlement_item', p_settlement_item_id,
    jsonb_build_object('reason', p_reason, 'amount', v_item.amount, 'currency', v_item.currency));

  return jsonb_build_object('item_id', p_settlement_item_id, 'status', 'disputed');
end;
$function$;

-- confirm_settlement_paid actualizado: también acepta 'disputed' (solo admin).
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
  if v_item.status not in ('pending_confirmation', 'pending', 'disputed') then
    raise exception 'item is not in a confirmable state' using errcode = '22023';
  end if;
  select * into v_batch from public.settlement_batches where id = v_item.settlement_batch_id;
  if v_item.status = 'disputed' then
    if not public.has_actor_authority(v_batch.context_actor_id, v_caller, 'money.settle') then
      raise exception 'only admins (money.settle) can resolve a dispute' using errcode = '42501';
    end if;
  else
    if v_item.to_actor_id <> v_caller
       and not public.has_actor_authority(v_batch.context_actor_id, v_caller, 'money.settle') then
      raise exception 'not authorized (solo el acreedor o admin)' using errcode = '42501';
    end if;
  end if;
  return public._settlement_finalize_item(p_settlement_item_id, v_caller);
end;
$function$;

grant execute on function public.appeal_settlement_paid(uuid, text) to authenticated;
