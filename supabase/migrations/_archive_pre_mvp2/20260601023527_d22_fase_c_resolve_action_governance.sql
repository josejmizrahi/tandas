-- D.22 FASE C — resolve_action_governance: pure read-only governance dispatcher.
-- Lee action_catalog + group settings + actor roles + permission catalog
-- Devuelve plan de acción. NO ejecuta nada.

CREATE OR REPLACE FUNCTION public.resolve_action_governance(
  p_group_id    uuid,
  p_action_key  text,
  p_target_kind text   DEFAULT NULL,
  p_target_id   uuid   DEFAULT NULL,
  p_payload     jsonb  DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid               uuid := auth.uid();
  v_action            public.action_catalog%ROWTYPE;
  v_group             public.groups%ROWTYPE;
  v_settings          jsonb;
  v_actor_mid         uuid;
  v_actor_status      text;
  v_actor_roles       jsonb := '[]'::jsonb;
  v_is_founder        boolean := false;
  v_is_admin          boolean := false;
  v_override          text;
  v_threshold_cfg     jsonb;
  v_threshold_amount  numeric;
  v_threshold_unit    text;
  v_payload_amount    numeric;
  v_requires_decision boolean;
  v_direct_execute    boolean := false;
  v_allowed           boolean := false;
  v_has_permission    boolean := false;
  v_missing_perm      text := NULL;
  v_reason            text;
  v_template_key      text;
  v_founder_emergency boolean;
  v_target_role_key   text;
BEGIN
  ---------------------------------------------------------------------
  -- 0. Auth & action lookup
  ---------------------------------------------------------------------
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object(
      'allowed', false, 'direct_execute', false, 'requires_decision', false,
      'reason', 'not_authenticated', 'action_key', p_action_key
    );
  END IF;

  SELECT * INTO v_action FROM public.action_catalog WHERE action_key = p_action_key;
  IF v_action.action_key IS NULL THEN
    RETURN jsonb_build_object(
      'allowed', false, 'direct_execute', false, 'requires_decision', false,
      'reason', 'action_unsupported', 'action_key', p_action_key
    );
  END IF;

  ---------------------------------------------------------------------
  -- 1. Self-only actions (identity/inbox/notification) bypass group context.
  ---------------------------------------------------------------------
  IF (v_action.metadata->>'self_only')::boolean = true THEN
    RETURN jsonb_build_object(
      'allowed', true, 'direct_execute', true, 'requires_decision', false,
      'reason', 'self_only_direct',
      'action_key', p_action_key,
      'executable_rpc', v_action.executable_rpc,
      'risk_level', v_action.risk_level
    );
  END IF;

  ---------------------------------------------------------------------
  -- 2. Group lookup
  ---------------------------------------------------------------------
  IF p_group_id IS NULL THEN
    RETURN jsonb_build_object(
      'allowed', false, 'direct_execute', false, 'requires_decision', false,
      'reason', 'group_required', 'action_key', p_action_key
    );
  END IF;

  SELECT * INTO v_group FROM public.groups WHERE id = p_group_id;
  IF v_group.id IS NULL THEN
    RETURN jsonb_build_object(
      'allowed', false, 'direct_execute', false, 'requires_decision', false,
      'reason', 'group_not_found', 'action_key', p_action_key
    );
  END IF;

  v_settings          := COALESCE(v_group.settings, '{}'::jsonb);
  v_founder_emergency := COALESCE((v_settings->>'founder_emergency_enabled')::boolean, true);

  ---------------------------------------------------------------------
  -- 3. Actor membership (prefer active row)
  ---------------------------------------------------------------------
  SELECT id, status INTO v_actor_mid, v_actor_status
    FROM public.group_memberships
   WHERE group_id = p_group_id AND user_id = v_uid
   ORDER BY (status = 'active') DESC, joined_at DESC NULLS LAST
   LIMIT 1;

  IF v_actor_mid IS NULL THEN
    RETURN jsonb_build_object(
      'allowed', false, 'direct_execute', false, 'requires_decision', false,
      'reason', 'not_a_member', 'action_key', p_action_key
    );
  END IF;

  IF v_actor_status <> 'active' THEN
    RETURN jsonb_build_object(
      'allowed', false, 'direct_execute', false, 'requires_decision', false,
      'reason', 'membership_inactive',
      'action_key', p_action_key,
      'actor_membership_id', v_actor_mid,
      'actor_status', v_actor_status
    );
  END IF;

  ---------------------------------------------------------------------
  -- 4. Actor roles (only system roles matter for tier checks)
  ---------------------------------------------------------------------
  SELECT COALESCE(jsonb_agg(gr.key ORDER BY gr.key), '[]'::jsonb)
    INTO v_actor_roles
    FROM public.group_member_roles gmr
    JOIN public.group_roles gr ON gr.id = gmr.role_id
   WHERE gmr.membership_id = v_actor_mid;

  v_is_founder := v_actor_roles ? 'founder';
  v_is_admin   := v_is_founder OR (v_actor_roles ? 'admin');

  ---------------------------------------------------------------------
  -- 5. Permission check (against canonical has_group_permission)
  ---------------------------------------------------------------------
  IF v_action.default_required_permission IS NOT NULL THEN
    SELECT public.has_group_permission(p_group_id, v_action.default_required_permission)
      INTO v_has_permission;
    IF NOT v_has_permission THEN
      v_missing_perm := v_action.default_required_permission;
    END IF;
  ELSE
    v_has_permission := true;
  END IF;

  ---------------------------------------------------------------------
  -- 6. Effective requires_decision = catalog default + group override
  --    + threshold + tier-aware role privilege.
  ---------------------------------------------------------------------
  v_override := v_settings->'action_overrides'->>p_action_key;
  IF v_override = 'requires_decision' THEN
    v_requires_decision := true;
  ELSIF v_override = 'direct' AND NOT v_action.is_constitutional THEN
    v_requires_decision := false;
  ELSE
    v_requires_decision := v_action.default_requires_decision;
  END IF;

  -- Threshold gating
  IF v_action.has_threshold THEN
    v_threshold_cfg    := v_settings->'action_thresholds'->p_action_key;
    v_threshold_amount := COALESCE(
      (v_threshold_cfg->>'amount')::numeric,
      v_action.default_threshold_amount
    );
    v_threshold_unit   := COALESCE(
      v_threshold_cfg->>'unit',
      v_action.default_threshold_unit
    );
    v_payload_amount   := NULLIF(p_payload->>'amount', '')::numeric;
    IF v_payload_amount IS NOT NULL AND v_payload_amount > v_threshold_amount THEN
      v_requires_decision := true;
    ELSIF v_payload_amount IS NULL AND v_threshold_amount = 0 THEN
      -- threshold=0 = always decide (e.g., money.payout)
      v_requires_decision := true;
    END IF;
  END IF;

  -- Tier-aware role.assign/revoke
  IF (v_action.metadata->>'tier_aware')::boolean = true THEN
    v_target_role_key := NULLIF(p_payload->>'target_role_key', '');
    IF v_target_role_key IS NOT NULL
       AND (v_action.metadata->'privileged_roles') ? v_target_role_key THEN
      v_requires_decision := true;
    END IF;
  END IF;

  ---------------------------------------------------------------------
  -- 7. Founder emergency override (only after perm + tree resolved).
  --    Cannot bypass constitutional actions.
  ---------------------------------------------------------------------
  IF v_requires_decision
     AND v_is_founder
     AND v_action.founder_can_override
     AND NOT v_action.is_constitutional
     AND v_founder_emergency
     AND v_has_permission THEN
    v_requires_decision := false;
    v_reason := 'founder_emergency_override';
  END IF;

  ---------------------------------------------------------------------
  -- 8. Final decision
  ---------------------------------------------------------------------
  IF v_requires_decision THEN
    v_template_key  := v_action.default_decision_template_key;
    v_allowed       := true;
    v_direct_execute := false;
    v_reason := COALESCE(v_reason, CASE
      WHEN v_action.is_constitutional THEN 'constitutional_action'
      WHEN v_override = 'requires_decision' THEN 'group_override_elevated'
      WHEN v_action.has_threshold
           AND ((v_payload_amount IS NOT NULL AND v_payload_amount > v_threshold_amount)
                OR (v_payload_amount IS NULL AND v_threshold_amount = 0)) THEN 'threshold_exceeded'
      WHEN (v_action.metadata->>'tier_aware')::boolean = true THEN 'tier_privileged_target'
      ELSE 'decision_required_by_default'
    END);
  ELSE
    IF NOT v_has_permission THEN
      RETURN jsonb_build_object(
        'allowed', false,
        'direct_execute', false,
        'requires_decision', false,
        'reason', 'missing_permission',
        'action_key', p_action_key,
        'missing_permission', v_missing_perm,
        'actor_membership_id', v_actor_mid,
        'actor_roles', v_actor_roles,
        'is_founder', v_is_founder,
        'is_admin', v_is_admin,
        'risk_level', v_action.risk_level
      );
    END IF;
    v_allowed       := true;
    v_direct_execute := true;
    v_reason := COALESCE(v_reason, 'direct_by_default');
  END IF;

  RETURN jsonb_build_object(
    'allowed', v_allowed,
    'direct_execute', v_direct_execute,
    'requires_decision', v_requires_decision,
    'decision_template_key', v_template_key,
    'reason', v_reason,
    'action_key', p_action_key,
    'executable_rpc', v_action.executable_rpc,
    'target_kind', COALESCE(p_target_kind, v_action.target_kind),
    'target_id', p_target_id,
    'actor_membership_id', v_actor_mid,
    'actor_roles', v_actor_roles,
    'is_founder', v_is_founder,
    'is_admin', v_is_admin,
    'missing_permission', v_missing_perm,
    'threshold_amount', v_threshold_amount,
    'threshold_unit', v_threshold_unit,
    'risk_level', v_action.risk_level,
    'is_constitutional', v_action.is_constitutional
  );
END;
$$;

COMMENT ON FUNCTION public.resolve_action_governance(uuid, text, text, uuid, jsonb) IS
  'D.22 FASE C — pure read-only governance resolver. Returns {allowed, direct_execute, requires_decision, decision_template_key, reason, missing_permission, actor_roles, ...}. No side effects.';

GRANT EXECUTE ON FUNCTION public.resolve_action_governance(uuid, text, text, uuid, jsonb) TO authenticated;
