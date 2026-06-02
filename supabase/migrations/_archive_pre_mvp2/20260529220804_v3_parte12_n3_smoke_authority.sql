-- PARTE 12 — N.3 Authority + mandates smoke.
--
-- Cobertura:
--   - assert_permission positive (founder) y negative (outsider).
--   - grant_mandate happy path + event.
--   - grant_mandate validation: ends_at en pasado → raises.
--   - revoke_mandate → status='revoked' + event.
--   - "cannot revoke last role" guard.
--   - Mandate cross-group guard via record_expense con mandate de otro grupo.

CREATE OR REPLACE FUNCTION public._smoke_authority()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_user_outsider uuid := gen_random_uuid();
  v_group_x      uuid;
  v_group_y      uuid;
  v_invite_b_id  uuid;
  v_invite_b_code text;
  v_membership_a_x uuid;
  v_membership_b_x uuid;
  v_membership_a_y uuid;
  v_assert_positive_ok boolean := true;
  v_assert_outsider_blocked boolean := false;
  v_mandate_id   uuid;
  v_mandate_event int;
  v_invalid_endsat_blocked boolean := false;
  v_mandate_status text;
  v_mandate_revoked_event int;
  v_last_role_blocked boolean := false;
  v_founder_role_id uuid;
  v_cross_group_blocked boolean := false;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b), (v_user_outsider);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke Auth A'),
    (v_user_b, 'Smoke Auth B'),
    (v_user_outsider, 'Smoke Auth Out')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  -- Setup: A crea group_x, invita a B, B acepta. A crea group_y (solo).
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_x := public.create_group('Smoke Auth X ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a_x FROM public.group_memberships gm
   WHERE gm.group_id = v_group_x AND gm.user_id = v_user_a;

  SELECT im.invite_id, im.code INTO v_invite_b_id, v_invite_b_code
    FROM public.invite_member(v_group_x, 'smoke-auth-b@test', NULL, 'member', NULL) im;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  SELECT ai.membership_id INTO v_membership_b_x FROM public.accept_invite(v_invite_b_code) ai;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_y := public.create_group('Smoke Auth Y ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a_y FROM public.group_memberships gm
   WHERE gm.group_id = v_group_y AND gm.user_id = v_user_a;

  -- N.3.1: founder asserts 'decisions.create' → no raise.
  BEGIN
    PERFORM public.assert_permission(v_group_x, 'decisions.create');
  EXCEPTION WHEN OTHERS THEN
    v_assert_positive_ok := false;
  END;
  step := 'N.3.1.assert_permission_positive'; ok := v_assert_positive_ok;
  detail := 'no_raise=' || v_assert_positive_ok::text; RETURN NEXT;

  -- N.3.2: outsider asserts permission → raises 42501.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_outsider::text)::text, true);
  BEGIN
    PERFORM public.assert_permission(v_group_x, 'group.update');
  EXCEPTION WHEN OTHERS THEN
    v_assert_outsider_blocked := true;
  END;
  step := 'N.3.2.assert_permission_outsider_blocked'; ok := v_assert_outsider_blocked;
  detail := 'blocked=' || v_assert_outsider_blocked::text; RETURN NEXT;

  -- N.3.3: founder grant_mandate to B → returns id + emits mandate.granted.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_mandate_id := public.grant_mandate(
    v_group_x, v_membership_b_x, 'spend', 'group', NULL,
    jsonb_build_object('amount_max', 500, 'unit', 'MXN'),
    now() + interval '7 days', NULL
  );
  SELECT count(*) INTO v_mandate_event FROM public.group_events ge
   WHERE ge.group_id = v_group_x AND ge.event_type = 'mandate.granted' AND ge.entity_id = v_mandate_id;
  step := 'N.3.3.grant_mandate_returns_id_and_event';
  ok := v_mandate_id IS NOT NULL AND v_mandate_event >= 1;
  detail := 'mandate_id=' || COALESCE(v_mandate_id::text, 'NULL') || ' mandate_granted_events=' || v_mandate_event; RETURN NEXT;

  -- N.3.4: grant_mandate con ends_at en pasado → raises 22023.
  BEGIN
    PERFORM public.grant_mandate(
      v_group_x, v_membership_b_x, 'spend', 'group', NULL,
      jsonb_build_object('amount_max', 100), now() - interval '1 day', NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_invalid_endsat_blocked := true;
  END;
  step := 'N.3.4.grant_mandate_past_endsat_blocked'; ok := v_invalid_endsat_blocked;
  detail := 'blocked=' || v_invalid_endsat_blocked::text; RETURN NEXT;

  -- N.3.5: revoke_mandate → status='revoked' + event.
  PERFORM public.revoke_mandate(v_mandate_id, 'smoke revoke');
  SELECT status INTO v_mandate_status FROM public.group_mandates WHERE id = v_mandate_id;
  SELECT count(*) INTO v_mandate_revoked_event FROM public.group_events ge
   WHERE ge.group_id = v_group_x AND ge.event_type = 'mandate.revoked' AND ge.entity_id = v_mandate_id;
  step := 'N.3.5.revoke_mandate_status_and_event';
  ok := v_mandate_status = 'revoked' AND v_mandate_revoked_event >= 1;
  detail := 'status=' || COALESCE(v_mandate_status, 'NULL') || ' revoked_events=' || v_mandate_revoked_event; RETURN NEXT;

  -- N.3.6: cannot revoke last role from member.
  --   Founder tiene solo el rol founder por default. Revocarlo → raises "cannot revoke last role".
  SELECT role_id INTO v_founder_role_id FROM public.group_member_roles
   WHERE membership_id = v_membership_a_x LIMIT 1;
  BEGIN
    PERFORM public.revoke_role_from_member(v_membership_a_x, v_founder_role_id);
  EXCEPTION WHEN OTHERS THEN
    v_last_role_blocked := true;
  END;
  step := 'N.3.6.revoke_last_role_blocked'; ok := v_last_role_blocked;
  detail := 'blocked=' || v_last_role_blocked::text; RETURN NEXT;

  -- N.3.7: cross-group mandate use bloqueado.
  --   Grant NUEVO mandato a B en group_x (el anterior está revoked).
  --   Intentar usar ese mandate_id en record_expense de group_y → guard raises.
  v_mandate_id := public.grant_mandate(
    v_group_x, v_membership_b_x, 'spend', 'group', NULL,
    jsonb_build_object('amount_max', 1000, 'unit', 'MXN'),
    now() + interval '7 days', NULL
  );
  -- A es active en group_y. Intenta record_expense en group_y con mandate de group_x.
  BEGIN
    PERFORM public.record_expense(
      p_group_id              => v_group_y,
      p_resource_id           => NULL,
      p_amount                => 100,
      p_unit                  => 'MXN',
      p_paid_by_membership_id => v_membership_a_y,
      p_description           => 'cross-group mandate attempt',
      p_split_mode            => 'even',
      p_split_breakdown       => jsonb_build_array(
                                    jsonb_build_object('membership_id', v_membership_a_y)
                                  ),
      p_in_kind               => false,
      p_mandate_id            => v_mandate_id,
      p_client_id             => 'smoke-cross-group-' || substr(v_user_a::text,1,8)
    );
  EXCEPTION WHEN OTHERS THEN
    v_cross_group_blocked := true;
  END;
  step := 'N.3.7.cross_group_mandate_blocked'; ok := v_cross_group_blocked;
  detail := 'blocked=' || v_cross_group_blocked::text; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_authority() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_authority() TO service_role;
