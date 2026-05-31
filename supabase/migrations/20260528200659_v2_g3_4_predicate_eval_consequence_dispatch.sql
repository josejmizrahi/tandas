-- V2-G3.4: predicate evaluator + consequence dispatcher + integration.
-- Closes the "rules are policies not text" loop: evaluate_rules_for_event
-- now runs the IF clause against the actual event, dispatches each THEN
-- consequence routed by atom.execution (sync inline vs async outbox),
-- and persists per-action outcome detail back into the audit row.

-- _rule_eval_predicate: evaluates one condition_tree atom against an
-- event. Returns {passed, reason, evaluated_value}. NULL/empty
-- predicate = pass (rule with no IF always fires).
CREATE OR REPLACE FUNCTION public._rule_eval_predicate(
  p_condition_tree jsonb,
  p_event public.group_events
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_kind text;
  v_fields jsonb;
  v_actor_membership uuid;
  v_actor_roles text[];
  v_required_roles jsonb;
  v_role text;
  v_match boolean := false;
  v_event_amount numeric;
  v_threshold numeric;
  v_target uuid;
  v_only_self boolean;
BEGIN
  IF p_condition_tree IS NULL OR p_condition_tree = '{}'::jsonb OR p_condition_tree = 'null'::jsonb THEN
    RETURN jsonb_build_object('passed', true, 'reason', 'no_predicate');
  END IF;

  v_kind := p_condition_tree->>'kind';
  v_fields := COALESCE(p_condition_tree->'fields', '{}'::jsonb);

  IF v_kind = 'condition.actor_role_in' THEN
    v_required_roles := v_fields->'roles';
    IF v_required_roles IS NULL OR jsonb_typeof(v_required_roles) <> 'array' THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'missing_roles', 'kind', v_kind);
    END IF;
    SELECT id INTO v_actor_membership
      FROM public.group_memberships
     WHERE group_id = p_event.group_id AND user_id = p_event.actor_user_id;
    IF v_actor_membership IS NULL THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'actor_not_member', 'kind', v_kind);
    END IF;
    SELECT COALESCE(array_agg(r.key), ARRAY[]::text[]) INTO v_actor_roles
      FROM public.group_member_roles mr
      JOIN public.group_roles r ON r.id = mr.role_id
     WHERE mr.membership_id = v_actor_membership;
    FOR v_role IN SELECT jsonb_array_elements_text(v_required_roles) LOOP
      IF v_role = ANY(v_actor_roles) THEN
        v_match := true; EXIT;
      END IF;
    END LOOP;
    RETURN jsonb_build_object(
      'passed', v_match,
      'reason', CASE WHEN v_match THEN 'role_match' ELSE 'no_role_match' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object('actor_roles', to_jsonb(v_actor_roles))
    );

  ELSIF v_kind = 'condition.amount_above' THEN
    v_threshold := COALESCE((v_fields->>'amount')::numeric, 0);
    v_event_amount := COALESCE((p_event.payload->>'amount')::numeric, 0);
    v_match := v_event_amount > v_threshold;
    RETURN jsonb_build_object(
      'passed', v_match,
      'reason', CASE WHEN v_match THEN 'above_threshold' ELSE 'below_threshold' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object('event_amount', v_event_amount, 'threshold', v_threshold)
    );

  ELSIF v_kind = 'condition.target_self' THEN
    v_only_self := COALESCE((v_fields->>'only_self')::boolean, true);
    v_target := NULLIF(p_event.payload->>'target_user_id','')::uuid;
    IF NOT v_only_self THEN
      RETURN jsonb_build_object('passed', true, 'reason', 'self_check_disabled', 'kind', v_kind);
    END IF;
    v_match := (v_target IS NOT DISTINCT FROM p_event.actor_user_id);
    RETURN jsonb_build_object(
      'passed', v_match,
      'reason', CASE WHEN v_match THEN 'actor_is_target' ELSE 'actor_not_target' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object('actor', p_event.actor_user_id, 'target', v_target)
    );

  ELSE
    RETURN jsonb_build_object('passed', false, 'reason', 'unknown_predicate_kind',
                              'kind', COALESCE(v_kind,'<null>'));
  END IF;
END;
$$;

