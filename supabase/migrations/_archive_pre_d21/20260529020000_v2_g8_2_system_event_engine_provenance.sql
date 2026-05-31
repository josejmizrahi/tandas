-- V2-G8 sub-slice 2 — system event engine provenance RPC
--
-- Reverse-lookup desde un group_events row hacia la group_rule_evaluation
-- que lo originó (si existe). Doctrina "¿por qué pasó esto?": el founder
-- ve un evento en Historia y quiere saber si lo causó el engine o un
-- humano. Sin ALTER de atom: usamos el target_id que el dispatcher ya
-- escribe en `actions_emitted[].target_id` cuando emite la consequence,
-- y matcheamos contra el UUID embedded en el event payload según
-- event_type.
--
-- Eventos engine-actionable mapeados (G3 polish atoms):
--   sanction.issued            → payload.sanction_id
--   member.state_changed       → payload.membership_id
--   money.pool_charge_created  → payload.pool_charge_id
--   decision.started_from_rule → payload.decision_id
-- Otros event_types devuelven {found:false, reason:'event_type_not_engine_actionable'}
-- sin error (sheet renderea "esto lo registró @actor manualmente").
--
-- Active-member gate idéntico a las otras read RPCs del feed.

CREATE OR REPLACE FUNCTION public.system_event_engine_provenance(
  p_event_uuid_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_event public.group_events%ROWTYPE;
  v_target_id uuid;
  v_eval public.group_rule_evaluations%ROWTYPE;
  v_rule_title text;
  v_source_event_summary jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_event FROM public.group_events WHERE uuid_id = p_event_uuid_id;
  IF v_event.uuid_id IS NULL THEN
    RETURN jsonb_build_object('found', false, 'reason', 'event_not_found');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = v_event.group_id
       AND gm.user_id = v_uid
       AND gm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', v_event.group_id
      USING errcode = '42501';
  END IF;

  v_target_id := CASE v_event.event_type
    WHEN 'sanction.issued'            THEN NULLIF(v_event.payload->>'sanction_id','')::uuid
    WHEN 'member.state_changed'       THEN NULLIF(v_event.payload->>'membership_id','')::uuid
    WHEN 'money.pool_charge_created'  THEN NULLIF(v_event.payload->>'pool_charge_id','')::uuid
    WHEN 'decision.started_from_rule' THEN NULLIF(v_event.payload->>'decision_id','')::uuid
    ELSE NULL
  END;

  IF v_target_id IS NULL THEN
    RETURN jsonb_build_object(
      'found',  false,
      'reason', 'event_type_not_engine_actionable',
      'event_type', v_event.event_type,
      'actor_user_id', v_event.actor_user_id
    );
  END IF;

  -- Reverse lookup: evaluation row that emitted a consequence whose
  -- target_id matches the UUID embedded in this event's payload. The
  -- jsonb containment operator @> handles unknown-position elements
  -- inside actions_emitted[].
  SELECT * INTO v_eval
    FROM public.group_rule_evaluations
   WHERE group_id = v_event.group_id
     AND actions_emitted @> jsonb_build_array(
       jsonb_build_object('target_id', v_target_id::text, 'status', 'emitted')
     )
   ORDER BY created_at DESC
   LIMIT 1;

  IF v_eval.id IS NULL THEN
    RETURN jsonb_build_object(
      'found',  false,
      'reason', 'no_engine_origin',
      'event_type', v_event.event_type,
      'actor_user_id', v_event.actor_user_id
    );
  END IF;

  -- Hidratar rule title (incluye versions ya superseded — usa rule_id
  -- direct, no current_version_id, para que rule_change post-eval no
  -- rompa el lookup retrospectivo).
  SELECT gr.title INTO v_rule_title
    FROM public.group_rule_versions grv
    JOIN public.group_rules gr ON gr.id = grv.rule_id
   WHERE grv.id = v_eval.rule_version_id;

  SELECT jsonb_build_object(
    'event_uuid',     se.uuid_id,
    'event_type',     se.event_type,
    'actor_user_id',  se.actor_user_id,
    'occurred_at',    se.created_at,
    'summary',        se.summary
  ) INTO v_source_event_summary
    FROM public.group_events se
   WHERE se.uuid_id = v_eval.source_event_id;

  RETURN jsonb_build_object(
    'found',             true,
    'evaluation_id',     v_eval.id,
    'rule_version_id',   v_eval.rule_version_id,
    'rule_title',        v_rule_title,
    'matched_predicate', v_eval.matched_predicate,
    'cycle_detected',    v_eval.cycle_detected,
    'depth',             v_eval.depth,
    'evaluated_at',      v_eval.created_at,
    'source_event',      v_source_event_summary
  );
END;
$$;

REVOKE ALL ON FUNCTION public.system_event_engine_provenance(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.system_event_engine_provenance(uuid) TO authenticated;

COMMENT ON FUNCTION public.system_event_engine_provenance(uuid) IS
  'V2-G8.2: reverse lookup desde group_events.uuid_id a la group_rule_evaluation que originó el evento (si lo hizo el engine). Returns {found, evaluation_id?, rule_title?, matched_predicate?, source_event?, reason?}. Active-member gate.';
