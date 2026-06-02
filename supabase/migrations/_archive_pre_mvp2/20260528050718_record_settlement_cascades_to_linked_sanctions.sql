-- 20260527230500 — record_settlement now flips linked sanctions
-- to 'completed' when their obligation fully settles.
--
-- Bug surfaced 2026-05-27: paying a monetary sanción closed the
-- linked obligation correctly (amount_outstanding=0, status='settled')
-- but `group_sanctions.status` stayed 'active' forever, so
-- `group_sanctions_active` kept returning the paid sanction and
-- Inicio's "Necesita atención" cluster surfaced it as still pending.
--
-- Fix: inside the FIFO allocation loop, when an obligation closes
-- (v_close = v_o.amount_outstanding), also flip any sanction whose
-- `obligation_id` references that obligation (and is still in an
-- open lifecycle state: proposed/active/disputed) to 'completed',
-- stamping `resolved_at = now()`. Partial-pay path stays untouched:
-- the obligation is still open so the sanction is still owed.
--
-- Sanctions table CHECK constraint already permits 'completed'
-- (verified pre-migration).

CREATE OR REPLACE FUNCTION public.record_settlement(
  p_group_id uuid,
  p_paid_by_membership_id uuid,
  p_paid_to_membership_id uuid,
  p_paid_to_kind text,
  p_amount numeric,
  p_unit text,
  p_notes text DEFAULT NULL::text,
  p_mandate_id uuid DEFAULT NULL::uuid,
  p_client_id text DEFAULT NULL::text
)
RETURNS TABLE(settlement_id uuid, transaction_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_settlement     uuid;
  v_tx_id          uuid;
  v_remaining      numeric;
  v_close          numeric;
  v_o              public.group_obligations%rowtype;
  v_actor_m        uuid;
  v_authority_path text;
  v_event_uuid     uuid;
  v_existing_tx    uuid;
  v_source_resource uuid;
begin
  if p_paid_to_kind not in ('member','pool','vendor','group') then
    raise exception 'invalid paid_to_kind';
  end if;
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;
  v_remaining := p_amount;

  v_actor_m := (select gm.id from public.group_memberships gm
                where gm.group_id = p_group_id and gm.user_id = auth.uid() and gm.status = 'active');
  if v_actor_m is null then
    raise exception 'caller is not an active member of group %', p_group_id;
  end if;

  if p_client_id is not null then
    select gs.id, gs.ledger_entry_id into v_settlement, v_existing_tx
      from public.group_settlements gs
     where gs.group_id = p_group_id and gs.client_id = p_client_id;
    if v_settlement is not null then
      settlement_id := v_settlement;
      transaction_id := v_existing_tx;
      return next;
      return;
    end if;
  end if;

  v_authority_path := public._resolve_authority_path(
    p_group_id         => p_group_id,
    p_actor_membership => v_actor_m,
    p_is_self_party    => (p_paid_by_membership_id = v_actor_m),
    p_mandate_id       => p_mandate_id,
    p_permission       => 'settlement.record_for_others',  -- P10: elevated
    p_mandate_scope    => 'settle',
    p_amount           => p_amount,
    p_unit             => p_unit,
    p_resource_id      => null
  );

  insert into public.group_settlements (
    group_id, paid_by_membership_id, paid_to_membership_id, paid_to_kind,
    amount, unit, status, mandate_id, client_id, notes, recorded_by, confirmed_at
  ) values (
    p_group_id, p_paid_by_membership_id, p_paid_to_membership_id, p_paid_to_kind,
    p_amount, p_unit, 'confirmed', p_mandate_id, p_client_id, p_notes, auth.uid(), now()
  ) returning id into v_settlement;

  for v_o in
    select * from public.group_obligations
     where group_id = p_group_id
       and owed_by_membership_id = p_paid_by_membership_id
       and ((p_paid_to_kind = 'member' and owed_to_membership_id = p_paid_to_membership_id)
            or (p_paid_to_kind <> 'member' and owed_to_kind = p_paid_to_kind))
       and unit = p_unit
       and status in ('open','partially_settled')
     order by created_at asc
     for update
  loop
    exit when v_remaining <= 0;
    v_close := least(v_remaining, v_o.amount_outstanding);

    insert into public.group_settlement_obligations (settlement_id, obligation_id, amount_closed)
    values (v_settlement, v_o.id, v_close);

    update public.group_obligations
       set amount_outstanding = amount_outstanding - v_close,
           status = case
             when (amount_outstanding - v_close) <= 0 then 'settled'
             else 'partially_settled'
           end
     where id = v_o.id;

    if v_close = v_o.amount_outstanding then
      insert into public.group_reputation_events (
        group_id, subject_membership_id, actor_membership_id,
        reputation_type, reason, evidence_entity_kind, evidence_entity_id
      ) values (
        p_group_id, p_paid_by_membership_id, v_actor_m,
        'commitment_kept', 'Obligación cerrada', 'obligation', v_o.id
      );

      -- Cascade: any sanction whose obligation just closed is fulfilled.
      -- Flip its lifecycle status to 'completed' (+ resolved_at) so it
      -- drops out of `group_sanctions_active` and the Inicio
      -- "Necesita atención" cluster. Guard by current status so we
      -- never overwrite reversed/cancelled/already-completed rows.
      update public.group_sanctions
         set status      = 'completed',
             resolved_at = now(),
             updated_at  = now()
       where obligation_id = v_o.id
         and status in ('proposed', 'active', 'disputed');
    end if;

    v_remaining := v_remaining - v_close;
  end loop;

  select o.source_resource_id into v_source_resource
    from public.group_settlement_obligations so
    join public.group_obligations o on o.id = so.obligation_id
    where so.settlement_id = v_settlement
      and o.source_resource_id is not null
    limit 1;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type,
    from_membership_id, to_membership_id, paid_by_membership_id,
    amount, unit, source_entity_kind, source_entity_id,
    mandate_id, description, recorded_by
  ) values (
    p_group_id, v_source_resource, 'settlement_payment',
    p_paid_by_membership_id,
    case when p_paid_to_kind = 'member' then p_paid_to_membership_id else null end,
    p_paid_by_membership_id,
    p_amount, p_unit, 'settlement', v_settlement,
    p_mandate_id, p_notes, auth.uid()
  ) returning id into v_tx_id;

  update public.group_settlements
     set ledger_entry_id = v_tx_id,
         metadata = case when v_remaining > 0
                         then metadata || jsonb_build_object('unallocated', v_remaining)
                         else metadata end
   where id = v_settlement;

  select rse.uuid_id into v_event_uuid from public.record_system_event(
    p_group_id, 'money.settlement_recorded', 'settlement', v_settlement, p_notes,
    jsonb_build_object(
      'amount', p_amount,
      'unit', p_unit,
      'authority_path', v_authority_path,
      'mandate_id', p_mandate_id,
      'paid_by_membership_id', p_paid_by_membership_id,
      'paid_to_kind', p_paid_to_kind,
      'unallocated', v_remaining
    )
  ) rse;
  perform public.evaluate_rules_for_event(v_event_uuid, 'sync');

  settlement_id := v_settlement;
  transaction_id := v_tx_id;
  return next;
  return;
end;
$function$;

COMMENT ON FUNCTION public.record_settlement(uuid, uuid, uuid, text, numeric, text, text, uuid, text) IS
  'Canonical settlement writer. Creates a group_settlements row, FIFO-allocates against open group_obligations, updates obligation status (settled/partially_settled), emits a commitment_kept reputation event when an obligation closes, and (patched 20260527230500) cascades the close to any linked group_sanctions row by flipping its status to ''completed'' + setting resolved_at. Idempotent via (group_id, p_client_id).';

-- Backfill: flip sanctions whose linked obligation already settled
-- but the sanción row got stranded in proposed/active/disputed.
-- One-shot — re-running is a no-op thanks to the status guard.
UPDATE public.group_sanctions s
   SET status      = 'completed',
       resolved_at = COALESCE(s.resolved_at, now()),
       updated_at  = now()
  FROM public.group_obligations o
 WHERE s.obligation_id = o.id
   AND o.status = 'settled'
   AND s.status IN ('proposed', 'active', 'disputed');