-- _rule_eval_dispatch: dispatches one consequence atom. Catches
-- handler errors so a failing consequence doesn't roll back the
-- whole evaluation — returns {kind, execution, status, target_id?,
-- error?} so the audit row tells the full story.
CREATE OR REPLACE FUNCTION public._rule_eval_dispatch(
  p_action jsonb,
  p_event public.group_events,
  p_rule_version_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_kind text := p_action->>'kind';
  v_fields jsonb := COALESCE(p_action->'fields', '{}'::jsonb);
  v_target_user_id uuid;
  v_target_membership uuid;
  v_severity int;
  v_message text;
  v_audience text;
  v_new_state text;
  v_reason text;
  v_sanction_id uuid;
  v_error text;
  v_notified int;
BEGIN
  v_target_user_id := COALESCE(
    NULLIF(p_event.payload->>'target_user_id','')::uuid,
    p_event.actor_user_id
  );
  SELECT id INTO v_target_membership
    FROM public.group_memberships
   WHERE group_id = p_event.group_id AND user_id = v_target_user_id;

  IF v_kind = 'consequence.issue_sanction' THEN
    v_severity := COALESCE((v_fields->>'severity')::int, 1);
    v_reason := COALESCE(v_fields->>'reason', 'Regla con engine');
    IF v_target_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'target_membership_not_found');
    END IF;
    BEGIN
      v_sanction_id := public.issue_sanction(
        p_group_id             => p_event.group_id,
        p_target_membership_id => v_target_membership,
        p_sanction_kind        => 'warning',
        p_reason               => v_reason,
        p_amount               => NULL,
        p_unit                 => NULL,
        p_ends_at              => NULL,
        p_rule_version_id      => p_rule_version_id,
        p_source_event_id      => p_event.uuid_id,
        p_client_id            => NULL
      );
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', v_sanction_id,
                                'severity', v_severity);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.set_membership_state' THEN
    v_new_state := v_fields->>'new_state';
    v_reason := v_fields->>'reason';
    IF v_target_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'target_membership_not_found');
    END IF;
    BEGIN
      PERFORM public.set_membership_state(v_target_membership, v_new_state, v_reason, NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', v_target_membership,
                                'new_state', v_new_state);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.send_notification' THEN
    v_message := COALESCE(v_fields->>'message', 'Regla disparada');
    v_audience := COALESCE(v_fields->>'audience', 'admins');
    v_notified := 0;
    BEGIN
      IF v_audience = 'actor' AND p_event.actor_user_id IS NOT NULL THEN
        INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
        VALUES (p_event.group_id, p_event.actor_user_id, 'rule_consequence',
                jsonb_build_object('rule_version_id', p_rule_version_id,
                                   'message', v_message,
                                   'source_event_id', p_event.uuid_id));
        v_notified := 1;
      ELSIF v_audience = 'group' THEN
        WITH ins AS (
          INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
          SELECT p_event.group_id, gm.user_id, 'rule_consequence',
                 jsonb_build_object('rule_version_id', p_rule_version_id,
                                    'message', v_message,
                                    'source_event_id', p_event.uuid_id)
            FROM public.group_memberships gm
           WHERE gm.group_id = p_event.group_id AND gm.status = 'active'
          RETURNING 1
        )
        SELECT count(*) INTO v_notified FROM ins;
      ELSE -- admins (default)
        WITH ins AS (
          INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
          SELECT DISTINCT p_event.group_id, gm.user_id, 'rule_consequence',
                 jsonb_build_object('rule_version_id', p_rule_version_id,
                                    'message', v_message,
                                    'source_event_id', p_event.uuid_id)
            FROM public.group_memberships gm
            JOIN public.group_member_roles mr ON mr.membership_id = gm.id
            JOIN public.group_roles r ON r.id = mr.role_id
           WHERE gm.group_id = p_event.group_id AND gm.status = 'active'
             AND r.key IN ('admin','founder')
          RETURNING 1
        )
        SELECT count(*) INTO v_notified FROM ins;
      END IF;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'async',
                                'status', 'emitted', 'audience', v_audience,
                                'recipients', v_notified);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'async',
                                'status', 'failed', 'error', v_error);
    END;

  ELSE
    RETURN jsonb_build_object('kind', COALESCE(v_kind,'<null>'),
                              'execution', 'unknown',
                              'status', 'skipped', 'error', 'unknown_consequence_kind');
  END IF;
END;
$$;

