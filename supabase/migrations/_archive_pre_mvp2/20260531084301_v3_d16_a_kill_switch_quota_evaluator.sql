-- V3 FASE D.16 — Mig A: kill switch (groups.engine_active) + token-bucket quota
-- + evaluator patched with both gates + rule.engine_skipped(rate_limited) audit.
-- Kill switch is silent (no audit emission). Rate limit emits one event per
-- skip so admins can see throttling in the timeline.

BEGIN;

-- =============================================================================
-- A1: groups.engine_active
-- =============================================================================
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS engine_active boolean NOT NULL DEFAULT true;

-- =============================================================================
-- A2: group_rule_engine_quotas + lazy UPSERT check
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.group_rule_engine_quotas (
  group_id                  uuid PRIMARY KEY REFERENCES public.groups(id) ON DELETE CASCADE,
  max_evals_per_window      int NOT NULL DEFAULT 60,
  window_seconds            int NOT NULL DEFAULT 60,
  current_window_started_at timestamptz NOT NULL DEFAULT now(),
  current_window_count      int NOT NULL DEFAULT 0,
  updated_at                timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT quotas_max_evals_pos CHECK (max_evals_per_window > 0),
  CONSTRAINT quotas_window_pos    CHECK (window_seconds > 0)
);

CREATE OR REPLACE FUNCTION public._rule_engine_quota_check(p_group_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now timestamptz := now();
  v_window_seconds int;
  v_max int;
  v_started timestamptz;
  v_count int;
  v_under_limit boolean;
BEGIN
  -- Lazy provisioning
  INSERT INTO public.group_rule_engine_quotas (group_id, current_window_started_at, current_window_count)
    VALUES (p_group_id, v_now, 0)
    ON CONFLICT (group_id) DO NOTHING;

  SELECT max_evals_per_window, window_seconds, current_window_started_at, current_window_count
    INTO v_max, v_window_seconds, v_started, v_count
    FROM public.group_rule_engine_quotas
   WHERE group_id = p_group_id
   FOR UPDATE;

  IF v_now - v_started >= make_interval(secs => v_window_seconds) THEN
    v_started := v_now;
    v_count := 0;
  END IF;

  IF v_count >= v_max THEN
    v_under_limit := false;
  ELSE
    v_under_limit := true;
    v_count := v_count + 1;
  END IF;

  UPDATE public.group_rule_engine_quotas
     SET current_window_started_at = v_started,
         current_window_count = v_count,
         updated_at = v_now
   WHERE group_id = p_group_id;

  RETURN v_under_limit;
END;
$$;

REVOKE ALL ON FUNCTION public._rule_engine_quota_check(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._rule_engine_quota_check(uuid) TO authenticated, service_role;

-- =============================================================================
-- A3: evaluate_rules_for_event — kill switch + quota gates
-- Order:
--   1. depth/mode/event lookup (existing)
--   2. NEW: kill switch (silent skip if engine_active=false)
--   3. resource_type resolve
--   4. early-exit if no matching rules (existing)
--   5. NEW: quota check (after we know we'd evaluate; emit rule.engine_skipped on throttle)
--   6. depth bump + FOR loop + lineage emission (existing)
-- =============================================================================
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
  v_emitted_item jsonb;
  v_engine_active boolean;
  v_quota_under_limit boolean;
BEGIN
  IF p_parent_evaluation_id IS NOT NULL THEN
    SELECT depth INTO v_parent_depth
      FROM public.group_rule_evaluations WHERE id = p_parent_evaluation_id;
    v_depth := COALESCE(v_parent_depth, 0) + 1;
    WITH RECURSIVE chain AS (
      SELECT id, rule_version_id, parent_evaluation_id
        FROM public.group_rule_evaluations WHERE id = p_parent_evaluation_id
       UNION ALL
      SELECT e.id, e.rule_version_id, e.parent_evaluation_id
        FROM public.group_rule_evaluations e
        JOIN chain c ON c.parent_evaluation_id = e.id
    )
    SELECT COALESCE(array_agg(rule_version_id), ARRAY[]::uuid[])
      INTO v_parent_chain FROM chain;
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

  -- D.16 kill switch — silent skip
  SELECT engine_active INTO v_engine_active FROM public.groups WHERE id = v_event.group_id;
  IF v_engine_active IS NOT TRUE THEN
    RETURN;
  END IF;

  IF v_event.entity_kind = 'resource' AND v_event.entity_id IS NOT NULL THEN
    SELECT resource_type INTO v_event_resource_type
      FROM public.group_resources WHERE id = v_event.entity_id;
  END IF;

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

  -- D.16 quota — only spend budget on events that would actually evaluate
  v_quota_under_limit := public._rule_engine_quota_check(v_event.group_id);
  IF NOT v_quota_under_limit THEN
    INSERT INTO public.group_events (group_id, actor_user_id, event_type, entity_kind, entity_id, summary, payload)
    VALUES (
      v_event.group_id, v_event.actor_user_id, 'rule.engine_skipped',
      'rule_engine', v_event.uuid_id,
      'Engine skip por rate_limit',
      jsonb_build_object(
        'reason','rate_limited',
        'source_event_uuid_id', p_event_uuid_id,
        'source_event_type', v_event.event_type));
    RETURN;
  END IF;

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
      FOR v_emitted_item IN SELECT jsonb_array_elements(v_actions_emitted) LOOP
        IF (v_emitted_item->>'status') IN ('emitted','failed') THEN
          INSERT INTO public.group_events (
            group_id, actor_user_id, event_type, entity_kind, entity_id, summary, payload
          ) VALUES (
            v_event.group_id, v_event.actor_user_id,
            'rule.consequence.executed', 'rule_consequence', v_eval_id,
            format('Engine ejecutó %s [%s]', v_emitted_item->>'kind', v_emitted_item->>'status'),
            jsonb_build_object(
              'consequence_kind', v_emitted_item->>'kind',
              'target_kind',      v_emitted_item->>'target_kind',
              'target_id',        v_emitted_item->>'target_id',
              'status',           v_emitted_item->>'status',
              'rule_version_id',  v_rv.id,
              'source_event_uuid_id', p_event_uuid_id,
              'recipient_user_ids', v_emitted_item->'recipient_user_ids'));
        END IF;
      END LOOP;

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

COMMIT;
