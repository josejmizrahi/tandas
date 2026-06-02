-- PARTE 12 — N.7 fix: spec §N.7.1 decía 'decision.started', código emite 'decision.proposed'.
-- Founder decisión 2026-05-29: código es source of truth; corregir spec.

CREATE OR REPLACE FUNCTION public._smoke_governance()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_group_id     uuid;
  v_invite_b_id  uuid;
  v_invite_b_code text;
  v_membership_a uuid;
  v_membership_b uuid;
  v_table_present int;
  v_no_delete_present int;
  v_partial_present int;
  v_versions_count_before int;
  v_versions_count_after  int;
  v_active_count int;
  v_closed_count int;
  v_version_id_1 uuid;
  v_version_id_2 uuid;
  v_event_payload jsonb;
  v_update_blocked boolean := false;
  v_delete_blocked boolean := false;
  v_decision_id  uuid;
  v_decision_status text;
  v_decision_proposed_events int;
  v_vote_1_id    uuid;
  v_vote_2_id    uuid;
  v_votes_count  int;
  v_current_vote public.group_votes%rowtype;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  -- 0a. Tabla group_governance_versions presente.
  SELECT count(*) INTO v_table_present
  FROM information_schema.tables
  WHERE table_schema='public' AND table_name='group_governance_versions';
  step := '0a.governance_versions_table_present'; ok := v_table_present = 1;
  detail := 'count=' || v_table_present; RETURN NEXT;

  -- 0b. Atom guards: no_delete + partial_guard.
  SELECT count(*) FILTER (WHERE p.proname='atom_no_delete_guard'),
         count(*) FILTER (WHERE p.proname='_group_governance_versions_partial_guard')
    INTO v_no_delete_present, v_partial_present
  FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
  WHERE t.tgrelid='public.group_governance_versions'::regclass AND NOT t.tgisinternal;
  step := '0b.governance_versions_atom_guards'; ok := v_no_delete_present >= 1 AND v_partial_present >= 1;
  detail := 'no_delete=' || v_no_delete_present || ' partial=' || v_partial_present; RETURN NEXT;

  -- Setup
  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke Gov A'), (v_user_b, 'Smoke Gov B')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_id := public.create_group('Smoke Gov ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');

  SELECT gm.id INTO v_membership_a FROM public.group_memberships gm
   WHERE gm.group_id = v_group_id AND gm.user_id = v_user_a;

  SELECT im.invite_id, im.code INTO v_invite_b_id, v_invite_b_code
    FROM public.invite_member(v_group_id, 'smoke-gov-b@test', NULL, 'member', NULL) im;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  PERFORM public.accept_invite(v_invite_b_code);

  SELECT gm.id INTO v_membership_b FROM public.group_memberships gm
   WHERE gm.group_id = v_group_id AND gm.user_id = v_user_b;

  -- =============== PARTE 7 versioning ===============
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);

  SELECT count(*) INTO v_versions_count_before FROM public.group_governance_versions
   WHERE group_id = v_group_id;

  PERFORM public.set_decision_rules(v_group_id, 'majority', 2, 'Smoke gov v1', 'majority', 'majority');

  SELECT count(*) INTO v_versions_count_after FROM public.group_governance_versions
   WHERE group_id = v_group_id;
  SELECT count(*) INTO v_active_count FROM public.group_governance_versions
   WHERE group_id = v_group_id AND effective_until IS NULL;
  step := 'PARTE7a.set_decision_rules_creates_version'; ok := (v_versions_count_after - v_versions_count_before) >= 1 AND v_active_count = 1;
  detail := 'delta=' || (v_versions_count_after - v_versions_count_before) || ' active=' || v_active_count; RETURN NEXT;

  SELECT id INTO v_version_id_1 FROM public.group_governance_versions
   WHERE group_id = v_group_id AND effective_until IS NULL;

  PERFORM public.set_decision_rules(v_group_id, 'supermajority', 2, 'Smoke gov v2', 'supermajority', 'supermajority');

  SELECT count(*) INTO v_active_count FROM public.group_governance_versions
   WHERE group_id = v_group_id AND effective_until IS NULL;
  SELECT count(*) INTO v_closed_count FROM public.group_governance_versions
   WHERE group_id = v_group_id AND id = v_version_id_1 AND effective_until IS NOT NULL;
  step := 'PARTE7b.second_set_closes_previous'; ok := v_active_count = 1 AND v_closed_count = 1;
  detail := 'active_now=' || v_active_count || ' previous_closed=' || v_closed_count; RETURN NEXT;

  SELECT id INTO v_version_id_2 FROM public.group_governance_versions
   WHERE group_id = v_group_id AND effective_until IS NULL;

  SELECT ge.payload INTO v_event_payload FROM public.group_events ge
   WHERE ge.group_id = v_group_id AND ge.event_type = 'decision_rules.set'
   ORDER BY ge.created_at DESC, ge.id DESC LIMIT 1;
  step := 'PARTE7c.event_carries_version_id'; ok := (v_event_payload->>'version_id') = v_version_id_2::text;
  detail := 'payload_version_id=' || COALESCE(v_event_payload->>'version_id', 'NULL'); RETURN NEXT;

  BEGIN
    UPDATE public.group_governance_versions
       SET snapshot = jsonb_build_object('tampered', true)
     WHERE id = v_version_id_2;
  EXCEPTION WHEN OTHERS THEN
    v_update_blocked := true;
  END;
  step := 'PARTE7d.update_snapshot_blocked'; ok := v_update_blocked;
  detail := 'blocked=' || v_update_blocked::text; RETURN NEXT;

  BEGIN
    DELETE FROM public.group_governance_versions WHERE id = v_version_id_2;
  EXCEPTION WHEN OTHERS THEN
    v_delete_blocked := true;
  END;
  step := 'PARTE7e.delete_blocked'; ok := v_delete_blocked;
  detail := 'blocked=' || v_delete_blocked::text; RETURN NEXT;

  -- =============== Voting lifecycle ===============
  v_decision_id := public.start_vote(
    v_group_id, 'Smoke decision 1', 'body', 'free_form', 'majority', 'majority',
    NULL, now() + interval '1 hour', NULL, NULL, false, NULL, NULL,
    '[]'::jsonb, '{}'::jsonb
  );

  SELECT status INTO v_decision_status FROM public.group_decisions WHERE id = v_decision_id;
  SELECT count(*) INTO v_decision_proposed_events FROM public.group_events
   WHERE group_id = v_group_id AND event_type = 'decision.proposed' AND entity_id = v_decision_id;
  step := 'N.7.1.start_vote_creates_open_decision'; ok := v_decision_status = 'open' AND v_decision_proposed_events >= 1;
  detail := 'status=' || v_decision_status || ' decision_proposed_events=' || v_decision_proposed_events; RETURN NEXT;

  v_vote_1_id := public.cast_vote(v_decision_id, NULL, 'yes', 'first');
  v_vote_2_id := public.cast_vote(v_decision_id, NULL, 'no', 'changed_mind');

  SELECT count(*) INTO v_votes_count FROM public.group_votes
   WHERE decision_id = v_decision_id AND voter_membership_id = v_membership_a;
  SELECT * INTO v_current_vote FROM public.current_vote_for(v_decision_id, v_membership_a);
  step := 'N.7.2.cast_vote_twice_current_returns_latest';
  ok := v_votes_count = 2 AND v_current_vote.id = v_vote_2_id AND v_current_vote.vote_value = 'no';
  detail := 'rows=' || v_votes_count || ' current_id=' || COALESCE(v_current_vote.id::text, 'NULL') || ' value=' || COALESCE(v_current_vote.vote_value, 'NULL'); RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_governance() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_governance() TO service_role;
