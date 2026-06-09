-- R.5Z.fix.CC.2.2 (2026-06-09 founder smoke) — extiende `_r6_emit_attention`
-- para derivar cta_scope_kind='money_transaction' cuando el source event es
-- expense.recorded / payment.recorded / similar (subject_type='money_transaction').
-- iOS routea money_transaction → MoneyHomeView del contexto.

create or replace function public._r6_emit_attention(
  p_context_actor_id uuid,
  p_subject_actor_id uuid,
  p_consequence jsonb,
  p_rule_id uuid,
  p_source_event_id uuid,
  p_idempotency_key text
) returns uuid
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_id uuid;
  v_cta_kind text := coalesce(p_consequence->>'cta_scope_kind', 'rule');
  v_cta_id uuid := coalesce(nullif(p_consequence->>'cta_scope_id','')::uuid, p_rule_id);
  v_ev record;
begin
  if v_cta_kind in ('context', 'rule') and p_source_event_id is not null then
    select obligation_id, resource_id, decision_id, subject_type, subject_id, event_type
      into v_ev
    from public.activity_events
    where id = p_source_event_id;

    if found then
      if v_ev.obligation_id is not null then
        v_cta_kind := 'obligation';
        v_cta_id := v_ev.obligation_id;
      elsif v_ev.decision_id is not null then
        v_cta_kind := 'decision';
        v_cta_id := v_ev.decision_id;
      elsif v_ev.resource_id is not null then
        v_cta_kind := 'resource';
        v_cta_id := v_ev.resource_id;
      elsif v_ev.subject_type = 'obligation' and v_ev.subject_id is not null then
        v_cta_kind := 'obligation';
        v_cta_id := v_ev.subject_id;
      elsif v_ev.subject_type = 'decision' and v_ev.subject_id is not null then
        v_cta_kind := 'decision';
        v_cta_id := v_ev.subject_id;
      elsif v_ev.subject_type = 'resource' and v_ev.subject_id is not null then
        v_cta_kind := 'resource';
        v_cta_id := v_ev.subject_id;
      -- R.5Z.fix.CC.2.2 — money_transaction → MoneyHomeView del contexto.
      -- iOS no tiene detail view de transacción individual; push a la lista
      -- de movimientos del contexto (closer to "the action" que el ContextDetail genérico).
      elsif v_ev.subject_type = 'money_transaction' then
        v_cta_kind := 'money_transaction';
        v_cta_id := p_context_actor_id;
      elsif v_cta_kind = 'context' then
        v_cta_id := p_context_actor_id;
      end if;
    end if;
  end if;

  insert into public.rule_attention_items
    (context_actor_id, subject_actor_id,
     kind, title, reason, priority,
     cta_action_key, cta_scope_kind, cta_scope_id,
     resource_id,
     source_rule_id, source_event_id, idempotency_key, metadata)
  values
    (p_context_actor_id, p_subject_actor_id,
     coalesce(p_consequence->>'kind', 'rule_violation'),
     coalesce(p_consequence->>'title', 'Atención requerida'),
     p_consequence->>'reason',
     coalesce(p_consequence->>'priority', 'normal'),
     coalesce(p_consequence->>'cta_action_key', 'view_rule'),
     v_cta_kind,
     v_cta_id,
     nullif(p_consequence->>'resource_id','')::uuid,
     p_rule_id,
     p_source_event_id,
     p_idempotency_key,
     coalesce(p_consequence->'metadata', '{}'::jsonb))
  on conflict (idempotency_key) do nothing
  returning id into v_id;

  return v_id;
end;
$function$;

-- Backfill: items 'open' con cta_scope_kind='context' que vienen de
-- money_transaction events → money_transaction scope con context_actor_id.
update public.rule_attention_items rai
set cta_scope_kind = 'money_transaction',
    cta_scope_id = rai.context_actor_id
from public.activity_events ae
where rai.source_event_id = ae.id
  and rai.status = 'open'
  and rai.cta_scope_kind = 'context'
  and ae.subject_type = 'money_transaction';
