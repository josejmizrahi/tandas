-- R.5Z.fix.CC.2 (2026-06-09 founder smoke) — `_r6_emit_attention` ahora deriva
-- `cta_scope_kind` + `cta_scope_id` desde el source activity_event cuando la
-- consequence pide scope genérico `context`. Esto hace que cuando una rule
-- viola sobre una obligación overdue, el item de atención apunte directo a la
-- obligación detail en vez de al context detail.
--
-- Heurística: si la consequence dice 'context', miramos source_event:
--   1. event.obligation_id → ('obligation', obligation_id)
--   2. event.resource_id → ('resource', resource_id)
--   3. event.subject_type='obligation' → ('obligation', subject_id)
--   4. event.subject_type='decision' → ('decision', subject_id)
--   5. event.subject_type='resource' → ('resource', subject_id)
--   6. fallback: queda en 'context' + context_actor_id.
--
-- Si la consequence pide algo no-genérico (e.g., scope='resource') se respeta.

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
  -- Si la consequence pide scope genérico (context o rule sin override) Y existe source_event,
  -- intentamos derivar un target más específico desde el activity_event.
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
      -- Si no hay target específico, fallback a context + context_actor_id
      -- (mejor que rule_id que para iOS no tiene detail view).
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

-- Backfill: aplicar la misma derivación a los rule_attention_items 'open' existentes.
update public.rule_attention_items rai
set cta_scope_kind = 'obligation',
    cta_scope_id = ae.obligation_id
from public.activity_events ae
where rai.source_event_id = ae.id
  and rai.status = 'open'
  and rai.cta_scope_kind in ('context', 'rule')
  and ae.obligation_id is not null;

update public.rule_attention_items rai
set cta_scope_kind = 'decision',
    cta_scope_id = ae.decision_id
from public.activity_events ae
where rai.source_event_id = ae.id
  and rai.status = 'open'
  and rai.cta_scope_kind in ('context', 'rule')
  and ae.decision_id is not null;

update public.rule_attention_items rai
set cta_scope_kind = 'resource',
    cta_scope_id = ae.resource_id
from public.activity_events ae
where rai.source_event_id = ae.id
  and rai.status = 'open'
  and rai.cta_scope_kind in ('context', 'rule')
  and ae.resource_id is not null;

-- Defensive: items que quedaron con cta_scope_kind=context apuntando al rule_id
-- (default original) → fix a apuntar al context_actor_id real.
update public.rule_attention_items
set cta_scope_id = context_actor_id
where status = 'open'
  and cta_scope_kind = 'context'
  and cta_scope_id <> context_actor_id;
