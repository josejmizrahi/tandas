-- R.2S restaura sobre R.2R: obligation_detail (+available_actions) y
-- evaluate_rules_for_event (+target_filter). R.2R se aplicó después de R.2S en
-- producción (divergencia pre-existente) y sobreescribió ambas.

-- obligation_detail con available_actions (R.2S.9)
create or replace function public.obligation_detail(p_obligation_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ob public.obligations%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ob from public.obligations where id = p_obligation_id;
  if v_ob.id is null then raise exception 'obligation not found' using errcode = 'P0002'; end if;

  if v_caller <> v_ob.debtor_actor_id
     and v_caller <> v_ob.creditor_actor_id
     and not (v_ob.context_actor_id is not null and public.is_context_member(v_ob.context_actor_id)) then
    raise exception 'not authorized to view this obligation' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'id', v_ob.id,
    'context_actor_id', v_ob.context_actor_id,
    'kind', v_ob.obligation_kind,
    'obligation_type', v_ob.obligation_type,
    'status', v_ob.status,
    'title', v_ob.title,
    'description', v_ob.description,
    'amount', v_ob.amount,
    'currency', v_ob.currency,
    'due_at', v_ob.due_at,
    'debtor_actor_id', v_ob.debtor_actor_id,
    'creditor_actor_id', v_ob.creditor_actor_id,
    'completed_at', v_ob.completed_at,
    'completed_by_actor_id', v_ob.completed_by_actor_id,
    'completion_notes', v_ob.completion_notes,
    'source_event_id', v_ob.source_event_id,
    'source_rule_id', v_ob.source_rule_id,
    'source_reservation_id', v_ob.source_reservation_id,
    'source_decision_id', v_ob.source_decision_id,
    'metadata', v_ob.metadata,
    'available_actions', public.obligation_available_actions(p_obligation_id, v_caller),
    'created_at', v_ob.created_at);
end; $$;

revoke all on function public.obligation_detail(uuid) from public, anon;
grant execute on function public.obligation_detail(uuid) to authenticated, service_role;
comment on function public.obligation_detail(uuid) is 'R.2S.9: detalle de obligación + available_actions.';

-- evaluate_rules_for_event con target_filter (R.2S.5) sobre el cuerpo R.2R (kind money/action)
create or replace function public.evaluate_rules_for_event(
  p_context_actor_id uuid,
  p_trigger_event_type text,
  p_subject_actor_id uuid,
  p_payload jsonb,
  p_source_event_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_rule record;
  v_matched integer := 0;
  v_obligations jsonb := '[]'::jsonb;
  v_rule_obligations jsonb;
  v_consequence jsonb;
  v_obligation_id uuid;
  v_eval_id uuid;
  v_outcome text;
  v_reason text;
  v_kind text;
  v_title text;
  v_obligation_type text;
  v_existing uuid;
  v_is_new boolean;
begin
  if v_caller is not null
     and v_caller <> p_subject_actor_id
     and not exists (
       select 1 from public.calendar_events e
       where e.id = p_source_event_id and e.host_actor_id = v_caller)
     and not public.has_actor_authority(p_context_actor_id, v_caller, 'rules.manage') then
    raise exception 'not authorized to evaluate rules for other actors' using errcode = '42501';
  end if;

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

    insert into public.rule_evaluations
      (rule_id, context_actor_id, triggering_event_type, triggering_object_id, outcome, metadata)
    values
      (v_rule.id, p_context_actor_id, p_trigger_event_type, p_source_event_id, v_outcome,
       jsonb_build_object('subject_actor_id', p_subject_actor_id, 'payload', p_payload))
    returning id into v_eval_id;

    if v_outcome = 'matched' then
      v_matched := v_matched + 1;

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
        end if;
      end loop;

      update public.rule_evaluations
         set consequences_emitted = jsonb_build_object('obligations', v_rule_obligations)
       where id = v_eval_id;

      v_obligations := v_obligations || v_rule_obligations;
    end if;

    perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'rule.evaluated',
      'rule_evaluation', v_eval_id,
      jsonb_build_object('rule_id', v_rule.id, 'rule_title', v_rule.title, 'outcome', v_outcome,
                         'triggered_by_event_type', p_trigger_event_type, 'source_rule_id', v_rule.id));
  end loop;

  return jsonb_build_object('rules_matched', v_matched, 'obligations_created', v_obligations);
end; $$;

revoke all on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) from public, anon;
grant execute on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) to authenticated, service_role;
comment on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) is
  'R.2S.5: evaluador universal de reglas (trigger + target_filter; cualquier dominio). Cuerpo R.2R (money/action).';