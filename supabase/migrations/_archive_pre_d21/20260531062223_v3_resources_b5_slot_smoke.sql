CREATE OR REPLACE FUNCTION public._smoke_resources_b5_slot()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_outsider uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_invite_b_code text;
  v_invite_b_id  uuid;
  v_group_x      uuid;
  v_membership_a_x uuid;
  v_membership_b_x uuid;

  v_slot         uuid;
  v_slot_expired uuid;
  v_event        uuid;
  v_event2       uuid;
  v_assignee     uuid;
  v_released     timestamptz;
  v_expired      timestamptz;

  v_release_empty_blocked boolean := false;
  v_premature_expire_blocked boolean := false;
  v_double_expire_blocked boolean := false;
  v_outsider_blocked boolean := false;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b), (v_user_outsider);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke B5 A'),
    (v_user_b, 'Smoke B5 B'),
    (v_user_outsider, 'Smoke B5 Out')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_x := public.create_group('Smoke B5 X ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a_x FROM public.group_memberships gm
   WHERE gm.group_id = v_group_x AND gm.user_id = v_user_a;

  SELECT im.invite_id, im.code INTO v_invite_b_id, v_invite_b_code
    FROM public.invite_member(v_group_x, 'smoke-b5-b@test', NULL, 'member', NULL) im;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  SELECT ai.membership_id INTO v_membership_b_x FROM public.accept_invite(v_invite_b_code) ai;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);

  v_slot := (public.create_group_resource(
    v_group_x, 'slot', 'Smoke B5 Slot',
    'Turno', 'members', 'group', NULL, NULL)).id;
  v_slot_expired := (public.create_group_resource(
    v_group_x, 'slot', 'Smoke B5 Slot Expired',
    'Turno con fecha', 'members', 'group', NULL, NULL)).id;

  v_event := public.assign_slot(v_slot, v_membership_a_x, 'smoke assign', 'cid-as-1');
  SELECT assigned_membership_id INTO v_assignee FROM public.group_resource_slots WHERE resource_id = v_slot;
  step := 'B5.1.assign_happy';
  ok := v_event IS NOT NULL AND v_assignee = v_membership_a_x;
  detail := 'match=' || (v_assignee = v_membership_a_x)::text; RETURN NEXT;

  v_event2 := public.assign_slot(v_slot, v_membership_a_x, 'smoke assign', 'cid-as-1');
  step := 'B5.2.assign_idempotent'; ok := v_event2 = v_event;
  detail := 'same=' || (v_event2 = v_event)::text; RETURN NEXT;

  v_event := public.assign_slot(v_slot, v_membership_b_x, 'reassign', 'cid-as-2');
  SELECT assigned_membership_id INTO v_assignee FROM public.group_resource_slots WHERE resource_id = v_slot;
  step := 'B5.3.reassign_happy';
  ok := v_event IS NOT NULL AND v_assignee = v_membership_b_x;
  detail := 'new=' || (v_assignee = v_membership_b_x)::text; RETURN NEXT;

  v_event := public.release_slot(v_slot, 'smoke release', 'cid-rel-1');
  SELECT assigned_membership_id, released_at INTO v_assignee, v_released
    FROM public.group_resource_slots WHERE resource_id = v_slot;
  step := 'B5.4.release_happy';
  ok := v_event IS NOT NULL AND v_assignee IS NULL AND v_released IS NOT NULL;
  detail := 'assignee_null=' || (v_assignee IS NULL)::text
         || ' released_set=' || (v_released IS NOT NULL)::text; RETURN NEXT;

  BEGIN
    PERFORM public.release_slot(v_slot, NULL, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_release_empty_blocked := true;
  END;
  step := 'B5.5.release_without_assignee_blocked'; ok := v_release_empty_blocked;
  detail := 'blocked=' || v_release_empty_blocked::text; RETURN NEXT;

  BEGIN
    PERFORM public.expire_slot(v_slot_expired, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_premature_expire_blocked := true;
  END;
  step := 'B5.6.premature_expire_blocked'; ok := v_premature_expire_blocked;
  detail := 'blocked=' || v_premature_expire_blocked::text; RETURN NEXT;

  PERFORM public.assign_slot(v_slot_expired, v_membership_a_x, 'smoke', NULL);
  UPDATE public.group_resource_slots
     SET slot_ends_at = now() - interval '1 minute'
   WHERE resource_id = v_slot_expired;
  v_event := public.expire_slot(v_slot_expired, 'cid-exp-1');
  SELECT expired_at INTO v_expired FROM public.group_resource_slots WHERE resource_id = v_slot_expired;
  step := 'B5.7.expire_happy';
  ok := v_event IS NOT NULL AND v_expired IS NOT NULL;
  detail := 'expired_set=' || (v_expired IS NOT NULL)::text; RETURN NEXT;

  BEGIN
    PERFORM public.expire_slot(v_slot_expired, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_double_expire_blocked := true;
  END;
  step := 'B5.8.double_expire_blocked'; ok := v_double_expire_blocked;
  detail := 'blocked=' || v_double_expire_blocked::text; RETURN NEXT;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_outsider::text)::text, true);
  BEGIN
    PERFORM public.assign_slot(v_slot, v_membership_a_x, 'evil', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_outsider_blocked := true;
  END;
  step := 'B5.9.assign_outsider_blocked'; ok := v_outsider_blocked;
  detail := 'blocked=' || v_outsider_blocked::text; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$$;

REVOKE ALL ON FUNCTION public._smoke_resources_b5_slot() FROM public, anon;
GRANT EXECUTE ON FUNCTION public._smoke_resources_b5_slot() TO authenticated;
