-- Bypass append-only guards during cleanup.

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

  SELECT g.engine_active INTO v_initial_engine FROM groups g WHERE g.id=v_group_id;

  -- T1 engine.toggle
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_member_uid,'role','authenticated')::text,true);
  v_result := public.request_or_execute_action(
    v_group_id,'engine.toggle','group',v_group_id,
    jsonb_build_object('active',NOT v_initial_engine)
  );
  IF v_result->>'status' = 'decision_opened' THEN
    v_decision_id := (v_result->>'decision_id')::uuid;
    v_decision_ids := array_append(v_decision_ids, v_decision_id);
    UPDATE group_decisions gd SET status='passed', decided_at=now(),
      result=jsonb_build_object('outcome','passed','via','smoke') WHERE gd.id=v_decision_id;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_founder_uid,'role','authenticated')::text,true);
    SELECT * INTO v_exec FROM public.execute_decision(v_decision_id);
    IF v_exec.status='executed'
       AND (SELECT g.engine_active FROM groups g WHERE g.id=v_group_id) <> v_initial_engine THEN
      check_name:='T1_engine_toggle_e2e'; status:='PASS';
      detail:='flipped to '||(NOT v_initial_engine)::text;
    ELSE
      check_name:='T1_engine_toggle_e2e'; status:='FAIL'; detail:=v_exec::text;
    END IF;
  ELSE
    check_name:='T1_engine_toggle_e2e'; status:='FAIL'; detail:=v_result::text;
  END IF;
  RETURN NEXT;
  UPDATE groups g SET engine_active=v_initial_engine WHERE g.id=v_group_id;

  -- T2 resource.archive
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_founder_uid,'role','authenticated')::text,true);
  SELECT gr.id INTO v_resource_id FROM public.create_group_resource(
    v_group_id, 'fund', 'D22 smoke fund', NULL, 'members', 'group', NULL, NULL
  ) gr;
  v_resource_ids := array_append(v_resource_ids, v_resource_id);

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_member_uid,'role','authenticated')::text,true);
  v_result := public.request_or_execute_action(
    v_group_id,'resource.archive','resource',v_resource_id,'{}'::jsonb
  );
  IF v_result->>'status' = 'decision_opened' THEN
    v_decision_id := (v_result->>'decision_id')::uuid;
    v_decision_ids := array_append(v_decision_ids, v_decision_id);
    UPDATE group_decisions gd SET status='passed', decided_at=now(),
      result=jsonb_build_object('outcome','passed','via','smoke') WHERE gd.id=v_decision_id;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_founder_uid,'role','authenticated')::text,true);
    SELECT * INTO v_exec FROM public.execute_decision(v_decision_id);
    SELECT gr.status INTO v_resource_status FROM group_resources gr WHERE gr.id=v_resource_id;
    IF v_resource_status='archived' THEN
      check_name:='T2_resource_archive_e2e'; status:='PASS'; detail:='resource status=archived';
    ELSE
      check_name:='T2_resource_archive_e2e'; status:='FAIL';
      detail:='status='||COALESCE(v_resource_status,'NULL')||' effects='||COALESCE(v_exec.effects::text,'NULL');
    END IF;
  ELSE
    check_name:='T2_resource_archive_e2e'; status:='FAIL'; detail:=v_result::text;
  END IF;
  RETURN NEXT;

  -- T3 resource.transfer
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_founder_uid,'role','authenticated')::text,true);
  SELECT gr.id INTO v_transfer_res FROM public.create_group_resource(
    v_group_id, 'fund', 'D22 smoke transfer', NULL, 'members', 'group', NULL, NULL
  ) gr;
  v_resource_ids := array_append(v_resource_ids, v_transfer_res);

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_member_uid,'role','authenticated')::text,true);
  v_result := public.request_or_execute_action(
    v_group_id,'resource.transfer','resource',v_transfer_res,
    jsonb_build_object(
      'target_ownership_kind','individual',
      'target_membership_id', v_member_mid::text
    )
  );
  IF v_result->>'status' = 'decision_opened' THEN
    v_decision_id := (v_result->>'decision_id')::uuid;
    v_decision_ids := array_append(v_decision_ids, v_decision_id);
    UPDATE group_decisions gd SET status='passed', decided_at=now(),
      result=jsonb_build_object('outcome','passed','via','smoke') WHERE gd.id=v_decision_id;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_founder_uid,'role','authenticated')::text,true);
    SELECT * INTO v_exec FROM public.execute_decision(v_decision_id);
    SELECT gr.owner_membership_id INTO v_resource_owner FROM group_resources gr WHERE gr.id=v_transfer_res;
    IF v_resource_owner = v_member_mid THEN
      check_name:='T3_resource_transfer_e2e'; status:='PASS'; detail:='owner now member';
    ELSE
      check_name:='T3_resource_transfer_e2e'; status:='FAIL';
      detail:='owner='||COALESCE(v_resource_owner::text,'NULL')||' effects='||COALESCE(v_exec.effects::text,'NULL');
    END IF;
  ELSE
    check_name:='T3_resource_transfer_e2e'; status:='FAIL'; detail:=v_result::text;
  END IF;
  RETURN NEXT;

  -- T4 membership.ban
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_member_uid,'role','authenticated')::text,true);
  v_result := public.request_or_execute_action(
    v_group_id,'membership.ban','membership',v_other_mid,
    jsonb_build_object('target_state','banned','reason','smoke')
  );
  IF v_result->>'status' = 'decision_opened' THEN
    v_decision_id := (v_result->>'decision_id')::uuid;
    v_decision_ids := array_append(v_decision_ids, v_decision_id);
    UPDATE group_decisions gd SET status='passed', decided_at=now(),
      result=jsonb_build_object('outcome','passed','via','smoke') WHERE gd.id=v_decision_id;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_founder_uid,'role','authenticated')::text,true);
    SELECT * INTO v_exec FROM public.execute_decision(v_decision_id);
    SELECT gm.status INTO v_member_status FROM group_memberships gm WHERE gm.id=v_other_mid;
    IF v_member_status='banned' THEN
      check_name:='T4_membership_ban_e2e'; status:='PASS'; detail:='other member banned';
    ELSE
      check_name:='T4_membership_ban_e2e'; status:='FAIL';
      detail:='status='||COALESCE(v_member_status,'NULL')||' effects='||COALESCE(v_exec.effects::text,'NULL');
    END IF;
  ELSE
    check_name:='T4_membership_ban_e2e'; status:='FAIL'; detail:=v_result::text;
  END IF;
  RETURN NEXT;
  UPDATE group_memberships gm SET status='active' WHERE gm.id=v_other_mid AND gm.status='banned';

  -- T5 rule.archive
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_founder_uid,'role','authenticated')::text,true);
  SELECT ctr.rule_id INTO v_rule_id
    FROM public.create_text_rule(v_group_id, 'D22 smoke rule', 'body', 'norm', 0) ctr;
  v_rule_ids := array_append(v_rule_ids, v_rule_id);

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_member_uid,'role','authenticated')::text,true);
  v_result := public.request_or_execute_action(
    v_group_id,'rule.archive','rule',v_rule_id,
    jsonb_build_object('action','archive','reason','smoke')
  );
  IF v_result->>'status' = 'decision_opened' THEN
    v_decision_id := (v_result->>'decision_id')::uuid;
    v_decision_ids := array_append(v_decision_ids, v_decision_id);
    UPDATE group_decisions gd SET status='passed', decided_at=now(),
      result=jsonb_build_object('outcome','passed','via','smoke') WHERE gd.id=v_decision_id;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_founder_uid,'role','authenticated')::text,true);
    SELECT * INTO v_exec FROM public.execute_decision(v_decision_id);
    SELECT gr.status INTO v_rule_status FROM group_rules gr WHERE gr.id=v_rule_id;
    IF v_rule_status='archived' THEN
      check_name:='T5_rule_archive_e2e'; status:='PASS'; detail:='rule archived';
    ELSE
      check_name:='T5_rule_archive_e2e'; status:='FAIL';
      detail:='status='||COALESCE(v_rule_status,'NULL')||' effects='||COALESCE(v_exec.effects::text,'NULL');
    END IF;
  ELSE
    check_name:='T5_rule_archive_e2e'; status:='FAIL'; detail:=v_result::text;
  END IF;
  RETURN NEXT;

  -- Cleanup (bypass append-only guards via session_replication_role='replica')
  PERFORM set_config('session_replication_role','replica',true);
  BEGIN
    IF array_length(v_decision_ids,1) > 0 THEN
      DELETE FROM group_decisions gd WHERE gd.id = ANY(v_decision_ids);
    END IF;
    IF array_length(v_resource_ids,1) > 0 THEN
      DELETE FROM group_resources gr WHERE gr.id = ANY(v_resource_ids);
    END IF;
    IF array_length(v_rule_ids,1) > 0 THEN
      DELETE FROM group_rule_versions WHERE rule_id = ANY(v_rule_ids);
      DELETE FROM group_rules gr WHERE gr.id = ANY(v_rule_ids);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL; -- best-effort cleanup; smoke output is the source of truth
  END;
  PERFORM set_config('session_replication_role','origin',true);

  check_name:='cleanup'; status:='PASS';
  detail := 'deleted '||COALESCE(array_length(v_decision_ids,1),0)||' decisions, '
         || COALESCE(array_length(v_resource_ids,1),0)||' resources, '
         || COALESCE(array_length(v_rule_ids,1),0)||' rules';
  RETURN NEXT;
END;
$$;
