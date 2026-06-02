-- V3 FASE D.16 — Mig E: smoke for kill switch, quota, summary, computed atoms, ext ops

BEGIN;

CREATE OR REPLACE FUNCTION public._smoke_rules_engine_d16()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $body$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_group_id     uuid;
  v_invite_code text;
  v_membership_a uuid;
  v_membership_b uuid;

  v_asset        public.group_resources%ROWTYPE;
  v_fund         public.group_resources%ROWTYPE;
  v_space        public.group_resources%ROWTYPE;

  -- T1
  v_rule_off_id uuid; v_rule_off_v uuid;
  v_matched_before int; v_matched_after int;
  v_evaluations_before int; v_evaluations_after int;

  -- T2
  v_rule_q_id uuid; v_rule_q_v uuid;
  v_quota_skip_count int;
  v_quota_matched_count int;

  -- T3
  v_summary jsonb;

  -- T4
  v_rule_bal_id uuid; v_rule_bal_v uuid;
  v_rule_book_id uuid; v_rule_book_v uuid;
  v_rule_use_id uuid; v_rule_use_v uuid;
  v_bal_matched int; v_book_matched int; v_use_matched int;

  -- T5
  v_rule_ct_id uuid; v_rule_ct_v uuid;
  v_rule_in_id uuid; v_rule_in_v uuid;
  v_rule_isnull_id uuid; v_rule_isnull_v uuid;
  v_rule_notnull_id uuid; v_rule_notnull_v uuid;
  v_ct_matched int; v_in_matched int; v_isnull_matched int; v_notnull_matched int;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 200 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke D16 A'), (v_user_b, 'Smoke D16 B')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_id := public.create_group('Smoke D16 ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a FROM public.group_memberships gm
   WHERE gm.group_id = v_group_id AND gm.user_id = v_user_a;
  SELECT (public.invite_member(v_group_id, 'smoke-d16-b@test', NULL, 'member', NULL)).code INTO v_invite_code;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  SELECT ai.membership_id INTO v_membership_b FROM public.accept_invite(v_invite_code) ai;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);

  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  v_asset := public.create_group_resource(v_group_id, 'asset', 'Smoke D16 Asset', NULL, 'members', 'group', NULL, v_membership_a);
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  v_fund  := public.create_group_resource(v_group_id, 'fund',  'Smoke D16 Fund',  NULL, 'members', 'group', NULL, NULL);
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  v_space := public.create_group_resource(v_group_id, 'space', 'Smoke D16 Space', NULL, 'members', 'group', NULL, NULL);

  step := 'D16.setup.resources_created';
  ok := v_asset.id IS NOT NULL AND v_fund.id IS NOT NULL AND v_space.id IS NOT NULL;
  detail := format('asset=%s fund=%s space=%s',
                   substr(v_asset.id::text,1,8), substr(v_fund.id::text,1,8), substr(v_space.id::text,1,8));
  RETURN NEXT;

  -- ==========================================================================
  -- T1 — KILL SWITCH
  --      Rule fires while engine_active=true. After flipping false, rule does
  --      NOT fire on a new event. Re-enable for subsequent tests.
  -- ==========================================================================
  SELECT cer.rule_id, cer.version_id INTO v_rule_off_id, v_rule_off_v
    FROM public.create_engine_rule(v_group_id,
      'D16 T1 — kill switch test',
      'trigger.resource.used', NULL,
      jsonb_build_array(jsonb_build_object('kind','consequence.send_notification',
        'fields', jsonb_build_object('message','x','audience','actor'))),
      'norm', 1) cer;

  -- First fire: engine_active=true (default). Should match.
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.record_resource_lifecycle_event(v_asset.id, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a::text), 'd16-t1-1');
  SELECT count(*) INTO v_matched_before FROM public.group_rule_evaluations
   WHERE rule_version_id = v_rule_off_v AND matched = true;

  -- Flip kill switch off
  UPDATE public.groups SET engine_active=false WHERE id = v_group_id;

  -- Second fire while engine_active=false. Should NOT match.
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.record_resource_lifecycle_event(v_asset.id, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a::text), 'd16-t1-2');
  SELECT count(*) INTO v_matched_after FROM public.group_rule_evaluations
   WHERE rule_version_id = v_rule_off_v AND matched = true;

  -- Re-enable engine for next tests
  UPDATE public.groups SET engine_active=true WHERE id = v_group_id;

  step := 'D16.T1.kill_switch';
  ok := v_matched_before >= 1 AND v_matched_after = v_matched_before;
  detail := 'matched_with_engine=' || v_matched_before
            || ' matched_after_kill=' || v_matched_after; RETURN NEXT;

  -- ==========================================================================
  -- T2 — QUOTA OVER LIMIT
  --      Set max_evals_per_window=2; fire 3 events; expect 3rd to be skipped
  --      with rule.engine_skipped(reason=rate_limited).
  -- ==========================================================================
  -- Make sure quota row exists then tighten limit
  INSERT INTO public.group_rule_engine_quotas (group_id, max_evals_per_window, window_seconds, current_window_count, current_window_started_at)
    VALUES (v_group_id, 2, 60, 0, now())
    ON CONFLICT (group_id) DO UPDATE SET
      max_evals_per_window = 2,
      window_seconds = 60,
      current_window_count = 0,
      current_window_started_at = now();

  SELECT cer.rule_id, cer.version_id INTO v_rule_q_id, v_rule_q_v
    FROM public.create_engine_rule(v_group_id,
      'D16 T2 — quota test',
      'trigger.resource.used', NULL,
      jsonb_build_array(jsonb_build_object('kind','consequence.send_notification',
        'fields', jsonb_build_object('message','q','audience','actor'))),
      'norm', 1) cer;

  -- Three fires. Each should attempt eval; only first 2 pass quota.
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.record_resource_lifecycle_event(v_asset.id, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a::text), 'd16-t2-1');
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.record_resource_lifecycle_event(v_asset.id, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a::text), 'd16-t2-2');
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.record_resource_lifecycle_event(v_asset.id, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a::text), 'd16-t2-3');

  SELECT count(*) INTO v_quota_matched_count FROM public.group_rule_evaluations
   WHERE rule_version_id = v_rule_q_v AND matched = true;
  SELECT count(*) INTO v_quota_skip_count FROM public.group_events
   WHERE group_id = v_group_id
     AND event_type = 'rule.engine_skipped'
     AND payload->>'reason' = 'rate_limited';

  step := 'D16.T2.quota_rate_limited';
  ok := v_quota_matched_count >= 2 AND v_quota_skip_count >= 1;
  detail := 'matched_q=' || v_quota_matched_count
            || ' rule_engine_skipped(rate_limited)=' || v_quota_skip_count; RETURN NEXT;

  -- Bump quota back up so subsequent tests don't trip
  UPDATE public.group_rule_engine_quotas
     SET max_evals_per_window = 1000,
         current_window_count = 0,
         current_window_started_at = now()
   WHERE group_id = v_group_id;

  -- ==========================================================================
  -- T3 — SUMMARY RETURNS
  -- ==========================================================================
  v_summary := public.rule_evaluation_summary(v_group_id);
  step := 'D16.T3.summary_coherent';
  ok := (v_summary->>'total_evaluations')::int >= 1
        AND (v_summary->>'matched_count')::int >= 1
        AND v_summary ? 'evaluations_by_trigger'
        AND v_summary ? 'actions_by_consequence_kind'
        AND v_summary ? 'engine_skipped_breakdown'
        AND v_summary ? 'top_failing_rules'
        AND (v_summary->'engine_skipped_breakdown')->>'rate_limited' IS NOT NULL
        AND (v_summary->>'engine_active')::boolean = true;
  detail := 'total=' || (v_summary->>'total_evaluations')
            || ' matched=' || (v_summary->>'matched_count')
            || ' emitted=' || (v_summary->>'emitted_actions_count')
            || ' skipped_rate_limited=' || COALESCE((v_summary->'engine_skipped_breakdown')->>'rate_limited','0'); RETURN NEXT;

  -- ==========================================================================
  -- T4 — COMPUTED ATOMS (balance / booking_count / usage_count_24h)
  -- ==========================================================================
  -- 4a: balance. Seed 3 transactions on fund: +500 contribution, -200 expense, +0 transfer.
  INSERT INTO public.group_resource_transactions (
    group_id, transaction_type, source_resource_id, amount, unit, occurred_at, recorded_by, in_kind, metadata)
  VALUES
    (v_group_id, 'contribution', v_fund.id, 500, 'MXN', now(), v_user_a, false, '{}'::jsonb),
    (v_group_id, 'expense',      v_fund.id, 200, 'MXN', now(), v_user_a, false, '{}'::jsonb),
    (v_group_id, 'transfer',     v_fund.id,  50, 'MXN', now(), v_user_a, false, '{}'::jsonb);
  -- Expected balance = 500 - 200 + 0 = 300

  SELECT cer.rule_id, cer.version_id INTO v_rule_bal_id, v_rule_bal_v
    FROM public.create_engine_rule(v_group_id,
      'D16 T4a — balance compare',
      'trigger.resource.used',
      jsonb_build_object('kind','condition.resource_compare',
        'fields', jsonb_build_object('atom','resource.balance','op','>','value','100')),
      jsonb_build_array(jsonb_build_object('kind','consequence.send_notification',
        'fields', jsonb_build_object('message','bal','audience','actor'))),
      'norm', 1) cer;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.record_resource_lifecycle_event(v_fund.id, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a::text), 'd16-t4a-1');
  SELECT count(*) INTO v_bal_matched FROM public.group_rule_evaluations
   WHERE rule_version_id = v_rule_bal_v AND matched = true;

  -- 4b: booking_count. Insert 1 booking on space.
  INSERT INTO public.group_resource_bookings (group_id, resource_id, booked_by_membership_id, starts_at, status)
    VALUES (v_group_id, v_space.id, v_membership_a, now(), 'confirmed');

  SELECT cer.rule_id, cer.version_id INTO v_rule_book_id, v_rule_book_v
    FROM public.create_engine_rule(v_group_id,
      'D16 T4b — booking_count compare',
      'trigger.resource.used',
      jsonb_build_object('kind','condition.resource_compare',
        'fields', jsonb_build_object('atom','resource.booking_count','op','>=','value','1')),
      jsonb_build_array(jsonb_build_object('kind','consequence.send_notification',
        'fields', jsonb_build_object('message','book','audience','actor'))),
      'norm', 1) cer;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.record_resource_lifecycle_event(v_space.id, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a::text), 'd16-t4b-1');
  SELECT count(*) INTO v_book_matched FROM public.group_rule_evaluations
   WHERE rule_version_id = v_rule_book_v AND matched = true;

  -- 4c: usage_count_24h.  Rule: usage_count_24h > 0. The first resource.used
  --      that fires this rule creates the event BEFORE the predicate runs;
  --      but our atom counts only PRIOR events (created_at < now()). Asset
  --      already has multiple resource.used from T1/T2, so count >= 0.
  --      To be safe, fire a fresh resource.used on the asset.
  SELECT cer.rule_id, cer.version_id INTO v_rule_use_id, v_rule_use_v
    FROM public.create_engine_rule(v_group_id,
      'D16 T4c — usage_count_24h compare',
      'trigger.resource.used',
      jsonb_build_object('kind','condition.resource_compare',
        'fields', jsonb_build_object('atom','resource.usage_count_24h','op','>=','value','1')),
      jsonb_build_array(jsonb_build_object('kind','consequence.send_notification',
        'fields', jsonb_build_object('message','use','audience','actor'))),
      'norm', 1) cer;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.record_resource_lifecycle_event(v_asset.id, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a::text), 'd16-t4c-1');
  SELECT count(*) INTO v_use_matched FROM public.group_rule_evaluations
   WHERE rule_version_id = v_rule_use_v AND matched = true;

  step := 'D16.T4.computed_atoms';
  ok := v_bal_matched >= 1 AND v_book_matched >= 1 AND v_use_matched >= 1;
  detail := 'balance=' || v_bal_matched
            || ' booking_count=' || v_book_matched
            || ' usage_24h=' || v_use_matched; RETURN NEXT;

  -- ==========================================================================
  -- T5 — EXTENDED OPERATORS (contains / in / is_null / is_not_null)
  -- ==========================================================================
  -- 5a: contains — resource.name contains 'Smoke'
  SELECT cer.rule_id, cer.version_id INTO v_rule_ct_id, v_rule_ct_v
    FROM public.create_engine_rule(v_group_id,
      'D16 T5a — contains',
      'trigger.resource.used',
      jsonb_build_object('kind','condition.resource_compare',
        'fields', jsonb_build_object('atom','resource.name','op','contains','value','Smoke')),
      jsonb_build_array(jsonb_build_object('kind','consequence.send_notification',
        'fields', jsonb_build_object('message','ct','audience','actor'))),
      'norm', 1) cer;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.record_resource_lifecycle_event(v_asset.id, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a::text), 'd16-t5a-1');
  SELECT count(*) INTO v_ct_matched FROM public.group_rule_evaluations
   WHERE rule_version_id = v_rule_ct_v AND matched = true;

  -- 5b: in — resource.type IN [asset, fund, vehicle]
  SELECT cer.rule_id, cer.version_id INTO v_rule_in_id, v_rule_in_v
    FROM public.create_engine_rule(v_group_id,
      'D16 T5b — in',
      'trigger.resource.used',
      jsonb_build_object('kind','condition.resource_compare',
        'fields', jsonb_build_object('atom','resource.type','op','in','value','asset,fund,vehicle')),
      jsonb_build_array(jsonb_build_object('kind','consequence.send_notification',
        'fields', jsonb_build_object('message','in','audience','actor'))),
      'norm', 1) cer;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.record_resource_lifecycle_event(v_asset.id, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a::text), 'd16-t5b-1');
  SELECT count(*) INTO v_in_matched FROM public.group_rule_evaluations
   WHERE rule_version_id = v_rule_in_v AND matched = true;

  -- 5c: is_null — resource.archived_at IS NULL (not archived yet)
  SELECT cer.rule_id, cer.version_id INTO v_rule_isnull_id, v_rule_isnull_v
    FROM public.create_engine_rule(v_group_id,
      'D16 T5c — is_null',
      'trigger.resource.used',
      jsonb_build_object('kind','condition.resource_compare',
        'fields', jsonb_build_object('atom','resource.archived_at','op','is_null')),
      jsonb_build_array(jsonb_build_object('kind','consequence.send_notification',
        'fields', jsonb_build_object('message','isnull','audience','actor'))),
      'norm', 1) cer;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.record_resource_lifecycle_event(v_asset.id, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a::text), 'd16-t5c-1');
  SELECT count(*) INTO v_isnull_matched FROM public.group_rule_evaluations
   WHERE rule_version_id = v_rule_isnull_v AND matched = true;

  -- 5d: is_not_null — resource.name IS NOT NULL (always true for canonical resources)
  SELECT cer.rule_id, cer.version_id INTO v_rule_notnull_id, v_rule_notnull_v
    FROM public.create_engine_rule(v_group_id,
      'D16 T5d — is_not_null',
      'trigger.resource.used',
      jsonb_build_object('kind','condition.resource_compare',
        'fields', jsonb_build_object('atom','resource.name','op','is_not_null')),
      jsonb_build_array(jsonb_build_object('kind','consequence.send_notification',
        'fields', jsonb_build_object('message','notnull','audience','actor'))),
      'norm', 1) cer;
  PERFORM set_config('ruul.rule_eval_depth', '0', true);
  PERFORM public.record_resource_lifecycle_event(v_asset.id, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a::text), 'd16-t5d-1');
  SELECT count(*) INTO v_notnull_matched FROM public.group_rule_evaluations
   WHERE rule_version_id = v_rule_notnull_v AND matched = true;

  step := 'D16.T5.extended_operators';
  ok := v_ct_matched >= 1 AND v_in_matched >= 1 AND v_isnull_matched >= 1 AND v_notnull_matched >= 1;
  detail := 'contains=' || v_ct_matched
            || ' in=' || v_in_matched
            || ' is_null=' || v_isnull_matched
            || ' is_not_null=' || v_notnull_matched; RETURN NEXT;

  step := 'D16.cleanup'; ok := true;
  detail := 'skipped (append-only tables; data persists)'; RETURN NEXT;
  RETURN;
END;
$body$;

COMMIT;
