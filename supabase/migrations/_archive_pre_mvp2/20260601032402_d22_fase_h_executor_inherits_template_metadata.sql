-- Fix: request_or_execute_action must merge the template's metadata
-- into the decision metadata. Without this, resource.archive opens a
-- decision but execute_decision's resource branch can't find
-- `metadata.action='archive'` (which is on the template, not on the
-- payload). Same for resource.transfer / resource.unarchive / etc.
-- Precedence: template.metadata < caller payload < canonical keys.

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
  v_plan := public.resolve_action_governance(
    p_group_id, p_action_key, p_target_kind, p_target_id, p_payload
  );

  IF NOT COALESCE((v_plan->>'allowed')::boolean, false) THEN
    RETURN v_plan || jsonb_build_object('status', 'denied');
  END IF;

  IF COALESCE((v_plan->>'direct_execute')::boolean, false) THEN
    RETURN v_plan || jsonb_build_object('status', 'direct_allowed');
  END IF;

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

    -- Precedence: template.metadata first (defaults like action='archive'),
    -- then caller payload (overrides, e.g., target_membership_id), then
    -- canonical keys (action_key, template_key, target_kind) on top so
    -- they cannot be shadowed.
    v_decision_metadata :=
      COALESCE(v_template.metadata, '{}'::jsonb)
      || COALESCE(p_payload, '{}'::jsonb)
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

  RETURN v_plan || jsonb_build_object('status', 'unsupported');
END;
$$;
