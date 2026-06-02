-- group_votes es append-only (atom_no_delete_guard). Multiple votos
-- del mismo membership son aceptados; el tally usa el más reciente
-- (lógica que ya existía antes de M1).

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
   WHERE group_id = v_decision.group_id AND user_id = v_uid AND status='active' LIMIT 1;
  IF v_membership_id IS NULL THEN
    RAISE EXCEPTION 'voter is not an active member of group %', v_decision.group_id USING errcode = '42501';
  END IF;

  v_value := COALESCE(NULLIF(btrim(p_vote_value), ''), 'yes');
  IF v_value NOT IN ('yes','no','abstain','block') THEN
    RAISE EXCEPTION 'invalid vote value: %', v_value USING errcode = '22023';
  END IF;

  -- Append-only: nuevo INSERT por cada voto. El tally agrega el más
  -- reciente por miembro vía las tally functions.
  INSERT INTO public.group_votes (
    group_id, decision_id, voter_membership_id, option_id, vote_value, reason, weight
  ) VALUES (
    v_decision.group_id, p_decision_id, v_membership_id, p_option_id, v_value,
    NULLIF(btrim(COALESCE(p_reason,'')), ''), p_weight
  )
  RETURNING id INTO v_vote_id;

  PERFORM public.record_system_event(
    v_decision.group_id, 'decision.voted', 'decision', p_decision_id,
    'Voto registrado',
    jsonb_build_object('value', v_value, 'option_id', p_option_id, 'weight', p_weight)
  );

  BEGIN
    PERFORM public._check_auto_finalize(p_decision_id);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN v_vote_id;
END;
$function$;

-- _check_auto_finalize: counter "latest vote per member" en lugar de
-- todos los rows (append-only puede tener múltiples votos por miembro
-- si cambiaron). DISTINCT ON (voter_membership_id) ORDER BY cast_at DESC.
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
  v_yes_count      integer;
  v_active_members integer;
  v_quorum_ok      boolean := false;
  v_yes_ratio      numeric;
  v_threshold      numeric;
  v_quorum_pct     numeric;
  v_quorum_count   integer;
BEGIN
  SELECT * INTO v_d FROM public.group_decisions WHERE id = p_decision_id;
  IF v_d.id IS NULL OR v_d.status <> 'open' THEN RETURN false; END IF;
  IF v_d.method NOT IN ('majority', 'supermajority') THEN RETURN false; END IF;

  SELECT decision_rules INTO v_rules FROM public.groups WHERE id = v_d.group_id;
  v_rules := COALESCE(v_rules, '{}'::jsonb);
  v_auto_close := COALESCE((v_rules->>'auto_close_on_threshold')::boolean, false);
  IF NOT v_auto_close THEN RETURN false; END IF;

  -- Latest vote per membership (append-only design).
  WITH latest_votes AS (
    SELECT DISTINCT ON (voter_membership_id)
      voter_membership_id, vote_value
    FROM public.group_votes
    WHERE decision_id = p_decision_id
    ORDER BY voter_membership_id, cast_at DESC, created_at DESC
  )
  SELECT
    COUNT(*) FILTER (WHERE vote_value IN ('yes','no','abstain')),
    COUNT(*) FILTER (WHERE vote_value IN ('yes','no')),
    COUNT(*) FILTER (WHERE vote_value = 'yes')
  INTO v_total, v_decided, v_yes_count
  FROM latest_votes;

  v_total := COALESCE(v_total, 0);
  v_decided := COALESCE(v_decided, 0);
  v_yes_count := COALESCE(v_yes_count, 0);
  IF v_decided = 0 THEN RETURN false; END IF;
  v_yes_ratio := v_yes_count::numeric / v_decided::numeric;

  v_threshold := COALESCE(
    v_d.threshold_pct,
    CASE v_d.method WHEN 'majority' THEN 50.01 WHEN 'supermajority' THEN 66.66 END
  );

  SELECT COUNT(*) INTO v_active_members FROM public.group_memberships
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

  IF (v_yes_ratio * 100) >= v_threshold THEN
    UPDATE public.group_decisions
       SET status = 'passed', decided_at = now(),
           result = jsonb_build_object(
             'outcome', 'passed', 'via', 'auto_close_on_threshold',
             'yes_ratio_at_close', v_yes_ratio, 'quorum_ok', v_quorum_ok,
             'threshold_pct', v_threshold, 'total_votes', v_total,
             'yes_count', v_yes_count
           )
     WHERE id = p_decision_id;

    PERFORM public.record_system_event(
      v_d.group_id, 'decision.passed', 'decision', p_decision_id,
      'Decisión pasó (auto-close)',
      jsonb_build_object('method', v_d.method, 'threshold_pct', v_threshold,
        'yes_ratio', v_yes_ratio, 'yes_count', v_yes_count, 'total_votes', v_total,
        'via', 'auto_close_on_threshold')
    );
    RETURN true;
  END IF;
  RETURN false;
END;
$function$;
