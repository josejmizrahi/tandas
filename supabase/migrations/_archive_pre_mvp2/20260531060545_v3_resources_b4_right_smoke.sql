CREATE OR REPLACE FUNCTION public._smoke_resources_b4_right()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_outsider uuid := gen_random_uuid();
  v_group_x      uuid;
  v_invite_b_id  uuid;
  v_invite_b_code text;
  v_user_b       uuid := gen_random_uuid();
  v_membership_a_x uuid;
  v_membership_b_x uuid;

  v_right        uuid;
  v_right_xfer   uuid;
  v_event_uuid   uuid;
  v_event_uuid2  uuid;
  v_holder       uuid;
  v_revoked      timestamptz;
  v_expired      timestamptz;

  v_xfer_blocked        boolean := false;
  v_double_revoke_blocked boolean := false;
  v_double_expire_blocked boolean := false;
  v_premature_expire_blocked boolean := false;
  v_outsider_blocked    boolean := false;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b), (v_user_outsider);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke B4 A'),
    (v_user_b, 'Smoke B4 B'),
    (v_user_outsider, 'Smoke B4 Out')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_x := public.create_group('Smoke B4 X ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a_x FROM public.group_memberships gm
   WHERE gm.group_id = v_group_x AND gm.user_id = v_user_a;

  SELECT im.invite_id, im.code INTO v_invite_b_id, v_invite_b_code
    FROM public.invite_member(v_group_x, 'smoke-b4-b@test', NULL, 'member', NULL) im;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  SELECT ai.membership_id INTO v_membership_b_x FROM public.accept_invite(v_invite_b_code) ai;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);

  -- Two right resources: one non-transferable, one transferable.
  v_right := (public.create_group_resource(
    v_group_x, 'right', 'Smoke B4 Right NT',
    'No transferable', 'members', 'group', NULL, NULL)).id;
  v_right_xfer := (public.create_group_resource(
    v_group_x, 'right', 'Smoke B4 Right T',
    'Transferable', 'members', 'group', NULL, NULL)).id;

  -- B4.1: grant_right happy.
  v_event_uuid := public.grant_right(v_right, v_membership_a_x, 'access', NULL, NULL, false, 'smoke grant', 'cid-g-1');
  SELECT holder_membership_id INTO v_holder FROM public.group_resource_rights WHERE resource_id = v_right;
  step := 'B4.1.grant_happy';
  ok := v_event_uuid IS NOT NULL AND v_holder = v_membership_a_x;
  detail := 'holder_match=' || (v_holder = v_membership_a_x)::text; RETURN NEXT;

  -- B4.2: grant idempotent.
  v_event_uuid2 := public.grant_right(v_right, v_membership_a_x, 'access', NULL, NULL, false, 'smoke grant', 'cid-g-1');
  step := 'B4.2.grant_idempotent';
  ok := v_event_uuid2 = v_event_uuid;
  detail := 'same=' || (v_event_uuid2 = v_event_uuid)::text; RETURN NEXT;

  -- B4.3: transfer_right blocked when transferable=false.
  BEGIN
    PERFORM public.transfer_right(v_right, v_membership_b_x, 'illegal', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_xfer_blocked := true;
  END;
  step := 'B4.3.transfer_non_transferable_blocked'; ok := v_xfer_blocked;
  detail := 'blocked=' || v_xfer_blocked::text; RETURN NEXT;

  -- B4.4: transfer_right happy (on transferable right).
  PERFORM public.grant_right(v_right_xfer, v_membership_a_x, 'access', NULL, NULL, true, 'grant t', 'cid-gt-1');
  v_event_uuid := public.transfer_right(v_right_xfer, v_membership_b_x, 'smoke xfer', 'cid-x-1');
  SELECT holder_membership_id INTO v_holder FROM public.group_resource_rights WHERE resource_id = v_right_xfer;
  step := 'B4.4.transfer_happy';
  ok := v_event_uuid IS NOT NULL AND v_holder = v_membership_b_x;
  detail := 'new_holder_match=' || (v_holder = v_membership_b_x)::text; RETURN NEXT;

  -- B4.5: revoke_right happy.
  v_event_uuid := public.revoke_right(v_right, 'smoke revoke', 'cid-r-1');
  SELECT revoked_at INTO v_revoked FROM public.group_resource_rights WHERE resource_id = v_right;
  step := 'B4.5.revoke_happy';
  ok := v_event_uuid IS NOT NULL AND v_revoked IS NOT NULL;
  detail := 'revoked_set=' || (v_revoked IS NOT NULL)::text; RETURN NEXT;

  -- B4.6: double revoke blocked.
  BEGIN
    PERFORM public.revoke_right(v_right, 'smoke revoke 2', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_double_revoke_blocked := true;
  END;
  step := 'B4.6.double_revoke_blocked'; ok := v_double_revoke_blocked;
  detail := 'blocked=' || v_double_revoke_blocked::text; RETURN NEXT;

  -- B4.7: expire_right blocked before expires_at.
  BEGIN
    PERFORM public.expire_right(v_right_xfer, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_premature_expire_blocked := true;
  END;
  step := 'B4.7.premature_expire_blocked'; ok := v_premature_expire_blocked;
  detail := 'blocked=' || v_premature_expire_blocked::text; RETURN NEXT;

  -- B4.8: set past expires_at + expire_right happy.
  UPDATE public.group_resource_rights
     SET expires_at = now() - interval '1 minute'
   WHERE resource_id = v_right_xfer;
  v_event_uuid := public.expire_right(v_right_xfer, 'cid-e-1');
  SELECT expired_at INTO v_expired FROM public.group_resource_rights WHERE resource_id = v_right_xfer;
  step := 'B4.8.expire_happy';
  ok := v_event_uuid IS NOT NULL AND v_expired IS NOT NULL;
  detail := 'expired_set=' || (v_expired IS NOT NULL)::text; RETURN NEXT;

  -- B4.9: double expire blocked.
  BEGIN
    PERFORM public.expire_right(v_right_xfer, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_double_expire_blocked := true;
  END;
  step := 'B4.9.double_expire_blocked'; ok := v_double_expire_blocked;
  detail := 'blocked=' || v_double_expire_blocked::text; RETURN NEXT;

  -- B4.10: outsider cannot grant.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_outsider::text)::text, true);
  BEGIN
    PERFORM public.grant_right(v_right, v_membership_a_x, 'access', NULL, NULL, false, 'evil', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_outsider_blocked := true;
  END;
  step := 'B4.10.grant_outsider_blocked'; ok := v_outsider_blocked;
  detail := 'blocked=' || v_outsider_blocked::text; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$$;

REVOKE ALL ON FUNCTION public._smoke_resources_b4_right() FROM public, anon;
GRANT EXECUTE ON FUNCTION public._smoke_resources_b4_right() TO authenticated;
