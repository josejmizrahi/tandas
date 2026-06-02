-- D.22 FASE E — request_or_execute_action: canonical executor.
-- Single entry point for governable actions. Routes to:
--   - decision_opened   : auto-creates a decision via start_vote
--   - direct_allowed    : caller may proceed with the underlying RPC
--   - denied/unsupported: resolver said no
--   - failed            : template missing or unexpected
-- The actual side-effect for direct actions stays with the underlying RPC;
-- iOS first calls this, then (if direct_allowed) calls the RPC named in plan.executable_rpc.

CREATE OR REPLACE FUNCTION public.request_or_execute_action(
  p_group_id    uuid,
  p_action_key  text,
  p_target_kind text         DEFAULT NULL,
  p_target_id   uuid         DEFAULT NULL,
  p_payload     jsonb        DEFAULT '{}'::jsonb,
  p_title       text         DEFAULT NULL,
  p_body        text         DEFAULT NULL,
  p_closes_at   timestamptz  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_plan              jsonb;
  v_template          public.decision_templates_catalog%ROWTYPE;
  v_decision_id       uuid;
  v_decision_metadata jsonb;
  v_title             text;
  v_body              text;
BEGIN
  -- 1. Resolve governance plan.
  v_plan := public.resolve_action_governance(
    p_group_id, p_action_key, p_target_kind, p_target_id, p_payload
  );

  -- 2. Not allowed → bubble up the resolver's denial as-is.
  IF NOT COALESCE((v_plan->>'allowed')::boolean, false) THEN
    RETURN v_plan || jsonb_build_object('status', 'denied');
  END IF;

  -- 3. Direct path → caller may execute the underlying RPC.
  IF COALESCE((v_plan->>'direct_execute')::boolean, false) THEN
    RETURN v_plan || jsonb_build_object('status', 'direct_allowed');
  END IF;

  -- 4. Decision path → open via start_vote.
  IF COALESCE((v_plan->>'requires_decision')::boolean, false) THEN
    SELECT * INTO v_template
      FROM public.decision_templates_catalog
     WHERE template_key = v_plan->>'decision_template_key';

    IF v_template.template_key IS NULL THEN
      RETURN v_plan || jsonb_build_object(
        'status', 'failed',
        'error', 'template_not_found',
        'detail', v_plan->>'decision_template_key'
      );
    END IF;

    v_title := COALESCE(NULLIF(p_title, ''), v_template.display_name);
    v_body  := COALESCE(NULLIF(p_body, ''), v_template.description);

    v_decision_metadata := COALESCE(p_payload, '{}'::jsonb)
      || jsonb_build_object(
        'action_key',   p_action_key,
        'template_key', v_template.template_key,
        'target_kind',  COALESCE(p_target_kind, v_plan->>'target_kind')
      );

    BEGIN
      v_decision_id := public.start_vote(
        p_group_id          := p_group_id,
        p_title             := v_title,
        p_body              := v_body,
        p_decision_type     := v_template.decision_type,
        p_method            := v_template.default_method,
        p_legitimacy_source := v_template.default_legitimacy_source,
        p_opens_at          := now(),
        p_closes_at         := COALESCE(p_closes_at, now() + interval '7 days'),
        p_threshold_pct     := v_template.default_threshold_pct,
        p_quorum_pct        := v_template.default_quorum_pct,
        p_committee_only    := false,
        p_reference_kind    := v_template.reference_kind,
        p_reference_id      := p_target_id,
        p_options           := NULL,
        p_metadata          := v_decision_metadata
      );
    EXCEPTION WHEN OTHERS THEN
      RETURN v_plan || jsonb_build_object(
        'status', 'failed',
        'error', 'start_vote_failed',
        'sqlstate', SQLSTATE,
        'message', SQLERRM
      );
    END;

    RETURN v_plan || jsonb_build_object(
      'status',                'decision_opened',
      'decision_id',           v_decision_id,
      'decision_template_key', v_template.template_key,
      'decision_method',       v_template.default_method,
      'decision_threshold_pct', v_template.default_threshold_pct,
      'decision_quorum_pct',   v_template.default_quorum_pct
    );
  END IF;

  -- Fallback (shouldn't be reached if resolver is consistent).
  RETURN v_plan || jsonb_build_object('status', 'unsupported');
END;
$$;

COMMENT ON FUNCTION public.request_or_execute_action(uuid, text, text, uuid, jsonb, text, text, timestamptz) IS
  'D.22 FASE E — canonical executor. Resolves governance then opens a decision (decision path) or returns direct_allowed plan. iOS treats response as ActionOutcome enum: decisionOpened/executed (after RPC follow-up)/denied/unsupported/failed.';

GRANT EXECUTE ON FUNCTION public.request_or_execute_action(uuid, text, text, uuid, jsonb, text, text, timestamptz) TO authenticated;
