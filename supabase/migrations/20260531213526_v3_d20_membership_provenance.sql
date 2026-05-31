-- V3-D.20 FASE E — membership_provenance(membership_id)
-- "¿Por qué esta persona está en este estado?"
-- Paralelo a decision_provenance + system_event_engine_provenance.
-- Devuelve current_state + last_transition + actor + source decisión/regla.

CREATE OR REPLACE FUNCTION public.membership_provenance(
  p_membership_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid              uuid := auth.uid();
  v_m                public.group_memberships%ROWTYPE;
  v_last_evt         public.group_membership_events%ROWTYPE;
  v_state_event      public.group_events%ROWTYPE;
  v_creation_event   public.group_events%ROWTYPE;
  v_eval             public.group_rule_evaluations%ROWTYPE;
  v_rule_title       text;
  v_consequence_kind text;
  v_source_decision  jsonb;
  v_decision_id      uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  IF p_membership_id IS NULL THEN
    RAISE EXCEPTION 'p_membership_id is required' USING errcode = '22023';
  END IF;

  SELECT * INTO v_m FROM public.group_memberships WHERE id = p_membership_id;
  IF v_m.id IS NULL THEN
    RETURN jsonb_build_object('found', false, 'reason', 'membership_not_found');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = v_m.group_id AND gm.user_id = v_uid AND gm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', v_m.group_id
      USING errcode = '42501';
  END IF;

  -- Última transición desde el log dedicado
  SELECT * INTO v_last_evt
  FROM public.group_membership_events
  WHERE membership_id = p_membership_id
  ORDER BY created_at DESC, id DESC
  LIMIT 1;

  -- Último member.state_changed en el feed canónico (para hop a rule provenance)
  SELECT * INTO v_state_event
  FROM public.group_events
  WHERE group_id = v_m.group_id
    AND entity_id = p_membership_id
    AND event_type = 'member.state_changed'
  ORDER BY occurred_at DESC
  LIMIT 1;

  -- ¿Esta transición fue causada por una decisión (vía execute_decision)?
  -- decision.executed events llevan reference_kind=membership en su payload
  -- cuando el branch membership ejecutó. El target en ese caso es el
  -- decision.id, no la membership_id — buscamos por reference_id.
  SELECT id INTO v_decision_id
  FROM public.group_decisions
  WHERE group_id = v_m.group_id
    AND reference_kind = 'membership'
    AND reference_id   = p_membership_id
    AND status         = 'executed'
  ORDER BY executed_at DESC NULLS LAST, created_at DESC
  LIMIT 1;

  IF v_decision_id IS NOT NULL THEN
    SELECT jsonb_build_object(
      'decision_id', d.id,
      'title',       d.title,
      'outcome',     d.result->>'outcome',
      'executed_at', d.executed_at,
      'template_key', d.template_key
    ) INTO v_source_decision
    FROM public.group_decisions d
    WHERE d.id = v_decision_id;
  END IF;

  -- ¿Esta transición fue causada por una regla del engine?
  -- Look for a rule.consequence.executed event with target_id = membership_id
  SELECT * INTO v_creation_event
  FROM public.group_events
  WHERE group_id = v_m.group_id
    AND event_type = 'rule.consequence.executed'
    AND (payload->>'target_id')::uuid = p_membership_id
    AND (payload->>'target_kind') = 'membership'
  ORDER BY occurred_at DESC
  LIMIT 1;

  IF v_creation_event.id IS NOT NULL THEN
    v_consequence_kind := v_creation_event.payload->>'consequence_kind';
    SELECT * INTO v_eval
    FROM public.group_rule_evaluations
    WHERE group_id = v_m.group_id
      AND rule_version_id = (v_creation_event.payload->>'rule_version_id')::uuid
    ORDER BY created_at DESC
    LIMIT 1;
    IF v_eval.id IS NOT NULL THEN
      SELECT gr.title INTO v_rule_title
      FROM public.group_rule_versions grv
      JOIN public.group_rules gr ON gr.id = grv.rule_id
      WHERE grv.id = v_eval.rule_version_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'found',              true,
    'membership_id',      v_m.id,
    'group_id',           v_m.group_id,
    'user_id',            v_m.user_id,
    'current_state',      v_m.status,
    'membership_type',    v_m.membership_type,
    'current_reason',     COALESCE(
      v_m.suspended_reason,
      v_m.paused_reason,
      v_m.removed_reason,
      v_m.left_reason
    ),
    'joined_at',          v_m.joined_at,
    'confirmed_at',       v_m.confirmed_at,
    'paused_until',       v_m.paused_until,
    'suspended_until',    v_m.suspended_until,
    'left_at',            v_m.left_at,
    'removed_at',         v_m.removed_at,
    'unbanned_at',        v_m.unbanned_at,
    'last_transition',    CASE WHEN v_last_evt.id IS NULL THEN NULL ELSE
      jsonb_build_object(
        'event_type',    v_last_evt.event_type,
        'reason',        v_last_evt.reason,
        'actor_user_id', v_last_evt.actor_user_id,
        'at',            v_last_evt.created_at
      )
    END,
    'source_event',       CASE WHEN v_state_event.uuid_id IS NULL THEN NULL ELSE
      jsonb_build_object(
        'event_uuid',    v_state_event.uuid_id,
        'event_type',    v_state_event.event_type,
        'actor_user_id', v_state_event.actor_user_id,
        'occurred_at',   v_state_event.created_at,
        'summary',       v_state_event.summary,
        'payload',       v_state_event.payload
      )
    END,
    'source_decision',    v_source_decision,
    'source_rule_title',  v_rule_title,
    'source_consequence_kind', v_consequence_kind,
    'joined_via',         v_m.joined_via,
    'invited_by',         v_m.invited_by
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.membership_provenance(uuid) TO authenticated;

COMMENT ON FUNCTION public.membership_provenance(uuid) IS
  'V3-D.20 — "¿Por qué esta persona está en este estado?" Active-member gate. Source = manual|decision|rule.';
