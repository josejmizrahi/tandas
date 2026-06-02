-- V3-D.18 FASE E
-- decision_provenance(p_decision_id) returns jsonb — "¿Por qué existe?"
-- Resolves the originating rule/event/consequence when one exists.
-- Inverted lookup: find the group_events row whose payload references the
-- decision_id (start_vote consequence emits decision.created with decision_id),
-- then chain to the rule evaluation that emitted it.
-- Falls back gracefully when manual (`source='manual'`).

CREATE OR REPLACE FUNCTION public.decision_provenance(p_decision_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid              uuid := auth.uid();
  v_d                public.group_decisions%ROWTYPE;
  v_creation_event   public.group_events%ROWTYPE;
  v_eval             public.group_rule_evaluations%ROWTYPE;
  v_rule_title       text;
  v_consequence_kind text;
  v_source_event     jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_d FROM public.group_decisions WHERE id = p_decision_id;
  IF v_d.id IS NULL THEN
    RETURN jsonb_build_object('found', false, 'reason', 'decision_not_found');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = v_d.group_id AND gm.user_id = v_uid AND gm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', v_d.group_id
      USING errcode = '42501';
  END IF;

  -- Look for a rule.consequence.executed event whose payload.target_id is this decision.
  SELECT * INTO v_creation_event
  FROM public.group_events
  WHERE group_id = v_d.group_id
    AND event_type = 'rule.consequence.executed'
    AND (payload->>'target_id')::uuid = p_decision_id
    AND (payload->>'target_kind') = 'decision'
  ORDER BY occurred_at DESC
  LIMIT 1;

  IF v_creation_event.id IS NULL THEN
    -- Decision was created manually (or by a legacy non-engine path).
    RETURN jsonb_build_object(
      'found',              true,
      'decision_id',        v_d.id,
      'source_type',        'manual',
      'source_event_id',    NULL,
      'source_rule_title',  NULL,
      'source_consequence_kind', NULL,
      'source_entity_kind', v_d.reference_kind,
      'source_entity_id',   v_d.reference_id,
      'created_at',         v_d.created_at,
      'created_by',         v_d.created_by,
      'template_key',       v_d.template_key
    );
  END IF;

  v_consequence_kind := v_creation_event.payload->>'consequence_kind';

  -- Resolve the evaluation that produced this consequence event.
  SELECT * INTO v_eval
  FROM public.group_rule_evaluations
  WHERE group_id = v_d.group_id
    AND rule_version_id = (v_creation_event.payload->>'rule_version_id')::uuid
    AND source_event_id = NULLIF(v_creation_event.payload->>'source_event_uuid_id','')::uuid
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_eval.id IS NOT NULL THEN
    SELECT gr.title INTO v_rule_title
    FROM public.group_rule_versions grv
    JOIN public.group_rules gr ON gr.id = grv.rule_id
    WHERE grv.id = v_eval.rule_version_id;

    SELECT jsonb_build_object(
      'event_uuid',    se.uuid_id,
      'event_type',    se.event_type,
      'actor_user_id', se.actor_user_id,
      'occurred_at',   se.created_at,
      'summary',       se.summary
    ) INTO v_source_event
    FROM public.group_events se
    WHERE se.uuid_id = v_eval.source_event_id;
  END IF;

  RETURN jsonb_build_object(
    'found',                   true,
    'decision_id',             v_d.id,
    'source_type',             'rule',
    'source_event_id',         v_creation_event.uuid_id,
    'source_rule_title',       v_rule_title,
    'source_consequence_kind', v_consequence_kind,
    'source_entity_kind',      v_d.reference_kind,
    'source_entity_id',        v_d.reference_id,
    'evaluation_id',           v_eval.id,
    'matched_predicate',       v_eval.matched_predicate,
    'depth',                   v_eval.depth,
    'created_at',              v_d.created_at,
    'created_by',              v_d.created_by,
    'template_key',            v_d.template_key,
    'source_event',            v_source_event
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.decision_provenance(uuid) TO authenticated;

COMMENT ON FUNCTION public.decision_provenance(uuid) IS
  'V3-D.18 — "¿Por qué existe esta decisión?" Returns source_type=manual|rule + rule title + consequence kind + reference_kind/id. Active-member gate.';
