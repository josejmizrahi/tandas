-- PARTE 12 — N.6 fix2: resolution_method 'mediated' NO está en whitelist.
-- Allowed: conversation | mediation | vote | admin_decision | arbitration | separation | other.

CREATE OR REPLACE FUNCTION public._smoke_disputes()
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
  v_no_mutation_present int;
  v_no_delete_present int;
  v_dispute_id   uuid;
  v_dispute_2_id uuid;
  v_open_event   int;
  v_dispute_event_id uuid;
  v_event_row_count int;
  v_event_added_event int;
  v_mediator_after uuid;
  v_decision_id  uuid;
  v_escalated_status text;
  v_escalated_decision_id uuid;
  v_escalated_event int;
  v_resolved_status text;
  v_resolved_at_set boolean;
  v_resolved_event int;
  v_update_blocked boolean := false;
  v_delete_blocked boolean := false;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  SELECT count(*) FILTER (WHERE p.proname='atom_no_mutation_guard'),
         count(*) FILTER (WHERE p.proname='atom_no_delete_guard')
    INTO v_no_mutation_present, v_no_delete_present
  FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
  WHERE t.tgrelid='public.group_dispute_events'::regclass AND NOT t.tgisinternal;
  step := '0a.dispute_events_atom_guards';
  ok := v_no_mutation_present >= 1 AND v_no_delete_present >= 1;
  detail := 'no_mutation=' || v_no_mutation_present || ' no_delete=' || v_no_delete_present; RETURN NEXT;

  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke Disp A'), (v_user_b, 'Smoke Disp B')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_id := public.create_group('Smoke Disp ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a FROM public.group_memberships gm
   WHERE gm.group_id = v_group_id AND gm.user_id = v_user_a;

  SELECT im.invite_id, im.code INTO v_invite_b_id, v_invite_b_code
    FROM public.invite_member(v_group_id, 'smoke-disp-b@test', NULL, 'member', NULL) im;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  SELECT ai.membership_id INTO v_membership_b FROM public.accept_invite(v_invite_b_code) ai;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_dispute_id := public.open_dispute(
    v_group_id, 'other', NULL, 'Smoke dispute 1', 'desc', v_membership_b
  );
  SELECT count(*) INTO v_open_event FROM public.group_events ge
   WHERE ge.group_id = v_group_id AND ge.event_type = 'dispute.opened' AND ge.entity_id = v_dispute_id;
  step := 'N.6.1.open_dispute_row_and_event';
  ok := v_dispute_id IS NOT NULL
        AND (SELECT status FROM public.group_disputes WHERE id = v_dispute_id) = 'open'
        AND v_open_event >= 1;
  detail := 'dispute_id=' || COALESCE(v_dispute_id::text,'NULL') || ' opened_events=' || v_open_event; RETURN NEXT;

  v_dispute_event_id := public.append_dispute_event(
    v_dispute_id, 'comment', 'smoke append', jsonb_build_object('by','A')
  );
  SELECT count(*) INTO v_event_row_count FROM public.group_dispute_events
   WHERE id = v_dispute_event_id;
  SELECT count(*) INTO v_event_added_event FROM public.group_events ge
   WHERE ge.group_id = v_group_id AND ge.event_type = 'dispute.event_added' AND ge.entity_id = v_dispute_id;
  step := 'N.6.2.append_dispute_event_row_and_canonical_event';
  ok := v_event_row_count = 1 AND v_event_added_event >= 1;
  detail := 'rows=' || v_event_row_count || ' canonical_event=' || v_event_added_event; RETURN NEXT;

  PERFORM public.assign_mediator(v_dispute_id, v_membership_a);
  SELECT mediator_membership_id INTO v_mediator_after FROM public.group_disputes WHERE id = v_dispute_id;
  step := 'N.6.3.assign_mediator_mutates'; ok := v_mediator_after = v_membership_a;
  detail := 'mediator=' || COALESCE(v_mediator_after::text,'NULL'); RETURN NEXT;

  v_decision_id := public.escalate_dispute_to_vote(
    v_dispute_id, 'Smoke escalation vote', 'majority', now() + interval '7 days'
  );
  SELECT status, escalated_decision_id INTO v_escalated_status, v_escalated_decision_id
    FROM public.group_disputes WHERE id = v_dispute_id;
  SELECT count(*) INTO v_escalated_event FROM public.group_events ge
   WHERE ge.group_id = v_group_id AND ge.event_type = 'dispute.escalated' AND ge.entity_id = v_dispute_id;
  step := 'N.6.4.escalate_status_decision_event';
  ok := v_escalated_status = 'escalated'
        AND v_escalated_decision_id = v_decision_id
        AND v_escalated_event >= 1;
  detail := 'status=' || COALESCE(v_escalated_status,'NULL')
            || ' decision_id_match=' || (v_escalated_decision_id = v_decision_id)::text
            || ' escalated_events=' || v_escalated_event; RETURN NEXT;

  v_dispute_2_id := public.open_dispute(
    v_group_id, 'other', NULL, 'Smoke dispute 2', 'desc', v_membership_b
  );
  PERFORM public.record_dispute_resolution(
    v_dispute_2_id, 'mediation', 'resolved by mediation', jsonb_build_object('agreement','ok')
  );
  SELECT status, (resolved_at IS NOT NULL) INTO v_resolved_status, v_resolved_at_set
    FROM public.group_disputes WHERE id = v_dispute_2_id;
  SELECT count(*) INTO v_resolved_event FROM public.group_events ge
   WHERE ge.group_id = v_group_id AND ge.event_type = 'dispute.resolved' AND ge.entity_id = v_dispute_2_id;
  step := 'N.6.5.resolve_status_and_event';
  ok := v_resolved_status = 'resolved' AND v_resolved_at_set AND v_resolved_event >= 1;
  detail := 'status=' || COALESCE(v_resolved_status,'NULL')
            || ' resolved_at_set=' || v_resolved_at_set::text
            || ' resolved_events=' || v_resolved_event; RETURN NEXT;

  BEGIN
    UPDATE public.group_dispute_events SET body = 'tampered' WHERE id = v_dispute_event_id;
  EXCEPTION WHEN OTHERS THEN
    v_update_blocked := true;
  END;
  step := 'N.6.6.update_dispute_event_blocked'; ok := v_update_blocked;
  detail := 'blocked=' || v_update_blocked::text; RETURN NEXT;

  BEGIN
    DELETE FROM public.group_dispute_events WHERE id = v_dispute_event_id;
  EXCEPTION WHEN OTHERS THEN
    v_delete_blocked := true;
  END;
  step := 'N.6.7.delete_dispute_event_blocked'; ok := v_delete_blocked;
  detail := 'blocked=' || v_delete_blocked::text; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_disputes() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_disputes() TO service_role;
