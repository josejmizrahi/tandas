-- Fix: evaluate_rules_for_event was consuming ruul.rule_eval_depth on every call,
-- even when zero rules matched the event. After D.14 added the trigger that fires
-- evaluate on every resource.* event, smokes that emit many resource events in one
-- txn (e.g. _smoke_resources) would burn the depth budget without any real rule
-- evaluation happening. Recursion safety is preserved because depth is still bumped
-- before consequences can emit new events.

CREATE OR REPLACE FUNCTION public.evaluate_rules_for_event(
  p_event_uuid_id uuid,
  p_mode text DEFAULT 'sync',
  p_parent_evaluation_id uuid DEFAULT NULL
) RETURNS SETOF uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  v_event_resource_type text;
  v_has_match boolean;
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

  IF p_mode NOT IN ('sync','async') THEN
    RAISE EXCEPTION 'invalid mode %', p_mode;
  END IF;

  SELECT * INTO v_event FROM public.group_events WHERE uuid_id = p_event_uuid_id;
  IF v_event.id IS NULL THEN
    RAISE EXCEPTION 'event % not found', p_event_uuid_id;
  END IF;

  IF v_event.entity_kind = 'resource' AND v_event.entity_id IS NOT NULL THEN
    SELECT resource_type INTO v_event_resource_type
      FROM public.group_resources WHERE id = v_event.entity_id;
  END IF;

  -- Early exit: avoid burning depth budget when nothing matches.
  SELECT EXISTS (
    SELECT 1 FROM public.group_rule_versions rv
    JOIN public.group_rules r ON r.current_version_id = rv.id
    WHERE r.group_id = v_event.group_id
      AND r.status = 'active'
      AND rv.execution_mode = 'engine'
      AND rv.trigger_event_type = v_event.event_type
      AND (r.scope_resource_type IS NULL OR r.scope_resource_type = v_event_resource_type)
      AND (r.scope_resource_id IS NULL OR r.scope_resource_id = v_event.entity_id)
  ) INTO v_has_match;

  IF NOT v_has_match THEN
    IF p_mode = 'async' THEN
      INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
      SELECT v_event.group_id, v_event.actor_user_id, 'rule_evaluated',
             jsonb_build_object('event_uuid_id', p_event_uuid_id, 'event_type', v_event.event_type)
      WHERE v_event.actor_user_id IS NOT NULL;
    END IF;
    RETURN;
  END IF;

  -- We have at least one matching rule version: now bump depth.
  PERFORM set_config('ruul.rule_eval_depth', (v_depth + 1)::text, true);

  FOR v_rv IN
    SELECT rv.* FROM public.group_rule_versions rv
    JOIN public.group_rules r ON r.current_version_id = rv.id
    WHERE r.group_id = v_event.group_id
      AND r.status = 'active'
      AND rv.execution_mode = 'engine'
      AND rv.trigger_event_type = v_event.event_type
      AND (r.scope_resource_type IS NULL OR r.scope_resource_type = v_event_resource_type)
      AND (r.scope_resource_id IS NULL OR r.scope_resource_id = v_event.entity_id)
  LOOP
    v_idem := p_event_uuid_id::text || '|' || v_rv.id::text;
    v_cycle := v_rv.id = ANY(v_parent_chain);

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
$$;
