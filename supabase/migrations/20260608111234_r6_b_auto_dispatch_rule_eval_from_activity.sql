-- R.6.B — Auto-dispatch rule evaluation desde activity_events trigger.
--
-- Idea: cualquier RPC que ya emite activity_event (resource.created, obligation.created,
-- decision.executed, member.joined, document.created, conflict.detected, etc.) automáticamente
-- dispara `_r6_eval_rules_core` sin tocar cada RPC. Cero loop riesgo gracias a guards:
--   1. Skip si payload->>'system' = 'true' (engine-emitted)
--   2. Skip si event_type like 'rule.%' (engine self-emit)
--   3. Skip si event_type = 'fine.created' (engine self-emit)
--   4. Skip si context_actor_id IS NULL (no contexto = no scope = no rules)
--   5. Skip si actor_id IS NULL (no subject = nothing to evaluate)
--   6. Best-effort: exception caught, raise warning → activity insert no falla
--
-- Idempotency_key (R.6.A) garantiza que doble-invocación (e.g. trigger + manual call desde
-- check_in_participant) no duplica consequences.
--
-- Refactor: split evaluator en `_r6_eval_rules_core` (sin auth check) + wrapper público
-- `evaluate_rules_for_event` (con auth check). El trigger llama core directamente porque
-- la activity ya fue emitida bajo authorization del RPC original.