-- Integration: evaluate_rules_for_event now runs predicate + dispatcher
-- for each matched rule. cycle_detected rules still land in the audit
-- table (transparency) but their consequences are skipped.
CREATE OR REPLACE FUNCTION public.evaluate_rules_for_event(
  p_event_uuid_id uuid,
  p_mode text DEFAULT 'sync',
  p_parent_evaluation_id uuid DEFAULT NULL
)
RETURNS SETOF uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_depth         int := 0;
  v_parent_depth  int;
  v_parent_chain  uuid[] := ARRAY[]::uuid[];
  v_max_depth     constant int := 5;
  v_event         public.group_events%rowtype;
  v_rv            public.group_rule_versions%rowtype;
  v_eval_id       uuid;
  v_idem          text;
  v_cycle         boolean;
  v_predicate_outcome jsonb;
  v_actions_emitted jsonb := '[]'::jsonb;
  v_conseq jsonb;
  v_action_result jsonb;
BEGIN
  IF p_parent_evaluation_id IS NOT NULL THEN
    SELECT depth INTO v_parent_depth
      FROM public.group_rule_evaluations
     WHERE id = p_parent_evaluation_id;
    v_depth := COALESCE(v_parent_depth, 0) + 1;
    WITH RECURSIVE chain AS (
      SELECT id, rule_version_id, parent_evaluation_id
        FROM public.group_rule_evaluations
       WHERE id = p_parent_evaluation_id
       UNION ALL
      SELECT e.id, e.rule_version_id, e.parent_evaluation_id
        FROM public.group_rule_evaluations e
        JOIN chain c ON c.parent_evaluation_id = e.id
    )
    SELECT COALESCE(array_agg(rule_version_id), ARRAY[]::uuid[])
      INTO v_parent_chain
      FROM chain;
  ELSE
    v_depth := COALESCE(nullif(current_setting('ruul.rule_eval_depth', true), '')::int, 0);
  END IF;

  IF v_depth >= v_max_depth THEN
    RAISE EXCEPTION 'rule evaluation depth % exceeds max % for event %',
      v_depth, v_max_depth, p_event_uuid_id;
  END IF;
  PERFORM set_config('ruul.rule_eval_depth', (v_depth + 1)::text, true);

  IF p_mode NOT IN ('sync','async') THEN
    RAISE EXCEPTION 'invalid mode %', p_mode;
  END IF;

  SELECT * INTO v_event FROM public.group_events WHERE uuid_id = p_event_uuid_id;
  IF v_event.id IS NULL THEN
    RAISE EXCEPTION 'event % not found', p_event_uuid_id;
  END IF;

  FOR v_rv IN
    SELECT rv.* FROM public.group_rule_versions rv
    JOIN public.group_rules r ON r.current_version_id = rv.id
    WHERE r.group_id = v_event.group_id
      AND r.status = 'active'
      AND rv.execution_mode = 'engine'
      AND rv.trigger_event_type = v_event.event_type
  LOOP
    v_idem := p_event_uuid_id::text || '|' || v_rv.id::text;
    v_cycle := v_rv.id = ANY(v_parent_chain);

    -- Evaluate predicate (skip dispatch when cycle; still record outcome).
    v_predicate_outcome := public._rule_eval_predicate(v_rv.condition_tree, v_event);
    v_actions_emitted := '[]'::jsonb;

    IF NOT v_cycle AND (v_predicate_outcome->>'passed')::boolean THEN
      FOR v_conseq IN SELECT jsonb_array_elements(COALESCE(v_rv.consequences,'[]'::jsonb)) LOOP
        v_action_result := public._rule_eval_dispatch(v_conseq, v_event, v_rv.id);
        v_actions_emitted := v_actions_emitted || jsonb_build_array(v_action_result);
      END LOOP;
    END IF;

    INSERT INTO public.group_rule_evaluations (
      rule_version_id, group_id, source_event_id, matched,
      consequences_emitted, idempotency_key,
      parent_evaluation_id, depth, matched_predicate, cycle_detected,
      actions_emitted
    ) VALUES (
      v_rv.id, v_event.group_id, p_event_uuid_id,
      (v_predicate_outcome->>'passed')::boolean,
      COALESCE(v_rv.consequences, '[]'::jsonb), v_idem,
      p_parent_evaluation_id, v_depth,
      v_predicate_outcome, v_cycle,
      v_actions_emitted
    )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING id INTO v_eval_id;
    IF v_eval_id IS NOT NULL THEN
      RETURN NEXT v_eval_id;
    END IF;
  END LOOP;

  IF p_mode = 'async' THEN
    INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
    SELECT v_event.group_id, v_event.actor_user_id, 'rule_evaluated',
           jsonb_build_object('event_uuid_id', p_event_uuid_id, 'event_type', v_event.event_type)
    WHERE v_event.actor_user_id IS NOT NULL;
  END IF;

  RETURN;
END;
$function$;
