-- Fix: R2 archive blocked because R1 left an open peer_obligation on the asset.
-- Use a fresh asset for R2 (consistent with R3 already creating its own).

CREATE OR REPLACE FUNCTION public._smoke_rules_engine_d15()
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
  v_asset_r1     public.group_resources%ROWTYPE;
  v_asset_r2     public.group_resources%ROWTYPE;
  v_asset_r3     public.group_resources%ROWTYPE;
  v_r1_rule_id   uuid; v_r1_version_id uuid;
  v_r2_rule_id   uuid; v_r2_version_id uuid;
  v_r3_rule_id   uuid; v_r3_version_id uuid;
  v_outbox_before int; v_outbox_after int;
  v_matched_count int;
  v_peer_obl_count int;
  v_peer_obl_id uuid;
  v_decision_count int;
  v_rejected boolean;
  v_rejected_msg text;
  v_lineage_count int;
  v_lineage_sample jsonb;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 200 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke D15 A'), (v_user_b, 'Smoke D15 B')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_id := public.create_group('Smoke D15 ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a FROM public.group_memberships gm
   WHERE gm.group_id = v_group_id AND gm.user_id = v_user_a;

  SELECT im.invite_id, im.code INTO v_invite_b_id, v_invite_b_code
    FROM public.invite_member(v_group_id, 'smoke-d15-b@test', NULL, 'member', NULL) im;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  SELECT ai.membership_id INTO v_membership_b FROM public.accept_invite(v_invite_b_code) ai;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);

  -- R1 asset: B owns, A custodian (damaging it creates A->B peer obligation)
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  v_asset_r1 := public.create_group_resource(
    v_group_id, 'asset', 'Smoke D15 Asset R1', NULL,
    'members', 'individual', v_membership_b, v_membership_a);

  -- R2 asset: separate (R1 leaves an open obligation, would block archive)
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  v_asset_r2 := public.create_group_resource(
    v_group_id, 'asset', 'Smoke D15 Asset R2', NULL,
    'members', 'group', NULL, v_membership_a);

  -- R3 asset: separate (clean canvas for reassignment audience test)
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  v_asset_r3 := public.create_group_resource(
    v_group_id, 'asset', 'Smoke D15 Asset R3', NULL,
    'members', 'group', NULL, v_membership_a);

  step := 'D15.setup.assets_created';
  ok := v_asset_r1.id IS NOT NULL AND v_asset_r2.id IS NOT NULL AND v_asset_r3.id IS NOT NULL
    AND v_asset_r1.owner_membership_id = v_membership_b;
  detail := 'r1=' || substr(v_asset_r1.id::text,1,8)
            || ' r2=' || substr(v_asset_r2.id::text,1,8)
            || ' r3=' || substr(v_asset_r3.id::text,1,8); RETURN NEXT;

  -- R1
  SELECT cer.rule_id, cer.version_id INTO v_r1_rule_id, v_r1_version_id
    FROM public.create_engine_rule(
      v_group_id, 'D15 R1 — damage creates peer obligation to owner',
      'trigger.resource.damaged', NULL,
      jsonb_build_array(jsonb_build_object(
        'kind','consequence.create_obligation',
        'fields', jsonb_build_object(
          'counterparty','owner',
          'amount', 100,
          'currency', 'MXN',
          'reason','Daño material'))),
      'norm', 1) cer;
  SELECT count(*) INTO v_peer_obl_count FROM public.group_obligations
   WHERE group_id = v_group_id AND obligation_kind = 'peer_obligation'
     AND owed_by_membership_id = v_membership_a
     AND owed_to_membership_id = v_membership_b;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.mark_asset_condition(v_asset_r1.id, 'damaged', 'smoke D15 R1', 'smoke-d15-r1');
  SELECT count(*) - v_peer_obl_count INTO v_peer_obl_count FROM public.group_obligations
   WHERE group_id = v_group_id AND obligation_kind = 'peer_obligation'
     AND owed_by_membership_id = v_membership_a
     AND owed_to_membership_id = v_membership_b;
  SELECT count(*) INTO v_matched_count FROM public.group_rule_evaluations
   WHERE rule_version_id = v_r1_version_id AND matched = true;
  SELECT id INTO v_peer_obl_id FROM public.group_obligations
   WHERE group_id = v_group_id AND obligation_kind = 'peer_obligation'
     AND owed_by_membership_id = v_membership_a
     AND owed_to_membership_id = v_membership_b
   ORDER BY created_at DESC LIMIT 1;
  step := 'D15.R1.damaged_creates_peer_obligation';
  ok := v_matched_count >= 1 AND v_peer_obl_count = 1 AND v_peer_obl_id IS NOT NULL;
  detail := 'matched=' || v_matched_count
            || ' peer_obligation_delta=' || v_peer_obl_count
            || ' obligation_id=' || COALESCE(v_peer_obl_id::text,'NULL'); RETURN NEXT;

  -- R2
  SELECT cer.rule_id, cer.version_id INTO v_r2_rule_id, v_r2_version_id
    FROM public.create_engine_rule(
      v_group_id, 'D15 R2 — archive triggers vote',
      'trigger.resource.archived', NULL,
      jsonb_build_array(jsonb_build_object(
        'kind','consequence.start_vote',
        'fields', jsonb_build_object(
          'title','¿Confirmar archivado D15?',
          'decision_type','proposal',
          'method','majority',
          'closes_in_hours', 24,
          'use_event_entity', true))),
      'norm', 1) cer;
  SELECT count(*) INTO v_decision_count FROM public.group_decisions
   WHERE group_id = v_group_id AND metadata->>'engine_rule_version_id' = v_r2_version_id::text;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.archive_resource(v_asset_r2.id, 'smoke D15 R2 archive');
  SELECT count(*) - v_decision_count INTO v_decision_count FROM public.group_decisions
   WHERE group_id = v_group_id AND metadata->>'engine_rule_version_id' = v_r2_version_id::text;
  SELECT count(*) INTO v_matched_count FROM public.group_rule_evaluations
   WHERE rule_version_id = v_r2_version_id AND matched = true;
  step := 'D15.R2.archived_starts_vote';
  ok := v_matched_count >= 1 AND v_decision_count >= 1;
  detail := 'matched=' || v_matched_count || ' decisions_delta=' || v_decision_count; RETURN NEXT;

  -- R3
  SELECT cer.rule_id, cer.version_id INTO v_r3_rule_id, v_r3_version_id
    FROM public.create_engine_rule(
      v_group_id, 'D15 R3 — notify custodian on assign',
      'trigger.resource.assigned', NULL,
      jsonb_build_array(jsonb_build_object(
        'kind','consequence.send_notification',
        'fields', jsonb_build_object(
          'message','Te asignaron custodia (D15)',
          'audience','custodian'))),
      'norm', 1) cer;
  SELECT count(*) INTO v_outbox_before FROM public.notifications_outbox
   WHERE group_id = v_group_id AND category = 'rule_consequence' AND recipient_user_id = v_user_b;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.assign_asset_custodian(v_asset_r3.id, v_membership_b, 'reassign D15', 'smoke-d15-r3');
  SELECT count(*) INTO v_matched_count FROM public.group_rule_evaluations
   WHERE rule_version_id = v_r3_version_id AND matched = true;
  SELECT count(*) INTO v_outbox_after FROM public.notifications_outbox
   WHERE group_id = v_group_id AND category = 'rule_consequence' AND recipient_user_id = v_user_b;
  SELECT actions_emitted->0 INTO v_lineage_sample
    FROM public.group_rule_evaluations
   WHERE rule_version_id = v_r3_version_id AND matched = true
   ORDER BY created_at DESC LIMIT 1;
  step := 'D15.R3.assigned_notifies_custodian_with_recipients';
  ok := v_matched_count >= 1
        AND (v_outbox_after - v_outbox_before) >= 1
        AND v_lineage_sample ? 'recipient_user_ids'
        AND v_lineage_sample->>'target_kind' = 'notification';
  detail := 'matched=' || v_matched_count
            || ' outbox_to_B_delta=' || (v_outbox_after - v_outbox_before)
            || ' target_kind=' || COALESCE(v_lineage_sample->>'target_kind','NULL')
            || ' recipients=' || jsonb_array_length(COALESCE(v_lineage_sample->'recipient_user_ids','[]'::jsonb))::text;
  RETURN NEXT;

  -- R4 — invalid combo rejected
  v_rejected := false; v_rejected_msg := NULL;
  BEGIN
    PERFORM public.create_engine_rule(
      v_group_id, 'D15 R4 — should be rejected',
      'trigger.mandate.granted', NULL,
      jsonb_build_array(jsonb_build_object(
        'kind','consequence.issue_sanction',
        'fields', jsonb_build_object('severity', 2, 'reason', 'invalid combo'))),
      'norm', 1);
  EXCEPTION WHEN OTHERS THEN
    v_rejected := true;
    GET STACKED DIAGNOSTICS v_rejected_msg = MESSAGE_TEXT;
  END;
  step := 'D15.R4.invalid_combo_rejected';
  ok := v_rejected
        AND v_rejected_msg ILIKE '%invalid rule shape%'
        AND v_rejected_msg ILIKE '%not_compatible%';
  detail := 'rejected=' || v_rejected::text
            || ' msg_excerpt=' || COALESCE(left(v_rejected_msg, 120),'NULL'); RETURN NEXT;

  -- R5 — lineage
  SELECT count(*) INTO v_lineage_count FROM public.rule_evaluation_lineage(v_r1_rule_id);
  SELECT row_to_json(t)::jsonb INTO v_lineage_sample
    FROM (
      SELECT * FROM public.rule_evaluation_lineage(v_r1_rule_id)
       WHERE target_kind = 'obligation' AND consequence_status = 'emitted'
       LIMIT 1
    ) t;
  step := 'D15.R5.lineage_returns_obligation';
  ok := v_lineage_count >= 1
        AND v_lineage_sample IS NOT NULL
        AND (v_lineage_sample->>'target_kind') = 'obligation'
        AND (v_lineage_sample->>'target_id') = v_peer_obl_id::text
        AND COALESCE(v_lineage_sample->>'target_label','') <> '';
  detail := 'lineage_rows=' || v_lineage_count
            || ' sample_target_kind=' || COALESCE(v_lineage_sample->>'target_kind','NULL')
            || ' sample_target_id=' || COALESCE(v_lineage_sample->>'target_id','NULL')
            || ' label=' || COALESCE(v_lineage_sample->>'target_label','NULL'); RETURN NEXT;

  step := 'D15.cleanup'; ok := true;
  detail := 'skipped (append-only tables; data persists)'; RETURN NEXT;
  RETURN;
END;
$body$;
