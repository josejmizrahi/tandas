-- 20260528060200 — V2-G3 sub-slice 3: explainability audit growth +
-- recursion-guard refactor de evaluate_rules_for_event.
--
-- Doctrine G3 §5 — cada fila en group_rule_evaluations debe poder
-- responder: qué regla matcheó, qué predicate pasó/falló (con
-- razón), qué consecuencias emitió, fue ciclo, a qué profundidad.
-- Estas columnas son nullable a nivel estructural — G3.3 ship la
-- shape sola; G3.4 dispatcher llena matched_predicate con el outcome
-- evaluado y actions_emitted con per-action detail.
-- cycle_detected lo settea inline este evaluator.

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

-- Refactor de evaluate_rules_for_event:
-- - Acepta p_parent_evaluation_id (NULL = root; cast_vote V2-G9 sigue
--   pasando 2 args, resuelve al default).
-- - depth = parent.depth + 1 cuando hay parent; sin parent cae al GUC
--   session-local 'ruul.rule_eval_depth' (cubre el path 2-arg legacy).
-- - Cycle detection: walk recursivo del parent_evaluation_id chain,
--   colecta rule_version_ids, flag cycle_detected=true si la regla
--   actual ya estuvo. Audit-only (la fila igual se inserta) para
--   que G3.5 pueda mostrar el ciclo, pero G3.4 dispatcher salta las
--   consequences cuando cycle_detected=true.
-- - matched_predicate pre-fill = rv.condition_tree raw; G3.4 lo
--   reemplaza con {passed, reason, evaluated_value}.

DROP FUNCTION IF EXISTS public.evaluate_rules_for_event(uuid, text);

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
