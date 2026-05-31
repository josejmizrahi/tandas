-- V2-G3.3: explainability audit growth for group_rule_evaluations
-- + recursion-guard refactor of evaluate_rules_for_event.
--
-- Doctrine G3 §5 (explainability) requires every evaluation row to
-- answer: which rule matched, what was the predicate outcome, which
-- consequences were emitted, was the chain a cycle, what depth.
-- These columns are nullable on the structural row (G3.3 ships the
-- schema only); G3.4 dispatcher fills matched_predicate.outcome and
-- actions_emitted detail. cycle_detected is set inline by the
-- evaluator below.

ALTER TABLE public.group_rule_evaluations
  ADD COLUMN IF NOT EXISTS parent_evaluation_id uuid
    REFERENCES public.group_rule_evaluations(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS depth int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS matched_predicate jsonb,
  ADD COLUMN IF NOT EXISTS actions_emitted jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS cycle_detected boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_group_rule_evaluations_parent
  ON public.group_rule_evaluations(parent_evaluation_id);

CREATE INDEX IF NOT EXISTS idx_group_rule_evaluations_group_created
  ON public.group_rule_evaluations(group_id, created_at DESC);

-- Refactor evaluate_rules_for_event:
-- - Accepts optional p_parent_evaluation_id (NULL = root, e.g. the
--   cast_vote V2-G9 hook keeps working with 2 args).
-- - depth derived from parent.depth + 1 when parent given; otherwise
--   falls back to the session GUC.
-- - Walks the parent chain (WITH RECURSIVE) collecting rule_version_ids
--   so we can detect a same-rule cycle BEFORE inserting another row.
-- - Persists parent_evaluation_id + depth + cycle_detected on each
--   row + pre-fills matched_predicate with the rule version's raw
--   condition_tree so G3.4 dispatcher can overwrite it with the
--   evaluated outcome `{passed, reason, evaluated_value}`.
-- - When a cycle is detected the row still lands (audit-only) but
--   marked cycle_detected=true so the dispatcher in G3.4 can skip
--   emitting consequences without erasing the trail.
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
BEGIN
  -- Depth + chain.
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
    INSERT INTO public.group_rule_evaluations (
      rule_version_id, group_id, source_event_id, matched,
      consequences_emitted, idempotency_key,
      parent_evaluation_id, depth, matched_predicate, cycle_detected
    ) VALUES (
      v_rv.id, v_event.group_id, p_event_uuid_id, true,
      COALESCE(v_rv.consequences, '[]'::jsonb), v_idem,
      p_parent_evaluation_id, v_depth,
      v_rv.condition_tree, v_cycle
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