-- 1. Core evaluator sin auth check.
create or replace function public._r6_eval_rules_core(
  p_context_actor_id uuid,
  p_trigger_event_type text,
  p_subject_actor_id uuid,
  p_payload jsonb,
  p_source_event_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to public, auth
as $$
declare
  v_rule record;
  v_matched integer := 0;
  v_obligations jsonb := '[]'::jsonb;
  v_attentions jsonb := '[]'::jsonb;
  v_rule_obligations jsonb;
  v_rule_attentions jsonb;
  v_consequence jsonb;
  v_consequence_index int;
  v_obligation_id uuid;
  v_attention_id uuid;
  v_eval_id uuid;
  v_outcome text;
  v_reason text;
  v_kind text;
  v_title text;
  v_obligation_type text;
  v_existing uuid;
  v_is_new boolean;
  v_idempotency_key text;
begin
  for v_rule in
    select * from public.rules
    where context_actor_id = p_context_actor_id
      and status = 'active'
      and trigger_event_type = p_trigger_event_type
      and public._rule_target_matches(coalesce(target_filter, '{}'::jsonb), p_payload)
  loop
    v_outcome := case when public._eval_condition(v_rule.condition_tree, p_payload)
                      then 'matched' else 'not_matched' end;
    v_rule_obligations := '[]'::jsonb;
    v_rule_attentions := '[]'::jsonb;

    v_idempotency_key := public._r6_compute_idempotency_key(
      v_rule.id, p_source_event_id, p_subject_actor_id, -1
    );

    insert into public.rule_evaluations
      (rule_id, context_actor_id, triggering_event_type, triggering_object_id,
       outcome, metadata, idempotency_key)
    values
      (v_rule.id, p_context_actor_id, p_trigger_event_type, p_source_event_id, v_outcome,
       jsonb_build_object('subject_actor_id', p_subject_actor_id, 'payload', p_payload),
       v_idempotency_key)
    on conflict (idempotency_key) do nothing
    returning id into v_eval_id;

    if v_eval_id is null then
      select id into v_eval_id from public.rule_evaluations
       where idempotency_key = v_idempotency_key
       limit 1;
      continue;
    end if;

    if v_outcome = 'matched' then
      v_matched := v_matched + 1;
      v_consequence_index := 0;

      for v_consequence in select * from jsonb_array_elements(coalesce(v_rule.consequences, '[]'::jsonb)) loop
        if v_consequence->>'type' in ('fine', 'create_obligation') then
          v_kind := coalesce(v_consequence->>'kind', 'money');
          v_title := coalesce(v_consequence->>'title', v_rule.title);
          v_reason := coalesce(v_consequence->>'reason', v_consequence->>'title', v_rule.title);

          select id into v_existing from public.obligations
           where source_rule_id = v_rule.id
             and source_event_id is not distinct from p_source_event_id
             and debtor_actor_id = p_subject_actor_id
             and metadata->>'reason' is not distinct from v_reason
             and status <> 'cancelled'
           limit 1;

          v_is_new := v_existing is null;
          if v_is_new then
            if v_kind = 'money' then
              v_obligation_type := coalesce(v_consequence->>'obligation_type', 'fine');
              insert into public.obligations
                (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_kind, obligation_type,
                 amount, currency, source_event_id, source_rule_id, metadata)
              values
                (p_context_actor_id, p_subject_actor_id, p_context_actor_id, 'money', v_obligation_type,
                 (v_consequence->>'amount')::numeric, coalesce(v_consequence->>'currency', 'MXN'),
                 p_source_event_id, v_rule.id,
                 jsonb_build_object(
                   'reason', v_reason, 'participant_actor_id', p_subject_actor_id,
                   'triggering_event_type', p_trigger_event_type, 'rule_evaluation_id', v_eval_id,
                   'rule_title', v_rule.title, 'trigger', p_trigger_event_type,
                   'target_scope', v_rule.target_scope))
              returning id into v_obligation_id;
            else
              v_obligation_type := coalesce(v_consequence->>'obligation_type', 'other');
              insert into public.obligations
                (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_kind, obligation_type,
                 title, description, due_at, source_event_id, source_rule_id, metadata)
              values
                (p_context_actor_id, p_subject_actor_id, p_context_actor_id, v_kind, v_obligation_type,
                 v_title, v_consequence->>'description',
                 nullif(v_consequence->>'due_at', '')::timestamptz,
                 p_source_event_id, v_rule.id,
                 jsonb_build_object(
                   'reason', v_reason, 'participant_actor_id', p_subject_actor_id,
                   'triggering_event_type', p_trigger_event_type, 'rule_evaluation_id', v_eval_id,
                   'rule_title', v_rule.title, 'trigger', p_trigger_event_type,
                   'target_scope', v_rule.target_scope))
              returning id into v_obligation_id;
            end if;

            perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'obligation.created',
              'obligation', v_obligation_id,
              jsonb_build_object('rule_title', v_rule.title, 'kind', v_kind, 'title', v_title,
                                 'amount', (v_consequence->>'amount')::numeric,
                                 'obligation_type', v_obligation_type, 'reason', v_reason,
                                 'system', true, 'triggered_by_event_type', p_trigger_event_type,
                                 'source_rule_id', v_rule.id),
              p_obligation_id := v_obligation_id);

            if v_kind = 'money' and v_obligation_type = 'fine' then
              perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'fine.created',
                'obligation', v_obligation_id,
                jsonb_build_object('rule_title', v_rule.title, 'amount', (v_consequence->>'amount')::numeric,
                                   'reason', v_reason,
                                   'system', true, 'triggered_by_event_type', p_trigger_event_type,
                                   'source_rule_id', v_rule.id),
                p_obligation_id := v_obligation_id);
            end if;
          else
            v_obligation_id := v_existing;
          end if;

          v_rule_obligations := v_rule_obligations || jsonb_build_object(
            'obligation_id', v_obligation_id, 'rule_id', v_rule.id, 'kind', v_kind,
            'amount', (v_consequence->>'amount')::numeric, 'already_existed', not v_is_new);

        elsif v_consequence->>'type' = 'emit_attention' then
          v_attention_id := public._r6_emit_attention(
            p_context_actor_id := p_context_actor_id,
            p_subject_actor_id := p_subject_actor_id,
            p_consequence := v_consequence,
            p_rule_id := v_rule.id,
            p_source_event_id := p_source_event_id,
            p_idempotency_key := public._r6_compute_idempotency_key(
              v_rule.id, p_source_event_id, p_subject_actor_id, v_consequence_index
            )
          );
          v_rule_attentions := v_rule_attentions || jsonb_build_object(
            'attention_id', v_attention_id,
            'kind', coalesce(v_consequence->>'kind', 'rule_violation'),
            'rule_id', v_rule.id,
            'already_existed', v_attention_id is null
          );
        end if;

        v_consequence_index := v_consequence_index + 1;
      end loop;

      update public.rule_evaluations
         set consequences_emitted = jsonb_build_object(
           'obligations', v_rule_obligations,
           'attentions',  v_rule_attentions
         )
       where id = v_eval_id;

      v_obligations := v_obligations || v_rule_obligations;
      v_attentions := v_attentions || v_rule_attentions;
    end if;

    perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'rule.evaluated',
      'rule_evaluation', v_eval_id,
      jsonb_build_object('rule_id', v_rule.id, 'rule_title', v_rule.title, 'outcome', v_outcome,
                         'triggered_by_event_type', p_trigger_event_type, 'source_rule_id', v_rule.id));
  end loop;

  return jsonb_build_object(
    'rules_matched', v_matched,
    'obligations_created', v_obligations,
    'attentions_emitted', v_attentions
  );
