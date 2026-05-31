-- PARTE 12 — N.2 fix: 'expelled' no es valid membership state. Canonical = 'banned'.
-- Allowed: active | suspended | left | banned | requested | invited.

CREATE OR REPLACE FUNCTION public._smoke_groups_boundary()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_user_c       uuid := gen_random_uuid();
  v_group_id     uuid;
  v_invite_b_id  uuid;
  v_invite_b_code text;
  v_invite_c_id  uuid;
  v_invite_c_code text;
  v_membership_a uuid;
  v_membership_b uuid;
  v_membership_c uuid;
  v_n_created   int;
  v_n_invited   int;
  v_n_joined    int;
  v_settings    jsonb;
  v_boundary_event int;
  v_invalid_blocked boolean := false;
  v_state_after text;
  v_state_event int;
  v_leave_blocked boolean := false;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b), (v_user_c);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke Bnd A'), (v_user_b, 'Smoke Bnd B'), (v_user_c, 'Smoke Bnd C')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_id := public.create_group('Smoke Bnd ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a FROM public.group_memberships gm
   WHERE gm.group_id = v_group_id AND gm.user_id = v_user_a AND gm.status = 'active';
  SELECT count(*) INTO v_n_created FROM public.group_events ge
   WHERE ge.group_id = v_group_id AND ge.event_type = 'group.created';
  step := 'N.2.1.create_group_founder_active_and_event'; ok := v_membership_a IS NOT NULL AND v_n_created >= 1;
  detail := 'membership_a=' || COALESCE(v_membership_a::text, 'NULL') || ' group_created=' || v_n_created; RETURN NEXT;

  SELECT im.invite_id, im.code INTO v_invite_b_id, v_invite_b_code
    FROM public.invite_member(v_group_id, 'smoke-bnd-b@test', NULL, 'member', NULL) im;
  SELECT count(*) INTO v_n_invited FROM public.group_events ge
   WHERE ge.group_id = v_group_id AND ge.event_type = 'member.invited';
  step := 'N.2.2.invite_creates_row_and_event'; ok := v_invite_b_id IS NOT NULL AND v_n_invited >= 1;
  detail := 'invite_b=' || COALESCE(v_invite_b_id::text, 'NULL') || ' invited_events=' || v_n_invited; RETURN NEXT;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  SELECT ai.membership_id INTO v_membership_b FROM public.accept_invite(v_invite_b_code) ai;
  SELECT count(*) INTO v_n_joined FROM public.group_events ge
   WHERE ge.group_id = v_group_id AND ge.event_type = 'member.joined';
  step := 'N.2.3.accept_creates_active_and_event';
  ok := v_membership_b IS NOT NULL
        AND v_n_joined >= 1
        AND (SELECT status FROM public.group_memberships WHERE id = v_membership_b) = 'active';
  detail := 'membership_b=' || COALESCE(v_membership_b::text, 'NULL') || ' joined_events=' || v_n_joined; RETURN NEXT;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  PERFORM public.set_group_boundary_policy(
    v_group_id, 'invite_only', 'admins_only', false, 'free', 'smoke policy'
  );
  SELECT settings INTO v_settings FROM public.groups WHERE id = v_group_id;
  SELECT count(*) INTO v_boundary_event FROM public.group_events ge
   WHERE ge.group_id = v_group_id AND ge.event_type = 'boundary_policy.updated';
  step := 'N.2.4.boundary_policy_set_and_event';
  ok := (v_settings #>> '{boundary_policy,entry_mode}') = 'invite_only'
        AND (v_settings #>> '{boundary_policy,who_can_invite}') = 'admins_only'
        AND v_boundary_event >= 1;
  detail := 'entry_mode=' || COALESCE(v_settings #>> '{boundary_policy,entry_mode}', 'NULL')
            || ' boundary_events=' || v_boundary_event; RETURN NEXT;

  BEGIN
    PERFORM public.set_group_boundary_policy(v_group_id, 'wide_open', 'any_member', false, 'free', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_invalid_blocked := true;
  END;
  step := 'N.2.5.invalid_entry_mode_blocked'; ok := v_invalid_blocked;
  detail := 'blocked=' || v_invalid_blocked::text; RETURN NEXT;

  -- Setup C
  SELECT im.invite_id, im.code INTO v_invite_c_id, v_invite_c_code
    FROM public.invite_member(v_group_id, 'smoke-bnd-c@test', NULL, 'member', NULL) im;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_c::text)::text, true);
  SELECT ai.membership_id INTO v_membership_c FROM public.accept_invite(v_invite_c_code) ai;

  -- N.2.6: admin path set_membership_state banned (canonical) → status='banned' + event.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  PERFORM public.set_membership_state(v_membership_b, 'banned', 'smoke banned reason', NULL);
  SELECT status INTO v_state_after FROM public.group_memberships WHERE id = v_membership_b;
  SELECT count(*) INTO v_state_event FROM public.group_events ge
   WHERE ge.group_id = v_group_id AND ge.event_type = 'member.state_changed'
     AND ge.entity_id = v_membership_b;
  step := 'N.2.6.set_membership_state_banned_event';
  ok := v_state_after = 'banned' AND v_state_event >= 1;
  detail := 'status=' || COALESCE(v_state_after, 'NULL') || ' state_events=' || v_state_event; RETURN NEXT;

  -- N.2.7: leave_group con balance != 0 bloqueado (PARTE 5b).
  PERFORM public.record_expense(
    p_group_id              => v_group_id,
    p_resource_id           => NULL,
    p_amount                => 100,
    p_unit                  => 'MXN',
    p_paid_by_membership_id => v_membership_a,
    p_description           => 'Smoke bnd expense',
    p_split_mode            => 'even',
    p_split_breakdown       => jsonb_build_array(
                                  jsonb_build_object('membership_id', v_membership_a),
                                  jsonb_build_object('membership_id', v_membership_c)
                                ),
    p_in_kind               => false,
    p_mandate_id            => NULL,
    p_client_id             => 'smoke-bnd-exp-' || substr(v_user_a::text,1,8)
  );
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_c::text)::text, true);
  BEGIN
    PERFORM public.leave_group(v_group_id, 'smoke leave with balance');
  EXCEPTION WHEN OTHERS THEN
    v_leave_blocked := true;
  END;
  step := 'N.2.7.leave_group_with_balance_blocked'; ok := v_leave_blocked;
  detail := 'blocked=' || v_leave_blocked::text; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_groups_boundary() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_groups_boundary() TO service_role;
