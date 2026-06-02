-- D.22 FASE H — Smoke completo end-to-end de las 5 acciones ya UI-wired:
-- engine.toggle, resource.archive, resource.transfer, membership.ban, rule.archive.
-- Cada path: open decision via request_or_execute_action → force-pass →
-- execute_decision → verify side effect → cleanup. Restaura estado al final.

CREATE OR REPLACE FUNCTION public._smoke_action_governance_full()
RETURNS TABLE(check_name text, status text, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_group_id       uuid;
  v_founder_uid    uuid;
  v_member_uid     uuid;
  v_member_mid     uuid;
  v_other_mid      uuid;
  v_resource_id    uuid;
  v_transfer_res   uuid;
  v_rule_id        uuid;
  v_decision_id    uuid;
  v_result         jsonb;
  v_exec           record;
  v_initial_engine boolean;
  v_decision_ids   uuid[] := ARRAY[]::uuid[];
  v_resource_ids   uuid[] := ARRAY[]::uuid[];
  v_rule_ids       uuid[] := ARRAY[]::uuid[];
  v_resource_status text;
  v_resource_owner uuid;
  v_member_status  text;
  v_rule_status    text;
BEGIN
  -- Fixture
  SELECT g.id INTO v_group_id
    FROM groups g WHERE g.name LIKE '%Test Bench%' AND g.status='active' LIMIT 1;
  SELECT gm.user_id INTO v_founder_uid
    FROM group_memberships gm
    JOIN group_member_roles gmr ON gmr.membership_id=gm.id
    JOIN group_roles gr ON gr.id=gmr.role_id AND gr.key='founder'
   WHERE gm.group_id=v_group_id AND gm.status='active' LIMIT 1;
  SELECT gm.user_id, gm.id INTO v_member_uid, v_member_mid
    FROM group_memberships gm
    JOIN group_member_roles gmr ON gmr.membership_id=gm.id
    JOIN group_roles gr ON gr.id=gmr.role_id AND gr.key='member'
   WHERE gm.group_id=v_group_id AND gm.status='active' AND gm.user_id<>v_founder_uid
   LIMIT 1;
  SELECT gm.id INTO v_other_mid
    FROM group_memberships gm
   WHERE gm.group_id=v_group_id AND gm.status='active'
     AND gm.user_id<>v_founder_uid AND gm.id<>v_member_mid
   LIMIT 1;

  IF v_group_id IS NULL OR v_founder_uid IS NULL OR v_member_uid IS NULL OR v_other_mid IS NULL THEN
    check_name:='fixture'; status:='FAIL';
    detail:='missing group/founder/member/other-member in Test Bench';
    RETURN NEXT; RETURN;
  END IF;

  SELECT engine_active INTO v_initial_engine FROM groups WHERE id=v_group_id;

  -- T1 engine.toggle
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_member_uid,'role','authenticated')::text,true);
  v_result := public.request_or_execute_action(
    v_group_id,'engine.toggle','group',v_group_id,
    jsonb_build_object('active',NOT v_initial_engine)
  );
  IF v_result->>'status' = 'decision_opened' THEN
    v_decision_id := (v_result->>'decision_id')::uuid;
    v_decision_ids := array_append(v_decision_ids, v_decision_id);
    UPDATE group_decisions SET status='passed', decided_at=now(),
      result=jsonb_build_object('outcome','passed','via','smoke') WHERE id=v_decision_id;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_founder_uid,'role','authenticated')::text,true);
    SELECT * INTO v_exec FROM public.execute_decision(v_decision_id);
    IF v_exec.status='executed' AND (SELECT engine_active FROM groups WHERE id=v_group_id) <> v_initial_engine THEN
      check_name:='T1_engine_toggle_e2e'; status:='PASS';
      detail:='flipped to '||(NOT v_initial_engine)::text;
    ELSE
      check_name:='T1_engine_toggle_e2e'; status:='FAIL'; detail:=v_exec::text;
    END IF;
  ELSE
    check_name:='T1_engine_toggle_e2e'; status:='FAIL'; detail:=v_result::text;
  END IF;
  RETURN NEXT;
  UPDATE groups SET engine_active=v_initial_engine WHERE id=v_group_id;

  -- (Body continues with T2-T5 + cleanup; superseded by later migrations.)
  -- This initial version had ambiguous status references and cleanup
  -- conflicts with the append-only group_rule_versions guard. Final
  -- working form lives in
  --   20260601032327_d22_fase_h_smoke_full_governance_cleanup_best_effort.sql.

  check_name:='_initial_form'; status:='INFO';
  detail:='Initial smoke body; see fix_ambiguous + fix_cleanup + cleanup_best_effort migrations for the working version.';
  RETURN NEXT;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._smoke_action_governance_full() FROM PUBLIC;
COMMENT ON FUNCTION public._smoke_action_governance_full() IS
  'D.22 FASE H smoke — full end-to-end paths for engine/resource(archive+transfer)/membership.ban/rule.archive.';
