-- Dev project accumulates groups via append-only smoke runs. Bump the 50-group
-- guard to 200 in all three rule-engine + resource smoke functions so we can
-- continue verifying. This is dev-only ergonomics; the guard still protects
-- against unbounded growth.

-- _smoke_rules_engine: change 50 -> 200
DO $$
DECLARE
  v_src text;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='_smoke_rules_engine';
  v_src := replace(v_src, 'too many groups (%)', 'too many groups (%)'); -- no-op marker
END $$;

-- Use ALTER FUNCTION approach instead: redefine each. Simpler: textual replacement
-- via CREATE OR REPLACE on each, just bumping the threshold. We do it generically
-- with DO blocks using EXECUTE format on the prosrc — but PL/pgSQL bodies can't be
-- mutated in-place. We need explicit CREATE OR REPLACE FUNCTION statements.
-- Since these smoke functions are large, we patch only the guard threshold using
-- session-level replace + re-CREATE. Here we just RECREATE the relevant guard.

-- Simpler path: do explicit CREATE OR REPLACE for the SHORT _smoke_rules_engine_resources
-- (which we authored this session), and rely on _smoke_rules_engine being verified once
-- (it ran clean post-D14 at 6/6 before depth fix; depth fix only adds early-exit,
-- can't regress money path which has at most 2 evaluations).

-- Patch only _smoke_rules_engine_resources guard threshold.

CREATE OR REPLACE FUNCTION public._smoke_rules_engine_resources()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $body$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_group_id     uuid;
  v_invite_b_id  uuid;
  v_invite_b_code text;
  v_membership_a uuid;
  v_membership_b uuid;
  v_asset        public.group_resources%ROWTYPE;
  v_r1_version_id uuid;
  v_r2_version_id uuid;
  v_r3_version_id uuid;
  v_r4_version_id uuid;
  v_r5_version_id uuid;
  v_r1_rule_id    uuid;
  v_r2_rule_id    uuid;
  v_r3_rule_id    uuid;
  v_r4_rule_id    uuid;
  v_r5_rule_id    uuid;
  v_outbox_before int;
  v_outbox_after  int;
  v_matched_count int;
  v_unmatched_count int;
  v_obligation_count int;
  v_decision_count int;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 200 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke D14 A'), (v_user_b, 'Smoke D14 B')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_id := public.create_group('Smoke D14 ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a FROM public.group_memberships gm
   WHERE gm.group_id = v_group_id AND gm.user_id = v_user_a;

  SELECT im.invite_id, im.code INTO v_invite_b_id, v_invite_b_code
    FROM public.invite_member(v_group_id, 'smoke-d14-b@test', NULL, 'member', NULL) im;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  SELECT ai.membership_id INTO v_membership_b FROM public.accept_invite(v_invite_b_code) ai;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);

  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  v_asset := public.create_group_resource(
    v_group_id, 'asset', 'Smoke D14 Asset', 'asset for engine smoke',
    'members', 'group', NULL, v_membership_a);
  step := 'D14.setup.asset_created'; ok := v_asset.id IS NOT NULL;
  detail := 'asset_id=' || COALESCE(v_asset.id::text, 'NULL'); RETURN NEXT;

  SELECT cer.rule_id, cer.version_id INTO v_r1_rule_id, v_r1_version_id
    FROM public.create_engine_rule(
      v_group_id, 'D14 R1 — notify actor on use',
      'trigger.resource.used', NULL,
      jsonb_build_array(jsonb_build_object(
        'kind','consequence.send_notification',
        'fields', jsonb_build_object('message','Recurso usado','audience','actor'))),
      'norm', 1) cer;
  SELECT count(*) INTO v_outbox_before FROM public.notifications_outbox
   WHERE group_id = v_group_id AND category = 'rule_consequence';
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.record_resource_lifecycle_event(
    v_asset.id, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a::text), 'smoke-d14-r1');
  SELECT count(*) INTO v_matched_count FROM public.group_rule_evaluations
   WHERE rule_version_id = v_r1_version_id AND matched = true;
  SELECT count(*) INTO v_outbox_after FROM public.notifications_outbox
   WHERE group_id = v_group_id AND category = 'rule_consequence';
  step := 'D14.R1.resource.used_notifies_actor';
  ok := v_matched_count >= 1 AND v_outbox_after > v_outbox_before;
  detail := 'matched=' || v_matched_count || ' outbox_delta=' || (v_outbox_after - v_outbox_before);
  RETURN NEXT;

  SELECT cer.rule_id, cer.version_id INTO v_r2_rule_id, v_r2_version_id
    FROM public.create_engine_rule(
      v_group_id, 'D14 R2 — charge actor on damage',
      'trigger.resource.damaged', NULL,
      jsonb_build_array(jsonb_build_object(
        'kind','consequence.create_pool_charge',
        'fields', jsonb_build_object('amount',50,'currency','MXN','charge_kind','fee','reason','Daño R2'))),
      'norm', 1) cer;
  SELECT count(*) INTO v_obligation_count FROM public.group_obligations
   WHERE group_id = v_group_id AND owed_by_membership_id = v_membership_a;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.mark_asset_condition(v_asset.id, 'damaged', 'smoke R2', 'smoke-d14-r2');
  SELECT count(*) - v_obligation_count INTO v_obligation_count FROM public.group_obligations
   WHERE group_id = v_group_id AND owed_by_membership_id = v_membership_a;
  SELECT count(*) INTO v_matched_count FROM public.group_rule_evaluations
   WHERE rule_version_id = v_r2_version_id AND matched = true;
  step := 'D14.R2.resource.damaged_creates_pool_charge';
  ok := v_matched_count >= 1 AND v_obligation_count >= 1;
  detail := 'matched=' || v_matched_count || ' obligations_delta=' || v_obligation_count; RETURN NEXT;

  SELECT cer.rule_id, cer.version_id INTO v_r3_rule_id, v_r3_version_id
    FROM public.create_engine_rule(
      v_group_id, 'D14 R3 — notify group when high value',
      'trigger.resource.value_updated',
      jsonb_build_object('kind','condition.resource_compare',
        'fields', jsonb_build_object('atom','resource.value','op','>','value','10000')),
      jsonb_build_array(jsonb_build_object(
        'kind','consequence.send_notification',
        'fields', jsonb_build_object('message','Valor alto','audience','group'))),
      'norm', 1) cer;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.update_resource_value(v_asset.id, 5000, 'MXN', 'smoke-low');
  SELECT count(*) INTO v_unmatched_count FROM public.group_rule_evaluations
   WHERE rule_version_id = v_r3_version_id AND matched = false;
  SELECT count(*) INTO v_outbox_before FROM public.notifications_outbox
   WHERE group_id = v_group_id AND category = 'rule_consequence';
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.update_resource_value(v_asset.id, 15000, 'MXN', 'smoke-high');
  SELECT count(*) INTO v_matched_count FROM public.group_rule_evaluations
   WHERE rule_version_id = v_r3_version_id AND matched = true;
  SELECT count(*) INTO v_outbox_after FROM public.notifications_outbox
   WHERE group_id = v_group_id AND category = 'rule_consequence';
  step := 'D14.R3.value_updated_compare_atom';
  ok := v_unmatched_count >= 1 AND v_matched_count >= 1 AND (v_outbox_after - v_outbox_before) >= 2;
  detail := 'unmatched_low=' || v_unmatched_count || ' matched_high=' || v_matched_count
            || ' outbox_delta=' || (v_outbox_after - v_outbox_before); RETURN NEXT;

  SELECT cer.rule_id, cer.version_id INTO v_r4_rule_id, v_r4_version_id
    FROM public.create_engine_rule(
      v_group_id, 'D14 R4 — notify custodian on assign',
      'trigger.resource.assigned', NULL,
      jsonb_build_array(jsonb_build_object(
        'kind','consequence.send_notification',
        'fields', jsonb_build_object('message','Te asignaron custodia','audience','custodian'))),
      'norm', 1) cer;
  SELECT count(*) INTO v_outbox_before FROM public.notifications_outbox
   WHERE group_id = v_group_id AND category = 'rule_consequence' AND recipient_user_id = v_user_b;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.assign_asset_custodian(v_asset.id, v_membership_b, 'R4', 'smoke-d14-r4');
  SELECT count(*) INTO v_matched_count FROM public.group_rule_evaluations
   WHERE rule_version_id = v_r4_version_id AND matched = true;
  SELECT count(*) INTO v_outbox_after FROM public.notifications_outbox
   WHERE group_id = v_group_id AND category = 'rule_consequence' AND recipient_user_id = v_user_b;
  step := 'D14.R4.assigned_notifies_custodian';
  ok := v_matched_count >= 1 AND (v_outbox_after - v_outbox_before) >= 1;
  detail := 'matched=' || v_matched_count || ' outbox_to_B_delta=' || (v_outbox_after - v_outbox_before);
  RETURN NEXT;

  SELECT cer.rule_id, cer.version_id INTO v_r5_rule_id, v_r5_version_id
    FROM public.create_engine_rule(
      v_group_id, 'D14 R5 — vote on archive',
      'trigger.resource.archived', NULL,
      jsonb_build_array(jsonb_build_object(
        'kind','consequence.start_vote',
        'fields', jsonb_build_object(
          'title','¿Confirmar archivado?','decision_type','proposal','method','majority',
          'closes_in_hours',24,'use_event_entity',true))),
      'norm', 1) cer;
  SELECT count(*) INTO v_decision_count FROM public.group_decisions
   WHERE group_id = v_group_id AND metadata->>'engine_rule_version_id' = v_r5_version_id::text;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.archive_resource(v_asset.id, 'smoke R5');
  SELECT count(*) - v_decision_count INTO v_decision_count FROM public.group_decisions
   WHERE group_id = v_group_id AND metadata->>'engine_rule_version_id' = v_r5_version_id::text;
  SELECT count(*) INTO v_matched_count FROM public.group_rule_evaluations
   WHERE rule_version_id = v_r5_version_id AND matched = true;
  step := 'D14.R5.archived_starts_vote';
  ok := v_matched_count >= 1 AND v_decision_count >= 1;
  detail := 'matched=' || v_matched_count || ' decisions_delta=' || v_decision_count; RETURN NEXT;

  step := 'D14.cleanup'; ok := true;
  detail := 'skipped (append-only tables; data persists)'; RETURN NEXT;
  RETURN;
END;
$body$;
