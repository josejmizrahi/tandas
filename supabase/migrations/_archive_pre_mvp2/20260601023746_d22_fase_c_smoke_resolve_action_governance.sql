-- D.22 FASE C — smoke for resolve_action_governance.
-- Verifies T1-T10 paths using sandbox "D.22 Test Bench".

CREATE OR REPLACE FUNCTION public._smoke_action_governance_resolver()
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
BEGIN
  -- Fixture
  SELECT g.id INTO v_group_id
    FROM groups g
   WHERE g.name LIKE '%Test Bench%' AND g.status='active'
   LIMIT 1;

  IF v_group_id IS NULL THEN
    check_name := 'fixture'; status := 'FAIL'; detail := 'no test bench group'; RETURN NEXT; RETURN;
  END IF;

  SELECT gm.user_id INTO v_founder_uid
    FROM group_memberships gm
    JOIN group_member_roles gmr ON gmr.membership_id = gm.id
    JOIN group_roles gr ON gr.id = gmr.role_id AND gr.key='founder'
   WHERE gm.group_id = v_group_id AND gm.status='active'
   LIMIT 1;

  SELECT gm.user_id INTO v_member_uid
    FROM group_memberships gm
   WHERE gm.group_id = v_group_id AND gm.status='active' AND gm.user_id <> v_founder_uid
   ORDER BY joined_at ASC NULLS LAST
   LIMIT 1;

  IF v_founder_uid IS NULL OR v_member_uid IS NULL THEN
    check_name := 'fixture'; status := 'FAIL'; detail := 'missing founder/member'; RETURN NEXT; RETURN;
  END IF;

  -- T1 — unknown action_key → action_unsupported
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_member_uid, 'role','authenticated')::text, true);
  v_result := public.resolve_action_governance(v_group_id, 'nonexistent.fake');
  IF v_result->>'reason' = 'action_unsupported' THEN
    check_name := 'T1_action_unsupported'; status := 'PASS'; detail := 'reason ok';
  ELSE
    check_name := 'T1_action_unsupported'; status := 'FAIL'; detail := COALESCE(v_result->>'reason','NULL');
  END IF;
  RETURN NEXT;

  -- T2 — unknown group → group_not_found
  v_result := public.resolve_action_governance(gen_random_uuid(), 'resource.create');
  IF v_result->>'reason' = 'group_not_found' THEN
    check_name := 'T2_group_not_found'; status := 'PASS'; detail := 'reason ok';
  ELSE
    check_name := 'T2_group_not_found'; status := 'FAIL'; detail := COALESCE(v_result->>'reason','NULL');
  END IF;
  RETURN NEXT;

  -- T3 — outsider → not_a_member
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_outsider, 'role','authenticated')::text, true);
  v_result := public.resolve_action_governance(v_group_id, 'resource.create');
  IF v_result->>'reason' = 'not_a_member' THEN
    check_name := 'T3_not_a_member'; status := 'PASS'; detail := 'reason ok';
  ELSE
    check_name := 'T3_not_a_member'; status := 'FAIL'; detail := COALESCE(v_result->>'reason','NULL');
  END IF;
  RETURN NEXT;

  -- T4 — self-only action → self_only_direct (no group needed)
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_member_uid, 'role','authenticated')::text, true);
  v_result := public.resolve_action_governance(NULL, 'identity.profile.update');
  IF v_result->>'reason' = 'self_only_direct' AND (v_result->>'direct_execute')::boolean THEN
    check_name := 'T4_self_only_direct'; status := 'PASS'; detail := 'reason+direct ok';
  ELSE
    check_name := 'T4_self_only_direct'; status := 'FAIL'; detail := COALESCE(v_result->>'reason','NULL');
  END IF;
  RETURN NEXT;

  -- T5 — member with perm → direct_by_default for resource.create
  v_result := public.resolve_action_governance(v_group_id, 'resource.create');
  IF v_result->>'reason' IN ('direct_by_default','founder_emergency_override') THEN
    check_name := 'T5_member_direct_by_default'; status := 'PASS'; detail := v_result->>'reason';
  ELSIF v_result->>'reason' = 'missing_permission' THEN
    check_name := 'T5_member_direct_by_default'; status := 'INFO'; detail := 'member lacks resources.create';
  ELSE
    check_name := 'T5_member_direct_by_default'; status := 'FAIL'; detail := COALESCE(v_result->>'reason','NULL');
  END IF;
  RETURN NEXT;

  -- T6 — member without perm → missing_permission for members.suspend
  v_result := public.resolve_action_governance(v_group_id, 'membership.suspend');
  IF v_result->>'reason' = 'missing_permission' THEN
    check_name := 'T6_member_missing_permission'; status := 'PASS'; detail := 'reason ok';
  ELSIF v_result->>'reason' = 'direct_by_default' THEN
    check_name := 'T6_member_missing_permission'; status := 'INFO'; detail := 'member has members.suspend perm';
  ELSE
    check_name := 'T6_member_missing_permission'; status := 'FAIL'; detail := COALESCE(v_result->>'reason','NULL');
  END IF;
  RETURN NEXT;

  -- T7 — founder calling membership.ban → founder_emergency_override
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_founder_uid, 'role','authenticated')::text, true);
  v_result := public.resolve_action_governance(v_group_id, 'membership.ban');
  IF v_result->>'reason' = 'founder_emergency_override' AND (v_result->>'direct_execute')::boolean THEN
    check_name := 'T7_founder_emergency_override'; status := 'PASS'; detail := 'override applied';
  ELSE
    check_name := 'T7_founder_emergency_override'; status := 'FAIL'; detail := COALESCE(v_result->>'reason','NULL');
  END IF;
  RETURN NEXT;

  -- T8 — founder calling engine.toggle (constitutional) → constitutional_action, NO override
  v_result := public.resolve_action_governance(v_group_id, 'engine.toggle');
  IF v_result->>'reason' = 'constitutional_action' AND (v_result->>'requires_decision')::boolean THEN
    check_name := 'T8_constitutional_no_override'; status := 'PASS'; detail := 'decision required';
  ELSE
    check_name := 'T8_constitutional_no_override'; status := 'FAIL'; detail := COALESCE(v_result->>'reason','NULL');
  END IF;
  RETURN NEXT;

  -- T9 — founder calling money.expense.record amount > 10000 → founder override path
  v_result := public.resolve_action_governance(
    v_group_id, 'money.expense.record', NULL, NULL,
    jsonb_build_object('amount', 25000)
  );
  IF v_result->>'reason' IN ('founder_emergency_override','direct_by_default')
     AND (v_result->>'direct_execute')::boolean THEN
    check_name := 'T9_founder_overrides_threshold'; status := 'PASS'; detail := v_result->>'reason';
  ELSE
    check_name := 'T9_founder_overrides_threshold'; status := 'FAIL'; detail := COALESCE(v_result->>'reason','NULL');
  END IF;
  RETURN NEXT;

  -- T10 — member calling resource.archive → decision_required_by_default
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_member_uid, 'role','authenticated')::text, true);
  v_result := public.resolve_action_governance(v_group_id, 'resource.archive');
  IF v_result->>'reason' = 'decision_required_by_default' AND (v_result->>'requires_decision')::boolean THEN
    check_name := 'T10_member_decision_required'; status := 'PASS'; detail := 'template='||COALESCE(v_result->>'decision_template_key','NULL');
  ELSIF v_result->>'reason' = 'missing_permission' THEN
    check_name := 'T10_member_decision_required'; status := 'INFO'; detail := 'member lacks perm';
  ELSE
    check_name := 'T10_member_decision_required'; status := 'FAIL'; detail := COALESCE(v_result->>'reason','NULL');
  END IF;
  RETURN NEXT;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._smoke_action_governance_resolver() FROM PUBLIC;
COMMENT ON FUNCTION public._smoke_action_governance_resolver() IS
  'D.22 FASE C smoke — T1-T10 paths for resolve_action_governance using D.22 Test Bench sandbox.';
