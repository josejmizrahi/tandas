-- PARTE 12 — N.4 fix: drifts vs spec:
--   - group_rule_evaluations usa `rule_version_id` (no `rule_id`).
--   - notifications_outbox.category emitida por engine = 'rule_consequence'.

CREATE OR REPLACE FUNCTION public._smoke_rules_engine()
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
  v_catalog_count int;
  v_validation   jsonb;
  v_validation_unknown jsonb;
  v_rule_id      uuid;
  v_version_id   uuid;
  v_rule_created_event int;
  v_active_version_count int;
  v_tx_high      uuid;
  v_tx_low       uuid;
  v_eval_high_matched int;
  v_eval_low_audit int;
  v_outbox_high  int;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  SELECT count(*) INTO v_catalog_count FROM public.rule_shapes_catalog
   WHERE shape_key IN ('trigger.money.expense_recorded','condition.amount_above','consequence.send_notification');
  step := '0a.catalog_has_3_shapes'; ok := v_catalog_count = 3;
  detail := 'shapes_found=' || v_catalog_count; RETURN NEXT;

  v_validation := public.validate_rule_shape(jsonb_build_object(
    'shape_key', 'trigger.money.expense_recorded',
    'condition_tree', jsonb_build_object(
      'kind', 'condition.amount_above',
      'fields', jsonb_build_object('amount', 50, 'currency', 'MXN')
    ),
    'consequences', jsonb_build_array(
      jsonb_build_object(
        'kind', 'consequence.send_notification',
        'fields', jsonb_build_object('message', 'Gasto sobre umbral', 'audience', 'admins')
      )
    )
  ));
  step := 'N.4.1.validate_rule_shape_happy'; ok := (v_validation->>'valid')::boolean = true;
  detail := 'valid=' || COALESCE(v_validation->>'valid', 'NULL')
            || ' errors=' || COALESCE(jsonb_array_length(v_validation->'errors'), 0)::text; RETURN NEXT;

  v_validation_unknown := public.validate_rule_shape(jsonb_build_object(
    'shape_key', 'trigger.unknown.bogus',
    'consequences', jsonb_build_array(
      jsonb_build_object('kind','consequence.send_notification','fields',jsonb_build_object('message','x'))
    )
  ));
  step := 'N.4.2.validate_rule_shape_unknown_invalid';
  ok := (v_validation_unknown->>'valid')::boolean = false;
  detail := 'valid=' || COALESCE(v_validation_unknown->>'valid','NULL'); RETURN NEXT;

  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke Eng A'), (v_user_b, 'Smoke Eng B')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_id := public.create_group('Smoke Eng ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a FROM public.group_memberships gm
   WHERE gm.group_id = v_group_id AND gm.user_id = v_user_a;

  SELECT im.invite_id, im.code INTO v_invite_b_id, v_invite_b_code
    FROM public.invite_member(v_group_id, 'smoke-eng-b@test', NULL, 'member', NULL) im;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  SELECT ai.membership_id INTO v_membership_b FROM public.accept_invite(v_invite_b_code) ai;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  SELECT cer.rule_id, cer.version_id INTO v_rule_id, v_version_id
    FROM public.create_engine_rule(
      v_group_id,
      'Smoke rule: notify on big expenses',
      'trigger.money.expense_recorded',
      jsonb_build_object(
        'kind', 'condition.amount_above',
        'fields', jsonb_build_object('amount', 50, 'currency', 'MXN')
      ),
      jsonb_build_array(
        jsonb_build_object(
          'kind', 'consequence.send_notification',
          'fields', jsonb_build_object('message', 'Gasto sobre umbral', 'audience', 'admins')
        )
      ),
      'norm', 1
    ) cer;
  SELECT count(*) INTO v_active_version_count FROM public.group_rule_versions
   WHERE rule_id = v_rule_id AND id = v_version_id;
  SELECT count(*) INTO v_rule_created_event FROM public.group_events ge
   WHERE ge.group_id = v_group_id AND ge.event_type = 'rule.created' AND ge.entity_id = v_rule_id;
  step := 'N.4.3.create_engine_rule_activates_version_and_event';
  ok := v_rule_id IS NOT NULL AND v_version_id IS NOT NULL
        AND v_active_version_count = 1 AND v_rule_created_event >= 1;
  detail := 'rule_id=' || COALESCE(v_rule_id::text,'NULL')
            || ' versions=' || v_active_version_count
            || ' rule_created_events=' || v_rule_created_event; RETURN NEXT;

  v_tx_high := public.record_expense(
    p_group_id              => v_group_id,
    p_resource_id           => NULL,
    p_amount                => 100,
    p_unit                  => 'MXN',
    p_paid_by_membership_id => v_membership_a,
    p_description           => 'Smoke eng high',
    p_split_mode            => 'even',
    p_split_breakdown       => jsonb_build_array(
                                  jsonb_build_object('membership_id', v_membership_a),
                                  jsonb_build_object('membership_id', v_membership_b)
                                ),
    p_in_kind               => false,
    p_mandate_id            => NULL,
    p_client_id             => 'smoke-eng-high-' || substr(v_user_a::text,1,8)
  );
  SELECT count(*) INTO v_eval_high_matched FROM public.group_rule_evaluations gre
   WHERE gre.group_id = v_group_id
     AND gre.rule_version_id = v_version_id
     AND gre.matched = true;
  SELECT count(*) INTO v_outbox_high FROM public.notifications_outbox no_
   WHERE no_.group_id = v_group_id AND no_.category = 'rule_consequence';
  step := 'N.4.4.expense_above_threshold_matched_and_outbox';
  ok := v_eval_high_matched >= 1 AND v_outbox_high >= 1;
  detail := 'matched_evals=' || v_eval_high_matched || ' outbox_rule_consequence=' || v_outbox_high; RETURN NEXT;

  v_tx_low := public.record_expense(
    p_group_id              => v_group_id,
    p_resource_id           => NULL,
    p_amount                => 40,
    p_unit                  => 'MXN',
    p_paid_by_membership_id => v_membership_a,
    p_description           => 'Smoke eng low',
    p_split_mode            => 'even',
    p_split_breakdown       => jsonb_build_array(
                                  jsonb_build_object('membership_id', v_membership_a),
                                  jsonb_build_object('membership_id', v_membership_b)
                                ),
    p_in_kind               => false,
    p_mandate_id            => NULL,
    p_client_id             => 'smoke-eng-low-' || substr(v_user_a::text,1,8)
  );
  SELECT count(*) INTO v_eval_low_audit FROM public.group_rule_evaluations gre
   WHERE gre.group_id = v_group_id
     AND gre.rule_version_id = v_version_id
     AND gre.matched = false;
  step := 'N.4.5.expense_below_threshold_audit_only';
  ok := v_eval_low_audit >= 1;
  detail := 'audit_evals=' || v_eval_low_audit; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_rules_engine() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_rules_engine() TO service_role;
