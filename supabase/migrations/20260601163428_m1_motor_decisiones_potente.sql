-- M1 — Motor de decisiones potente.
CREATE OR REPLACE FUNCTION public.set_decision_rules(
  p_group_id uuid,
  p_default_style text,
  p_quorum_min integer DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_default_method text DEFAULT NULL,
  p_default_legitimacy_source text DEFAULT NULL,
  p_default_threshold_pct numeric DEFAULT NULL,
  p_default_quorum_pct numeric DEFAULT NULL,
  p_default_duration_hours integer DEFAULT NULL,
  p_auto_close_on_threshold boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid        uuid := auth.uid();
  v_style      text;
  v_method     text;
  v_legitimacy text;
  v_notes      text;
  v_rules      jsonb;
  v_version_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  v_method := COALESCE(NULLIF(btrim(p_default_method), ''), NULL);
  IF v_method IS NULL THEN
    v_style := COALESCE(NULLIF(btrim(p_default_style), ''), '');
    v_method := CASE v_style
      WHEN 'admin_only'    THEN 'admin'
      WHEN 'majority'      THEN 'majority'
      WHEN 'supermajority' THEN 'supermajority'
      WHEN 'unanimity'     THEN 'consensus'
      WHEN 'consensus'     THEN 'consent'
      ELSE ''
    END;
  END IF;
  IF v_method NOT IN (
    'admin', 'majority', 'supermajority', 'consensus', 'consent',
    'ranked_choice', 'weighted', 'veto'
  ) THEN
    RAISE EXCEPTION 'invalid decision method: %', v_method USING errcode = '22023';
  END IF;

  v_style := CASE v_method
    WHEN 'admin'         THEN 'admin_only'
    WHEN 'majority'      THEN 'majority'
    WHEN 'supermajority' THEN 'supermajority'
    WHEN 'consensus'     THEN 'unanimity'
    WHEN 'consent'       THEN 'consensus'
    WHEN 'ranked_choice' THEN 'majority'
    WHEN 'weighted'      THEN 'majority'
    WHEN 'veto'          THEN 'consensus'
  END;

  v_legitimacy := COALESCE(NULLIF(btrim(p_default_legitimacy_source), ''), NULL);
  IF v_legitimacy IS NULL THEN
    v_legitimacy := CASE v_method
      WHEN 'admin'         THEN 'founder'
      WHEN 'majority'      THEN 'majority'
      WHEN 'supermajority' THEN 'supermajority'
      WHEN 'consensus'     THEN 'unanimity'
      WHEN 'consent'       THEN 'committee'
      WHEN 'ranked_choice' THEN 'election'
      WHEN 'weighted'      THEN 'expert'
      WHEN 'veto'          THEN 'committee'
    END;
  END IF;
  IF v_legitimacy NOT IN (
    'founder', 'election', 'majority', 'supermajority', 'committee',
    'unanimity', 'expert', 'external_contract', 'tradition', 'emergency'
  ) THEN
    RAISE EXCEPTION 'invalid legitimacy source: %', v_legitimacy USING errcode = '22023';
  END IF;

  IF p_quorum_min IS NOT NULL AND p_quorum_min < 1 THEN
    RAISE EXCEPTION 'quorum_min must be >= 1' USING errcode = '22023';
  END IF;
  IF p_default_threshold_pct IS NOT NULL
     AND (p_default_threshold_pct < 0 OR p_default_threshold_pct > 100) THEN
    RAISE EXCEPTION 'default_threshold_pct must be between 0 and 100' USING errcode = '22023';
  END IF;
  IF p_default_quorum_pct IS NOT NULL
     AND (p_default_quorum_pct < 0 OR p_default_quorum_pct > 100) THEN
    RAISE EXCEPTION 'default_quorum_pct must be between 0 and 100' USING errcode = '22023';
  END IF;
  IF p_default_duration_hours IS NOT NULL
     AND (p_default_duration_hours < 1 OR p_default_duration_hours > 24*90) THEN
    RAISE EXCEPTION 'default_duration_hours must be between 1 and 2160' USING errcode = '22023';
  END IF;

  v_notes := NULLIF(btrim(COALESCE(p_notes, '')), '');

  PERFORM public.assert_permission(p_group_id, 'group.update');

  v_rules := jsonb_strip_nulls(jsonb_build_object(
    'default_style',             v_style,
    'default_method',            v_method,
    'default_legitimacy_source', v_legitimacy,
    'quorum_min',                p_quorum_min,
    'notes',                     v_notes,
    'default_threshold_pct',     p_default_threshold_pct,
    'default_quorum_pct',        p_default_quorum_pct,
    'default_duration_hours',    p_default_duration_hours,
    'auto_close_on_threshold',   p_auto_close_on_threshold
  ));

  UPDATE public.groups
     SET decision_rules = v_rules,
         updated_at     = now()
   WHERE id = p_group_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'group not found: %', p_group_id USING errcode = 'P0002';
  END IF;

  UPDATE public.group_governance_versions
     SET effective_until = now()
   WHERE group_id = p_group_id AND effective_until IS NULL;

  INSERT INTO public.group_governance_versions (group_id, snapshot, set_by, source_decision_id)
  VALUES (p_group_id, v_rules, v_uid, NULL)
  RETURNING id INTO v_version_id;

  PERFORM public.record_system_event(
    p_group_id, 'decision_rules.set', 'group', p_group_id,
    'Reglas de decisión actualizadas',
    jsonb_build_object(
      'default_style',             v_style,
      'default_method',            v_method,
      'default_legitimacy_source', v_legitimacy,
      'quorum_min',                p_quorum_min,
      'has_notes',                 v_notes IS NOT NULL,
      'default_threshold_pct',     p_default_threshold_pct,
      'default_quorum_pct',        p_default_quorum_pct,
      'default_duration_hours',    p_default_duration_hours,
      'auto_close_on_threshold',   p_auto_close_on_threshold,
      'version_id',                v_version_id
    )
  );

  RETURN jsonb_build_object(
    'group_id',                  p_group_id,
    'default_style',             v_style,
    'default_method',            v_method,
    'default_legitimacy_source', v_legitimacy,
    'quorum_min',                p_quorum_min,
    'notes',                     v_notes,
    'default_threshold_pct',     p_default_threshold_pct,
    'default_quorum_pct',        p_default_quorum_pct,
    'default_duration_hours',    p_default_duration_hours,
    'auto_close_on_threshold',   p_auto_close_on_threshold,
    'version_id',                v_version_id,
    'is_default',                false
  );
END;
$function$;

-- start_vote: usar group defaults
CREATE OR REPLACE FUNCTION public.start_vote(
  p_group_id uuid,
  p_title text,
  p_body text,
  p_decision_type text,
  p_method text,
  p_legitimacy_source text DEFAULT 'majority'::text,
  p_opens_at timestamptz DEFAULT NULL,
  p_closes_at timestamptz DEFAULT NULL,
  p_threshold_pct numeric DEFAULT NULL,
  p_quorum_pct numeric DEFAULT NULL,
  p_committee_only boolean DEFAULT false,
  p_reference_kind text DEFAULT NULL,
  p_reference_id uuid DEFAULT NULL,
  p_options jsonb DEFAULT NULL,
  p_metadata jsonb DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid       uuid := auth.uid();
  v_decision_id uuid;
  v_option    jsonb;
  v_sort      integer := 0;
  v_rules     jsonb;
  v_duration_hours integer;
  v_threshold numeric;
  v_quorum    numeric;
  v_closes_at timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  PERFORM public.assert_permission(p_group_id, 'decisions.create');

  SELECT decision_rules INTO v_rules FROM public.groups WHERE id = p_group_id;
  v_rules := COALESCE(v_rules, '{}'::jsonb);

  v_duration_hours := COALESCE((v_rules->>'default_duration_hours')::integer, 168);
  v_closes_at := COALESCE(
    p_closes_at,
    COALESCE(p_opens_at, now()) + (v_duration_hours || ' hours')::interval
  );
  v_threshold := COALESCE(p_threshold_pct, (v_rules->>'default_threshold_pct')::numeric);
  v_quorum := COALESCE(p_quorum_pct, (v_rules->>'default_quorum_pct')::numeric);

  INSERT INTO public.group_decisions (
    group_id, title, body, decision_type, method, legitimacy_source,
    status, opens_at, closes_at, threshold_pct, quorum_pct,
    committee_only, reference_kind, reference_id, metadata, created_by
  ) VALUES (
    p_group_id, p_title, p_body, p_decision_type, p_method, p_legitimacy_source,
    'open', p_opens_at, v_closes_at, v_threshold, v_quorum,
    COALESCE(p_committee_only, false), p_reference_kind, p_reference_id,
    COALESCE(p_metadata, '{}'::jsonb), v_uid
  )
  RETURNING id INTO v_decision_id;

  IF p_options IS NOT NULL AND jsonb_typeof(p_options) = 'array' THEN
    FOR v_option IN SELECT * FROM jsonb_array_elements(p_options)
    LOOP
      INSERT INTO public.group_decision_options (decision_id, label, body, sort_order)
      VALUES (v_decision_id, COALESCE(v_option->>'label',''), v_option->>'body', v_sort);
      v_sort := v_sort + 1;
    END LOOP;
  END IF;

  PERFORM public.record_system_event(
    p_group_id, 'decision.proposed', 'decision', v_decision_id, p_title,
    jsonb_build_object(
      'decision_type', p_decision_type,
      'method', p_method,
      'reference_kind', p_reference_kind,
      'closes_at', v_closes_at,
      'threshold_pct', v_threshold,
      'quorum_pct', v_quorum
    )
  );
  RETURN v_decision_id;
END;
$function$;

-- _check_auto_finalize helper
CREATE OR REPLACE FUNCTION public._check_auto_finalize(p_decision_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_d              public.group_decisions%ROWTYPE;
  v_rules          jsonb;
  v_auto_close     boolean;
  v_total          integer;
  v_decided        integer;
  v_active_members integer;
  v_quorum_ok      boolean := false;
  v_yes_ratio      numeric;
  v_threshold      numeric;
  v_quorum_pct     numeric;
  v_quorum_count   integer;
BEGIN
  SELECT * INTO v_d FROM public.group_decisions WHERE id = p_decision_id;
  IF v_d.id IS NULL OR v_d.status <> 'open' THEN
    RETURN false;
  END IF;
  IF v_d.method NOT IN ('majority', 'supermajority') THEN
    RETURN false;
  END IF;

  SELECT decision_rules INTO v_rules FROM public.groups WHERE id = v_d.group_id;
  v_rules := COALESCE(v_rules, '{}'::jsonb);
  v_auto_close := COALESCE((v_rules->>'auto_close_on_threshold')::boolean, false);
  IF NOT v_auto_close THEN
    RETURN false;
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE gv.value IN ('yes','no','abstain')),
    COUNT(*) FILTER (WHERE gv.value IN ('yes','no')),
    SUM(CASE WHEN gv.value='yes' THEN 1 ELSE 0 END)::numeric
      / NULLIF(SUM(CASE WHEN gv.value IN ('yes','no') THEN 1 ELSE 0 END), 0)
  INTO v_total, v_decided, v_yes_ratio
  FROM public.group_votes gv
  WHERE gv.decision_id = p_decision_id;

  v_total := COALESCE(v_total, 0);
  v_decided := COALESCE(v_decided, 0);
  IF v_decided = 0 THEN RETURN false; END IF;

  v_threshold := COALESCE(
    v_d.threshold_pct,
    CASE v_d.method WHEN 'majority' THEN 50.01 WHEN 'supermajority' THEN 66.66 END
  );

  SELECT COUNT(*) INTO v_active_members
  FROM public.group_memberships
  WHERE group_id = v_d.group_id AND status='active';

  v_quorum_pct := COALESCE(v_d.quorum_pct, (v_rules->>'default_quorum_pct')::numeric);

  IF v_quorum_pct IS NOT NULL AND v_active_members > 0 THEN
    v_quorum_ok := (v_total::numeric / v_active_members::numeric) * 100 >= v_quorum_pct;
  ELSE
    v_quorum_count := (v_rules->>'quorum_min')::integer;
    IF v_quorum_count IS NOT NULL THEN
      v_quorum_ok := v_total >= v_quorum_count;
    ELSE
      v_quorum_ok := true;
    END IF;
  END IF;

  IF NOT v_quorum_ok THEN RETURN false; END IF;

  IF v_yes_ratio IS NOT NULL AND (v_yes_ratio * 100) >= v_threshold THEN
    UPDATE public.group_decisions
       SET status = 'passed',
           decided_at = now(),
           result = jsonb_build_object(
             'outcome', 'passed',
             'via', 'auto_close_on_threshold',
             'yes_ratio_at_close', v_yes_ratio,
             'quorum_ok', v_quorum_ok,
             'threshold_pct', v_threshold,
             'total_votes', v_total
           )
     WHERE id = p_decision_id;

    PERFORM public.record_system_event(
      v_d.group_id, 'decision.passed', 'decision', p_decision_id,
      'Decisión pasó (auto-close)',
      jsonb_build_object(
        'method', v_d.method,
        'threshold_pct', v_threshold,
        'yes_ratio', v_yes_ratio,
        'total_votes', v_total,
        'via', 'auto_close_on_threshold'
      )
    );
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public._check_auto_finalize(uuid) FROM PUBLIC;

-- cast_vote: invoca auto-finalize después de insertar.
CREATE OR REPLACE FUNCTION public.cast_vote(
  p_decision_id uuid,
  p_option_id uuid DEFAULT NULL,
  p_vote_value text DEFAULT NULL,
  p_reason text DEFAULT NULL,
  p_weight numeric DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid           uuid := auth.uid();
  v_decision      public.group_decisions%ROWTYPE;
  v_membership_id uuid;
  v_value         text;
  v_vote_id       uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_decision FROM public.group_decisions WHERE id = p_decision_id;
  IF v_decision.id IS NULL THEN
    RAISE EXCEPTION 'decision % not found', p_decision_id USING errcode = 'P0002';
  END IF;
  IF v_decision.status <> 'open' THEN
    RAISE EXCEPTION 'decision % is not open (status=%)', p_decision_id, v_decision.status
      USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_decision.group_id, 'decisions.vote');

  SELECT id INTO v_membership_id FROM public.group_memberships
   WHERE group_id = v_decision.group_id AND user_id = v_uid AND status='active'
   LIMIT 1;
  IF v_membership_id IS NULL THEN
    RAISE EXCEPTION 'voter is not an active member of group %', v_decision.group_id USING errcode = '42501';
  END IF;

  v_value := COALESCE(NULLIF(btrim(p_vote_value), ''), 'yes');
  IF v_value NOT IN ('yes','no','abstain','block') THEN
    RAISE EXCEPTION 'invalid vote value: %', v_value USING errcode = '22023';
  END IF;

  INSERT INTO public.group_votes (
    decision_id, voter_membership_id, option_id, value, reason, weight
  ) VALUES (
    p_decision_id, v_membership_id, p_option_id, v_value,
    NULLIF(btrim(COALESCE(p_reason,'')), ''), p_weight
  )
  ON CONFLICT (decision_id, voter_membership_id)
  DO UPDATE SET
    option_id  = EXCLUDED.option_id,
    value      = EXCLUDED.value,
    reason     = EXCLUDED.reason,
    weight     = EXCLUDED.weight,
    updated_at = now()
  RETURNING id INTO v_vote_id;

  PERFORM public.record_system_event(
    v_decision.group_id, 'decision.voted', 'decision', p_decision_id,
    'Voto registrado',
    jsonb_build_object('value', v_value, 'option_id', p_option_id, 'weight', p_weight)
  );

  -- M1: auto-close on threshold (best-effort).
  BEGIN
    PERFORM public._check_auto_finalize(p_decision_id);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN v_vote_id;
END;
$function$;