end;
$$;

-- 2. Wrapper público con auth check. Delega a _r6_eval_rules_core.
create or replace function public.evaluate_rules_for_event(
  p_context_actor_id uuid,
  p_trigger_event_type text,
  p_subject_actor_id uuid,
  p_payload jsonb,
  p_source_event_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is not null
     and v_caller <> p_subject_actor_id
     and not exists (
       select 1 from public.calendar_events e
       where e.id = p_source_event_id and e.host_actor_id = v_caller)
     and not public.has_actor_authority(p_context_actor_id, v_caller, 'rules.manage') then
    raise exception 'not authorized to evaluate rules for other actors' using errcode = '42501';
  end if;

  return public._r6_eval_rules_core(
    p_context_actor_id := p_context_actor_id,
    p_trigger_event_type := p_trigger_event_type,
    p_subject_actor_id := p_subject_actor_id,
    p_payload := p_payload,
    p_source_event_id := p_source_event_id
  );
end;
$$;

-- 3. Trigger dispatcher.
create or replace function public._r6_dispatch_rule_eval()
returns trigger
language plpgsql
security definer
set search_path to public, auth
as $$
begin
  -- Guards anti-recursión:
  if NEW.payload ? 'system' and (NEW.payload->>'system')::boolean = true then return null; end if;
  if NEW.event_type like 'rule.%' then return null; end if;
  if NEW.event_type like 'fine.created' then return null; end if;

  -- Skip si falta scope o subject.
  if NEW.context_actor_id is null then return null; end if;
  if NEW.actor_id is null then return null; end if;

  begin
    perform public._r6_eval_rules_core(
      p_context_actor_id := NEW.context_actor_id,
      p_trigger_event_type := NEW.event_type,
      p_subject_actor_id := NEW.actor_id,
      p_payload := coalesce(NEW.payload, '{}'::jsonb),
      p_source_event_id := NEW.id
    );
  exception when others then
    -- Best-effort: warn pero no romper la activity insertion.
    raise warning 'R.6.B rule dispatch failed for activity_event % type=%: %',
      NEW.id, NEW.event_type, sqlerrm;
  end;

  return null;
end;
$$;

-- 4. Wire trigger. AFTER INSERT — la activity row debe existir para que
--    rule_evaluations.triggering_object_id apunte a algo válido.
drop trigger if exists trg_r6_dispatch_rule_eval on public.activity_events;
create trigger trg_r6_dispatch_rule_eval
  after insert on public.activity_events
  for each row execute function public._r6_dispatch_rule_eval();
