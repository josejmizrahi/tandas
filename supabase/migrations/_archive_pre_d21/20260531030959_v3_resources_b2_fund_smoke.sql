-- Smoke for Fund Fase B.2: lock/unlock/set_threshold + permission gates.

CREATE OR REPLACE FUNCTION public._smoke_resources_b2_fund()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_outsider uuid := gen_random_uuid();
  v_group_x      uuid;
  v_membership_a_x uuid;

  v_fund         uuid;
  v_outsider_blocked boolean := false;
  v_unlock_unlocked_blocked boolean := false;
  v_neg_threshold_blocked boolean := false;

  v_status_pre   int;
  v_status_post  int;
  v_idemp_post   int;

  v_locked_at    timestamptz;
  v_threshold    numeric;
  v_currency     text;
  v_event_uuid   uuid;
  v_event_uuid2  uuid;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_outsider);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke B2 A'),
    (v_user_outsider, 'Smoke B2 Out')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_x := public.create_group('Smoke B2 X ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a_x FROM public.group_memberships gm
   WHERE gm.group_id = v_group_x AND gm.user_id = v_user_a;

  v_fund := (public.create_group_resource(
    v_group_x, 'fund', 'Smoke B2 Fund',
    'Fund to test lock/threshold', 'members', 'group', NULL, NULL)).id;

  -- B2.1: lock_fund happy path.
  SELECT count(*) INTO v_status_pre FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.status_changed' AND entity_id = v_fund
     AND payload->>'to' = 'locked';
  v_event_uuid := public.lock_fund(v_fund, 'smoke lock', 'cid-lock-1');
  SELECT locked_at INTO v_locked_at FROM public.group_resource_funds WHERE resource_id = v_fund;
  SELECT count(*) INTO v_status_post FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.status_changed' AND entity_id = v_fund
     AND payload->>'to' = 'locked';
  step := 'B2.1.lock_happy';
  ok := v_event_uuid IS NOT NULL
        AND v_locked_at IS NOT NULL
        AND v_status_post = v_status_pre + 1;
  detail := 'event=' || COALESCE(v_event_uuid::text, 'NULL')
         || ' locked_at_set=' || (v_locked_at IS NOT NULL)::text
         || ' delta=' || (v_status_post - v_status_pre); RETURN NEXT;

  -- B2.2: lock idempotent.
  v_event_uuid2 := public.lock_fund(v_fund, 'smoke lock', 'cid-lock-1');
  SELECT count(*) INTO v_idemp_post FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.status_changed' AND entity_id = v_fund
     AND payload->>'to' = 'locked';
  step := 'B2.2.lock_idempotent_client_id';
  ok := v_event_uuid2 = v_event_uuid AND v_idemp_post = v_status_post;
  detail := 'same_event=' || (v_event_uuid2 = v_event_uuid)::text
         || ' count_unchanged=' || (v_idemp_post = v_status_post)::text; RETURN NEXT;

  -- B2.3: unlock_fund happy path.
  v_event_uuid := public.unlock_fund(v_fund, 'smoke unlock', 'cid-unlock-1');
  SELECT locked_at INTO v_locked_at FROM public.group_resource_funds WHERE resource_id = v_fund;
  step := 'B2.3.unlock_happy';
  ok := v_event_uuid IS NOT NULL AND v_locked_at IS NULL;
  detail := 'event=' || COALESCE(v_event_uuid::text, 'NULL')
         || ' locked_at_null=' || (v_locked_at IS NULL)::text; RETURN NEXT;

  -- B2.4: unlock on already-unlocked fund fails 22023.
  BEGIN
    PERFORM public.unlock_fund(v_fund, 'smoke unlock again', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_unlock_unlocked_blocked := true;
  END;
  step := 'B2.4.unlock_when_unlocked_blocked'; ok := v_unlock_unlocked_blocked;
  detail := 'blocked=' || v_unlock_unlocked_blocked::text; RETURN NEXT;

  -- B2.5: set_fund_threshold happy path.
  v_event_uuid := public.set_fund_threshold(v_fund, 5000, 'MXN', 'smoke threshold', 'cid-thr-1');
  SELECT threshold_target, currency INTO v_threshold, v_currency
    FROM public.group_resource_funds WHERE resource_id = v_fund;
  step := 'B2.5.set_threshold_happy';
  ok := v_event_uuid IS NOT NULL
        AND v_threshold = 5000
        AND v_currency = 'MXN';
  detail := 'event=' || COALESCE(v_event_uuid::text, 'NULL')
         || ' threshold=' || COALESCE(v_threshold::text, 'NULL')
         || ' currency=' || COALESCE(v_currency, 'NULL'); RETURN NEXT;

  -- B2.6: threshold idempotent via client_id.
  SELECT count(*) INTO v_status_pre FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.status_changed' AND entity_id = v_fund
     AND payload->>'kind' = 'threshold_updated';
  v_event_uuid2 := public.set_fund_threshold(v_fund, 5000, 'MXN', 'smoke threshold', 'cid-thr-1');
  SELECT count(*) INTO v_status_post FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.status_changed' AND entity_id = v_fund
     AND payload->>'kind' = 'threshold_updated';
  step := 'B2.6.threshold_idempotent_client_id';
  ok := v_event_uuid2 = v_event_uuid AND v_status_post = v_status_pre;
  detail := 'same_event=' || (v_event_uuid2 = v_event_uuid)::text
         || ' count_unchanged=' || (v_status_post = v_status_pre)::text; RETURN NEXT;

  -- B2.7: negative threshold blocked.
  BEGIN
    PERFORM public.set_fund_threshold(v_fund, -10, 'MXN', 'evil', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_neg_threshold_blocked := true;
  END;
  step := 'B2.7.negative_threshold_blocked'; ok := v_neg_threshold_blocked;
  detail := 'blocked=' || v_neg_threshold_blocked::text; RETURN NEXT;

  -- B2.8: outsider cannot lock_fund.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_outsider::text)::text, true);
  BEGIN
    PERFORM public.lock_fund(v_fund, 'evil', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_outsider_blocked := true;
  END;
  step := 'B2.8.lock_outsider_blocked'; ok := v_outsider_blocked;
  detail := 'blocked=' || v_outsider_blocked::text; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$$;

REVOKE ALL ON FUNCTION public._smoke_resources_b2_fund() FROM public, anon;
GRANT EXECUTE ON FUNCTION public._smoke_resources_b2_fund() TO authenticated;
