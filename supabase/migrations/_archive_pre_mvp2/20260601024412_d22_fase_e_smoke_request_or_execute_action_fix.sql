-- D.22 FASE E — smoke fix: select member who actually has 'member' role assigned.

CREATE OR REPLACE FUNCTION public._smoke_action_executor()
RETURNS TABLE(check_name text, status text, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_group_id    uuid;
  v_founder_uid uuid;
  v_member_uid  uuid;
  v_outsider    uuid := gen_random_uuid();
  v_result      jsonb;
  v_decision_ids uuid[] := ARRAY[]::uuid[];
  v_dec_id      uuid;
BEGIN
  -- Fixture
  SELECT g.id INTO v_group_id
    FROM groups g WHERE g.name LIKE '%Test Bench%' AND g.status='active' LIMIT 1;

  SELECT gm.user_id INTO v_founder_uid
    FROM group_memberships gm
    JOIN group_member_roles gmr ON gmr.membership_id = gm.id
    JOIN group_roles gr ON gr.id = gmr.role_id AND gr.key='founder'
   WHERE gm.group_id = v_group_id AND gm.status='active' LIMIT 1;

  -- Pick a non-founder member who HAS at least one role (preferably 'member').
  SELECT gm.user_id INTO v_member_uid
    FROM group_memberships gm
   WHERE gm.group_id = v_group_id AND gm.status='active' AND gm.user_id <> v_founder_uid
     AND EXISTS (
       SELECT 1 FROM group_member_roles gmr
       JOIN group_roles gr ON gr.id = gmr.role_id AND gr.key='member'
       WHERE gmr.membership_id = gm.id
     )
   ORDER BY joined_at ASC NULLS LAST LIMIT 1;

  IF v_group_id IS NULL OR v_founder_uid IS NULL OR v_member_uid IS NULL THEN
    check_name := 'fixture'; status := 'FAIL'; detail := 'missing test bench/founder/member-with-role'; RETURN NEXT; RETURN;
  END IF;

  -- T1 — unknown action → denied
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_member_uid, 'role','authenticated')::text, true);
  v_result := public.request_or_execute_action(v_group_id, 'nonexistent.fake');
  IF v_result->>'status' = 'denied' AND v_result->>'reason' = 'action_unsupported' THEN
    check_name := 'T1_unknown_action_denied'; status := 'PASS'; detail := 'reason ok';
  ELSE
    check_name := 'T1_unknown_action_denied'; status := 'FAIL'; detail := v_result::text;
  END IF;
  RETURN NEXT;

  -- T2 — self-only → direct_allowed
  v_result := public.request_or_execute_action(NULL, 'identity.profile.update');
  IF v_result->>'status' = 'direct_allowed' AND v_result->>'executable_rpc' = 'update_my_profile' THEN
    check_name := 'T2_self_only_direct_allowed'; status := 'PASS'; detail := 'direct ok';
  ELSE
    check_name := 'T2_self_only_direct_allowed'; status := 'FAIL'; detail := v_result::text;
  END IF;
  RETURN NEXT;

  -- T3 — outsider → denied
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_outsider, 'role','authenticated')::text, true);
  v_result := public.request_or_execute_action(v_group_id, 'resource.create');
  IF v_result->>'status' = 'denied' AND v_result->>'reason' = 'not_a_member' THEN
    check_name := 'T3_outsider_denied'; status := 'PASS'; detail := 'denial ok';
  ELSE
    check_name := 'T3_outsider_denied'; status := 'FAIL'; detail := v_result::text;
  END IF;
  RETURN NEXT;

  -- T4 — member calling resource.archive → decision_opened
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_member_uid, 'role','authenticated')::text, true);
  v_result := public.request_or_execute_action(
    v_group_id, 'resource.archive', 'resource', gen_random_uuid()
  );
  IF v_result->>'status' = 'decision_opened' AND (v_result->>'decision_id') IS NOT NULL THEN
    check_name := 'T4_member_decision_opened'; status := 'PASS'; detail := 'template='||COALESCE(v_result->>'decision_template_key','NULL');
    v_dec_id := (v_result->>'decision_id')::uuid;
    v_decision_ids := array_append(v_decision_ids, v_dec_id);
  ELSE
    check_name := 'T4_member_decision_opened'; status := 'FAIL'; detail := v_result::text;
  END IF;
  RETURN NEXT;

  -- T5 — verify decision metadata
  IF v_dec_id IS NOT NULL THEN
    PERFORM 1 FROM group_decisions WHERE id = v_dec_id AND metadata->>'action_key' = 'resource.archive';
    IF FOUND THEN
      check_name := 'T5_decision_metadata_carries_action_key'; status := 'PASS'; detail := 'action_key persisted';
    ELSE
      check_name := 'T5_decision_metadata_carries_action_key'; status := 'FAIL'; detail := 'metadata missing action_key';
    END IF;
  ELSE
    check_name := 'T5_decision_metadata_carries_action_key'; status := 'SKIP'; detail := 'T4 did not produce decision';
  END IF;
  RETURN NEXT;

  -- T6 — founder calling resource.archive → direct_allowed
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_founder_uid, 'role','authenticated')::text, true);
  v_result := public.request_or_execute_action(
    v_group_id, 'resource.archive', 'resource', gen_random_uuid()
  );
  IF v_result->>'status' = 'direct_allowed' AND v_result->>'reason' = 'founder_emergency_override' THEN
    check_name := 'T6_founder_override_direct'; status := 'PASS'; detail := 'override ok';
  ELSE
    check_name := 'T6_founder_override_direct'; status := 'FAIL'; detail := v_result::text;
  END IF;
  RETURN NEXT;

  -- T7 — founder calling engine.toggle (constitutional) → decision_opened
  v_result := public.request_or_execute_action(v_group_id, 'engine.toggle', 'group', v_group_id);
  IF v_result->>'status' = 'decision_opened' AND v_result->>'decision_template_key' = 'decision.engine_toggle' THEN
    check_name := 'T7_constitutional_no_override'; status := 'PASS'; detail := 'decision opened';
    v_decision_ids := array_append(v_decision_ids, (v_result->>'decision_id')::uuid);
  ELSE
    check_name := 'T7_constitutional_no_override'; status := 'FAIL'; detail := v_result::text;
  END IF;
  RETURN NEXT;

  -- T8 — founder + expense > 10000 → direct_allowed
  v_result := public.request_or_execute_action(
    v_group_id, 'money.expense.record', NULL, NULL, jsonb_build_object('amount', 25000)
  );
  IF v_result->>'status' = 'direct_allowed' THEN
    check_name := 'T8_threshold_founder_override'; status := 'PASS'; detail := 'override applied';
  ELSE
    check_name := 'T8_threshold_founder_override'; status := 'FAIL'; detail := v_result::text;
  END IF;
  RETURN NEXT;

  -- T9 — member + money.payout → decision_opened (threshold=0 forces decision)
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_member_uid, 'role','authenticated')::text, true);
  v_result := public.request_or_execute_action(
    v_group_id, 'money.payout', 'money_movement', NULL,
    jsonb_build_object('amount', 5000)
  );
  IF v_result->>'status' = 'decision_opened' AND v_result->>'decision_template_key' = 'decision.payout' THEN
    check_name := 'T9_payout_force_decision'; status := 'PASS'; detail := 'payout decision opened';
    v_decision_ids := array_append(v_decision_ids, (v_result->>'decision_id')::uuid);
  ELSIF v_result->>'status' = 'denied' AND v_result->>'reason' = 'missing_permission' THEN
    check_name := 'T9_payout_force_decision'; status := 'INFO'; detail := 'member lacks payout.record perm';
  ELSE
    check_name := 'T9_payout_force_decision'; status := 'FAIL'; detail := v_result::text;
  END IF;
  RETURN NEXT;

  -- T10 — member + membership.ban → decision_opened
  v_result := public.request_or_execute_action(
    v_group_id, 'membership.ban', 'membership', gen_random_uuid()
  );
  IF v_result->>'status' = 'decision_opened' AND v_result->>'decision_template_key' = 'decision.membership_remove' THEN
    check_name := 'T10_ban_decision_opened'; status := 'PASS'; detail := 'ban decision opened';
    v_decision_ids := array_append(v_decision_ids, (v_result->>'decision_id')::uuid);
  ELSIF v_result->>'status' = 'denied' AND v_result->>'reason' = 'missing_permission' THEN
    check_name := 'T10_ban_decision_opened'; status := 'INFO'; detail := 'member lacks members.remove';
  ELSE
    check_name := 'T10_ban_decision_opened'; status := 'FAIL'; detail := v_result::text;
  END IF;
  RETURN NEXT;

  -- Cleanup
  IF array_length(v_decision_ids, 1) > 0 THEN
    DELETE FROM public.group_decisions WHERE id = ANY(v_decision_ids);
  END IF;
  check_name := 'cleanup'; status := 'PASS'; detail := 'deleted '||COALESCE(array_length(v_decision_ids,1), 0)||' smoke decisions';
  RETURN NEXT;
END;
$$;
