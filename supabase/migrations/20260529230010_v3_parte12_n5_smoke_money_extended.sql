-- PARTE 12 — N.5 ampliada: cubre reverse_transaction guard + happy + custom split
-- breakdown + emit_mandate_expiring_events idempotent.
--
-- Cobertura:
--   - 0a Precheck: hot-fix emit_mandate_expiring_events apunta a status='active'.
--   - N.5.5a record_expense (con obligations) → reverse_transaction RAISE
--     (dependent obligation guard "use domain-specific reversal").
--   - N.5.5b record_contribution (sin obligations) → reverse_transaction OK
--     + reversed_entry_id link + money.transaction_reversed event.
--   - N.5.6 custom split_breakdown: amounts custom respetan jsonb (no even).
--     Observación: payer participante NO recibe self-obligation (correcto).
--   - N.5.9 emit_mandate_expiring_events idempotent: 1st call >=1, 2nd call =0,
--     total events_after_2x = 1.

CREATE OR REPLACE FUNCTION public._smoke_money_extended()
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
  v_hotfix_applied boolean;
  v_tx_expense   uuid;
  v_reverse_blocked boolean := false;
  v_tx_contrib   uuid;
  v_tx_reverse   uuid;
  v_reverse_link uuid;
  v_reverse_event int;
  v_tx_custom    uuid;
  v_obl_a_amount numeric;
  v_obl_b_amount numeric;
  v_mandate_id   uuid;
  v_emit_first   int;
  v_emit_second  int;
  v_event_count_after int;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  SELECT (prosrc LIKE '%status      = ''active''%') INTO v_hotfix_applied
  FROM pg_proc WHERE proname='emit_mandate_expiring_events';
  step := '0a.emit_mandate_expiring_hotfix_applied'; ok := COALESCE(v_hotfix_applied, false);
  detail := 'src_references_active=' || COALESCE(v_hotfix_applied::text,'NULL'); RETURN NEXT;

  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke MX A'), (v_user_b, 'Smoke MX B')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_id := public.create_group('Smoke MX ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a FROM public.group_memberships gm
   WHERE gm.group_id = v_group_id AND gm.user_id = v_user_a;

  SELECT im.invite_id, im.code INTO v_invite_b_id, v_invite_b_code
    FROM public.invite_member(v_group_id, 'smoke-mx-b@test', NULL, 'member', NULL) im;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  SELECT ai.membership_id INTO v_membership_b FROM public.accept_invite(v_invite_b_code) ai;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_tx_expense := public.record_expense(
    v_group_id, NULL, 100, 'MXN', v_membership_a, 'smoke mx exp', 'even',
    jsonb_build_array(
      jsonb_build_object('membership_id', v_membership_a),
      jsonb_build_object('membership_id', v_membership_b)
    ),
    false, NULL, 'smoke-mx-exp-' || substr(v_user_a::text,1,8)
  );
  BEGIN
    PERFORM public.reverse_transaction(v_tx_expense, 'smoke attempt');
  EXCEPTION WHEN OTHERS THEN
    v_reverse_blocked := true;
  END;
  step := 'N.5.5a.reverse_with_dependent_obligations_blocked'; ok := v_reverse_blocked;
  detail := 'blocked=' || v_reverse_blocked::text; RETURN NEXT;

  v_tx_contrib := public.record_contribution(
    v_group_id, NULL, 200, 'MXN', v_membership_a, 'smoke mx contrib',
    false, NULL, 'smoke-mx-con-' || substr(v_user_a::text,1,8)
  );
  v_tx_reverse := public.reverse_transaction(v_tx_contrib, 'smoke mx reverse');
  SELECT reversed_entry_id INTO v_reverse_link
    FROM public.group_resource_transactions WHERE id = v_tx_reverse;
  SELECT count(*) INTO v_reverse_event FROM public.group_events ge
   WHERE ge.group_id = v_group_id AND ge.event_type = 'money.transaction_reversed'
     AND ge.entity_id = v_tx_contrib;
  step := 'N.5.5b.reverse_contribution_links_and_emits';
  ok := v_tx_reverse IS NOT NULL AND v_reverse_link = v_tx_contrib AND v_reverse_event >= 1;
  detail := 'reverse_id=' || COALESCE(v_tx_reverse::text,'NULL')
            || ' link_matches=' || (v_reverse_link = v_tx_contrib)::text
            || ' events=' || v_reverse_event; RETURN NEXT;

  v_tx_custom := public.record_expense(
    v_group_id, NULL, 100, 'MXN', v_membership_a, 'smoke mx custom', 'custom',
    jsonb_build_array(
      jsonb_build_object('membership_id', v_membership_a, 'amount', 70),
      jsonb_build_object('membership_id', v_membership_b, 'amount', 30)
    ),
    false, NULL, 'smoke-mx-custom-' || substr(v_user_a::text,1,8)
  );
  SELECT amount_original INTO v_obl_a_amount FROM public.group_obligations
   WHERE source_transaction_id = v_tx_custom AND owed_by_membership_id = v_membership_a;
  SELECT amount_original INTO v_obl_b_amount FROM public.group_obligations
   WHERE source_transaction_id = v_tx_custom AND owed_by_membership_id = v_membership_b;
  step := 'N.5.6.custom_split_obligation_amounts_match';
  ok := v_obl_b_amount = 30;
  detail := 'obl_a_amount=' || COALESCE(v_obl_a_amount::text,'NULL')
            || ' obl_b_amount=' || COALESCE(v_obl_b_amount::text,'NULL'); RETURN NEXT;

  v_mandate_id := public.grant_mandate(
    v_group_id, v_membership_b, 'spend', 'group', NULL,
    jsonb_build_object('amount_max', 500, 'unit', 'MXN'),
    now() + interval '12 hours', NULL
  );
  v_emit_first  := public.emit_mandate_expiring_events();
  v_emit_second := public.emit_mandate_expiring_events();
  SELECT count(*) INTO v_event_count_after FROM public.group_events ge
   WHERE ge.group_id = v_group_id AND ge.event_type = 'mandate.expiring_in_24h'
     AND ge.entity_id = v_mandate_id;
  step := 'N.5.9.mandate_expiring_idempotent';
  ok := v_emit_first >= 1 AND v_emit_second = 0 AND v_event_count_after = 1;
  detail := 'first=' || v_emit_first || ' second=' || v_emit_second
            || ' events_after_2x=' || v_event_count_after; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_money_extended() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_money_extended() TO service_role;
