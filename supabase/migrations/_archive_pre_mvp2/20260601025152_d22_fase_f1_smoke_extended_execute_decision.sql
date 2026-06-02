-- D.22 FASE F.1 smoke — verifies the new execute_decision branches fire end-to-end.
-- Opens engine.toggle decision via request_or_execute_action, force-passes it,
-- calls execute_decision, asserts engine_active flipped. Restores state at end.

CREATE OR REPLACE FUNCTION public._smoke_action_governance_end_to_end()
RETURNS TABLE(check_name text, status text, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_group_id        uuid;
  v_member_uid      uuid;
  v_initial_active  boolean;
  v_after_active    boolean;
  v_result          jsonb;
  v_decision_id     uuid;
  v_exec_result     record;
BEGIN
  SELECT g.id INTO v_group_id
    FROM groups g WHERE g.name LIKE '%Test Bench%' AND g.status='active' LIMIT 1;

  SELECT gm.user_id INTO v_member_uid
    FROM group_memberships gm
    JOIN group_member_roles gmr ON gmr.membership_id = gm.id
    JOIN group_roles gr ON gr.id = gmr.role_id AND gr.key='member'
   WHERE gm.group_id = v_group_id AND gm.status='active' LIMIT 1;

  IF v_group_id IS NULL OR v_member_uid IS NULL THEN
    check_name := 'fixture'; status := 'FAIL'; detail := 'missing test bench/member'; RETURN NEXT; RETURN;
  END IF;

  SELECT engine_active INTO v_initial_active FROM groups WHERE id = v_group_id;

  -- T1 — member opens engine.toggle decision via executor.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_member_uid, 'role','authenticated')::text, true);
  v_result := public.request_or_execute_action(
    v_group_id, 'engine.toggle', 'group', v_group_id,
    jsonb_build_object('active', NOT v_initial_active)
  );
  IF v_result->>'status' = 'decision_opened' THEN
    v_decision_id := (v_result->>'decision_id')::uuid;
    check_name := 'T1_engine_toggle_decision_opened'; status := 'PASS'; detail := 'id='||v_decision_id::text;
  ELSE
    check_name := 'T1_engine_toggle_decision_opened'; status := 'FAIL'; detail := v_result::text; RETURN NEXT; RETURN;
  END IF;
  RETURN NEXT;

  -- T2 — force-pass the decision (bypass voting for smoke purposes).
  UPDATE group_decisions
     SET status='passed', decided_at=now(),
         result = jsonb_build_object('outcome','passed','via','smoke_force_pass')
   WHERE id = v_decision_id;
  IF FOUND THEN
    check_name := 'T2_force_pass'; status := 'PASS'; detail := 'set passed';
  ELSE
    check_name := 'T2_force_pass'; status := 'FAIL'; detail := 'no row';
  END IF;
  RETURN NEXT;

  -- T3 — call execute_decision and check effects (assert_permission needs decisions.execute;
  --       member doesn't have it by default → switch to founder for execution).
  DECLARE
    v_founder_uid uuid;
  BEGIN
    SELECT gm.user_id INTO v_founder_uid
      FROM group_memberships gm
      JOIN group_member_roles gmr ON gmr.membership_id = gm.id
      JOIN group_roles gr ON gr.id = gmr.role_id AND gr.key='founder'
     WHERE gm.group_id = v_group_id AND gm.status='active' LIMIT 1;

    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_founder_uid, 'role','authenticated')::text, true);
    SELECT * INTO v_exec_result FROM public.execute_decision(v_decision_id);
  END;

  IF v_exec_result.status = 'executed' THEN
    check_name := 'T3_execute_decision_engine_toggle';
    status := 'PASS';
    detail := 'effects='||v_exec_result.effects::text;
  ELSE
    check_name := 'T3_execute_decision_engine_toggle';
    status := 'FAIL';
    detail := COALESCE(v_exec_result.status,'NULL');
  END IF;
  RETURN NEXT;

  -- T4 — verify side effect (engine_active flipped).
  SELECT engine_active INTO v_after_active FROM groups WHERE id = v_group_id;
  IF v_after_active IS DISTINCT FROM v_initial_active THEN
    check_name := 'T4_engine_active_flipped';
    status := 'PASS';
    detail := 'from '||v_initial_active||' to '||v_after_active;
  ELSE
    check_name := 'T4_engine_active_flipped';
    status := 'FAIL';
    detail := 'unchanged: '||v_initial_active;
  END IF;
  RETURN NEXT;

  -- Restore + cleanup.
  UPDATE groups SET engine_active = v_initial_active WHERE id = v_group_id;
  DELETE FROM group_decisions WHERE id = v_decision_id;
  check_name := 'cleanup'; status := 'PASS'; detail := 'restored engine_active='||v_initial_active||', deleted decision';
  RETURN NEXT;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._smoke_action_governance_end_to_end() FROM PUBLIC;
