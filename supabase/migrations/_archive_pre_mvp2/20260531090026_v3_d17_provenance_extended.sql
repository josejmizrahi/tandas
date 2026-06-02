-- V3-D.17 FASE D-back
-- Extends `system_event_engine_provenance` to cover the D.14/D.15 event
-- surface so that WhyDidThisHappenSheet can explain consequences across:
--   * obligation creation (peer_obligation, create_pool_charge in D.15)
--   * notification dispatch (send_notification audience)
--   * resource lifecycle effects (archive/transfer/etc., D.14)
--   * direct `rule.consequence.executed` events (D.15 dispatcher emits
--     these on every consequence regardless of side-effect entity).
--
-- It also enriches the returned jsonb with `consequence_kind` and
-- `target_kind` when available so iOS can render a human sentence
-- like "ejecutó consequence.create_pool_charge → obligation".
--
-- Backwards compatible: every shape returned by the previous version is
-- preserved; new keys are added under the same envelope.

CREATE OR REPLACE FUNCTION public.system_event_engine_provenance(p_event_uuid_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_event public.group_events%ROWTYPE;
  v_target_id uuid;
  v_consequence_kind text;
  v_target_kind text;
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
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', v_event.group_id
      USING errcode = '42501';
  END IF;

  -- D.17: rule.consequence.executed is the canonical exit. If we land
  -- on one directly, we already have the consequence shape on payload
  -- and can resolve the originating evaluation via source_event_uuid_id.
  IF v_event.event_type = 'rule.consequence.executed' THEN
    v_consequence_kind := v_event.payload->>'consequence_kind';
    v_target_kind      := v_event.payload->>'target_kind';
    v_target_id        := NULLIF(v_event.payload->>'target_id','')::uuid;

    SELECT * INTO v_eval
      FROM public.group_rule_evaluations
     WHERE rule_version_id = (v_event.payload->>'rule_version_id')::uuid
       AND group_id = v_event.group_id
       AND source_event_id = NULLIF(v_event.payload->>'source_event_uuid_id','')::uuid
     ORDER BY created_at DESC
     LIMIT 1;
  ELSE
    -- Pre-D.17 mapping + D.14/D.15 extensions (entity-by-entity).
    v_target_id := CASE v_event.event_type
      WHEN 'sanction.issued'             THEN NULLIF(v_event.payload->>'sanction_id','')::uuid
      WHEN 'member.state_changed'        THEN NULLIF(v_event.payload->>'membership_id','')::uuid
      WHEN 'money.pool_charge_created'   THEN NULLIF(v_event.payload->>'pool_charge_id','')::uuid
      WHEN 'decision.started_from_rule'  THEN NULLIF(v_event.payload->>'decision_id','')::uuid
      -- D.15 obligation paths (peer_obligation, create_pool_charge)
      WHEN 'money.obligation_created'    THEN NULLIF(v_event.payload->>'obligation_id','')::uuid
      WHEN 'obligation.created'          THEN NULLIF(v_event.payload->>'obligation_id','')::uuid
      -- D.14 resource lifecycle (archived/transferred/etc.)
      WHEN 'resource.archived'           THEN NULLIF(v_event.payload->>'resource_id','')::uuid
      WHEN 'resource.transferred'        THEN NULLIF(v_event.payload->>'resource_id','')::uuid
      WHEN 'resource.value_updated'      THEN NULLIF(v_event.payload->>'resource_id','')::uuid
      WHEN 'resource.assigned'           THEN NULLIF(v_event.payload->>'resource_id','')::uuid
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

    -- Find the evaluation that emitted this target_id.
    SELECT * INTO v_eval
      FROM public.group_rule_evaluations
     WHERE group_id = v_event.group_id
       AND actions_emitted @> jsonb_build_array(
             jsonb_build_object('target_id', v_target_id::text, 'status', 'emitted')
           )
     ORDER BY created_at DESC
     LIMIT 1;

    -- Pull consequence_kind / target_kind out of the matched action when
    -- present, for richer rendering on iOS.
    IF v_eval.id IS NOT NULL THEN
      SELECT
        a->>'kind',
        a->>'target_kind'
      INTO v_consequence_kind, v_target_kind
      FROM jsonb_array_elements(v_eval.actions_emitted) AS a
      WHERE NULLIF(a->>'target_id','')::uuid = v_target_id
        AND a->>'status' = 'emitted'
      LIMIT 1;
    END IF;
  END IF;

  IF v_eval.id IS NULL THEN
    RETURN jsonb_build_object(
      'found',  false,
      'reason', 'no_engine_origin',
      'event_type', v_event.event_type,
      'actor_user_id', v_event.actor_user_id
    );
  END IF;

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
  ) INTO v_source_event_summary
    FROM public.group_events se
   WHERE se.uuid_id = v_eval.source_event_id;

  RETURN jsonb_build_object(
    'found',             true,
    'evaluation_id',     v_eval.id,
    'rule_version_id',   v_eval.rule_version_id,
    'rule_title',        v_rule_title,
    'consequence_kind',  v_consequence_kind,
    'target_kind',       v_target_kind,
    'target_id',         v_target_id,
    'matched_predicate', v_eval.matched_predicate,
    'cycle_detected',    v_eval.cycle_detected,
    'depth',             v_eval.depth,
    'evaluated_at',      v_eval.created_at,
    'source_event',      v_source_event_summary
  );
END;
$function$;

COMMENT ON FUNCTION public.system_event_engine_provenance(uuid) IS
  'V3-D.17 — extended to cover D.14/D.15 events (obligations, resource lifecycle, rule.consequence.executed). Adds consequence_kind/target_kind/target_id to the envelope.';
