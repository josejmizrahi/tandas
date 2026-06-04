-- R.2J-1b — fix del gateway: normalizar batch_id legacy → settlement_batch_id
create or replace function public._emit_activity(
  p_context_actor_id uuid,
  p_actor_id uuid,
  p_event_type text,
  p_subject_type text default null,
  p_subject_id uuid default null,
  p_payload jsonb default '{}'::jsonb,
  p_resource_id uuid default null,
  p_decision_id uuid default null,
  p_obligation_id uuid default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_type text;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
begin
  v_type := case p_event_type
    when 'member.joined'              then 'membership.joined'
    when 'member.invited'             then 'membership.invited'
    when 'member.removed'             then 'membership.removed'
    when 'member.left'                then 'membership.left'
    when 'document.registered'        then 'document.created'
    when 'money.expense_recorded'     then 'expense.recorded'
    when 'money.fine_recorded'        then 'fine.created'
    when 'money.game_result_recorded' then 'game_result.recorded'
    when 'money.settlement_generated' then 'settlement.generated'
    when 'money.settlement_paid'      then 'settlement.paid'
    when 'event.rsvp'                 then 'event.rsvp_updated'
    else p_event_type
  end;

  -- R.2J.2.9: settlement.* siempre lleva batch/item en el payload
  if v_type like 'settlement.%' then
    if p_subject_type = 'settlement_batch' and p_subject_id is not null then
      v_payload := v_payload || jsonb_build_object('settlement_batch_id', p_subject_id);
    elsif p_subject_type = 'settlement_item' and p_subject_id is not null then
      v_payload := v_payload || jsonb_build_object('settlement_item_id', p_subject_id);
    end if;
    -- normalizar la key legacy batch_id → settlement_batch_id
    if v_payload ? 'batch_id' and not v_payload ? 'settlement_batch_id' then
      v_payload := v_payload || jsonb_build_object('settlement_batch_id', v_payload->'batch_id');
    end if;
  end if;

  -- R.2J.6: los eventos inherentemente automáticos quedan marcados como sistema
  if v_type in ('rule.evaluated', 'reservation.conflict_detected', 'settlement.item_created') then
    v_payload := v_payload || '{"system": true}'::jsonb;
  end if;

  insert into public.activity_events
    (context_actor_id, actor_id, event_type, subject_type, subject_id, payload,
     resource_id, decision_id, obligation_id)
  values
    (p_context_actor_id, coalesce(p_actor_id, public.system_actor_id()), v_type,
     p_subject_type, p_subject_id, v_payload,
     p_resource_id, p_decision_id, p_obligation_id)
  returning id into v_id;
  return v_id;
end; $$;

revoke all on function public._emit_activity(uuid, uuid, text, text, uuid, jsonb, uuid, uuid, uuid) from public, anon, authenticated;