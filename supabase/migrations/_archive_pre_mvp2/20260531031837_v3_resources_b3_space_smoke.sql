CREATE OR REPLACE FUNCTION public._smoke_resources_b3_space()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_outsider uuid := gen_random_uuid();
  v_group_x      uuid;
  v_membership_a_x uuid;

  v_space        uuid;
  v_booking_1    uuid;
  v_booking_2    uuid;
  v_cancel_id    uuid;
  v_count        int;

  v_starts1      timestamptz := now() + interval '7 days';
  v_ends1        timestamptz := now() + interval '7 days' + interval '2 hours';
  v_starts2      timestamptz := now() + interval '7 days' + interval '1 hour'; -- overlaps
  v_ends2        timestamptz := now() + interval '7 days' + interval '3 hours';
  v_starts3      timestamptz := now() + interval '8 days';
  v_ends3        timestamptz := now() + interval '8 days' + interval '1 hour';

  v_overlap_blocked   boolean := false;
  v_invalid_window_blocked boolean := false;
  v_outsider_blocked  boolean := false;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_outsider);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke B3 A'),
    (v_user_outsider, 'Smoke B3 Out')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_x := public.create_group('Smoke B3 X ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a_x FROM public.group_memberships gm
   WHERE gm.group_id = v_group_x AND gm.user_id = v_user_a;

  v_space := (public.create_group_resource(
    v_group_x, 'space', 'Smoke B3 Space',
    'Sala compartida', 'members', 'group', NULL, NULL)).id;

  -- B3.1: book_resource happy path.
  v_booking_1 := public.book_resource(v_space, v_starts1, v_ends1, 'smoke booking 1', 'cid-book-1');
  step := 'B3.1.book_happy';
  ok := v_booking_1 IS NOT NULL;
  detail := 'booking_id=' || COALESCE(v_booking_1::text, 'NULL'); RETURN NEXT;

  -- B3.2: idempotent.
  v_booking_2 := public.book_resource(v_space, v_starts1, v_ends1, 'smoke booking 1', 'cid-book-1');
  step := 'B3.2.book_idempotent_client_id';
  ok := v_booking_2 = v_booking_1;
  detail := 'same=' || (v_booking_2 = v_booking_1)::text; RETURN NEXT;

  -- B3.3: overlap blocked.
  BEGIN
    PERFORM public.book_resource(v_space, v_starts2, v_ends2, 'evil overlap', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_overlap_blocked := true;
  END;
  step := 'B3.3.overlap_blocked'; ok := v_overlap_blocked;
  detail := 'blocked=' || v_overlap_blocked::text; RETURN NEXT;

  -- B3.4: ends_at <= starts_at blocked.
  BEGIN
    PERFORM public.book_resource(v_space, v_starts3, v_starts3, 'invalid window', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_invalid_window_blocked := true;
  END;
  step := 'B3.4.invalid_window_blocked'; ok := v_invalid_window_blocked;
  detail := 'blocked=' || v_invalid_window_blocked::text; RETURN NEXT;

  -- B3.5: non-overlapping booking accepted.
  v_booking_2 := public.book_resource(v_space, v_starts3, v_ends3, 'smoke booking 3', 'cid-book-3');
  step := 'B3.5.non_overlap_accepted';
  ok := v_booking_2 IS NOT NULL AND v_booking_2 <> v_booking_1;
  detail := 'booking_id=' || COALESCE(v_booking_2::text, 'NULL'); RETURN NEXT;

  -- B3.6: list_bookings_for_resource returns both.
  SELECT count(*) INTO v_count
    FROM public.list_bookings_for_resource(v_space, NULL, NULL, 50);
  step := 'B3.6.list_returns_both';
  ok := v_count >= 2;
  detail := 'count=' || v_count; RETURN NEXT;

  -- B3.7: filter by p_starts_after returns only later booking.
  SELECT count(*) INTO v_count
    FROM public.list_bookings_for_resource(v_space, v_starts3 - interval '1 minute', NULL, 50);
  step := 'B3.7.list_filter_starts_after';
  ok := v_count = 1;
  detail := 'count=' || v_count; RETURN NEXT;

  -- B3.8: cancel_booking happy path.
  v_cancel_id := public.cancel_booking(v_booking_1, 'smoke cancel');
  step := 'B3.8.cancel_happy';
  ok := v_cancel_id IS NOT NULL AND v_cancel_id <> v_booking_1;
  detail := 'cancel_id=' || COALESCE(v_cancel_id::text, 'NULL'); RETURN NEXT;

  -- B3.9: after cancel, a new booking on the original window is allowed.
  DECLARE v_re uuid; BEGIN
    v_re := public.book_resource(v_space, v_starts1, v_ends1, 'replay after cancel', NULL);
    step := 'B3.9.rebook_after_cancel_allowed';
    ok := v_re IS NOT NULL;
    detail := 'booking_id=' || COALESCE(v_re::text, 'NULL'); RETURN NEXT;
  EXCEPTION WHEN OTHERS THEN
    step := 'B3.9.rebook_after_cancel_allowed';
    ok := false;
    detail := 'unexpected error: ' || SQLERRM; RETURN NEXT;
  END;

  -- B3.10: outsider cannot list.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_outsider::text)::text, true);
  BEGIN
    PERFORM count(*) FROM public.list_bookings_for_resource(v_space, NULL, NULL, 50);
  EXCEPTION WHEN OTHERS THEN
    v_outsider_blocked := true;
  END;
  step := 'B3.10.list_outsider_blocked'; ok := v_outsider_blocked;
  detail := 'blocked=' || v_outsider_blocked::text; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$$;

REVOKE ALL ON FUNCTION public._smoke_resources_b3_space() FROM public, anon;
GRANT EXECUTE ON FUNCTION public._smoke_resources_b3_space() TO authenticated;
