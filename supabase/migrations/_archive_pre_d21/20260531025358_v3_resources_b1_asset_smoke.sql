-- Smoke for Asset Fase B.1: CHECK + assign/release/condition + permission gates.

CREATE OR REPLACE FUNCTION public._smoke_resources_b1_asset()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_user_outsider uuid := gen_random_uuid();
  v_group_x      uuid;
  v_invite_b_id  uuid;
  v_invite_b_code text;
  v_membership_a_x uuid;
  v_membership_b_x uuid;

  v_asset       uuid;
  v_invalid_cond_blocked boolean := false;
  v_check_constraint_blocked boolean := false;
  v_outsider_blocked  boolean := false;
  v_release_empty_blocked boolean := false;

  v_assigned_pre  int;
  v_assigned_post int;
  v_returned_pre  int;
  v_returned_post int;
  v_damaged_pre   int;
  v_damaged_post  int;
  v_repaired_pre  int;
  v_repaired_post int;
  v_status_pre    int;
  v_status_post   int;
  v_idemp_post    int;

  v_cond          text;
  v_custodian     uuid;
  v_event_uuid    uuid;
  v_event_uuid2   uuid;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  -- Setup users + group + 2 memberships.
  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b), (v_user_outsider);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke B1 A'),
    (v_user_b, 'Smoke B1 B'),
    (v_user_outsider, 'Smoke B1 Out')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_x := public.create_group('Smoke B1 X ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a_x FROM public.group_memberships gm
   WHERE gm.group_id = v_group_x AND gm.user_id = v_user_a;

  SELECT im.invite_id, im.code INTO v_invite_b_id, v_invite_b_code
    FROM public.invite_member(v_group_x, 'smoke-b1-b@test', NULL, 'member', NULL) im;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  SELECT ai.membership_id INTO v_membership_b_x FROM public.accept_invite(v_invite_b_code) ai;

  -- Create asset.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_asset := (public.create_group_resource(
    v_group_x, 'asset', 'Smoke B1 Asset',
    'Asset to test custody', 'members', 'group', NULL, NULL)).id;

  -- B1.1: CHECK rejects invalid condition via direct INSERT.
  BEGIN
    INSERT INTO public.group_resource_assets (resource_id, condition)
    VALUES (v_asset, 'garbage');
  EXCEPTION WHEN OTHERS THEN
    v_check_constraint_blocked := true;
  END;
  step := 'B1.1.check_rejects_invalid_condition'; ok := v_check_constraint_blocked;
  detail := 'blocked=' || v_check_constraint_blocked::text; RETURN NEXT;

  -- B1.2: mark_asset_condition rejects invalid string.
  BEGIN
    PERFORM public.mark_asset_condition(v_asset, 'garbage', 'smoke', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_invalid_cond_blocked := true;
  END;
  step := 'B1.2.mark_condition_rejects_invalid'; ok := v_invalid_cond_blocked;
  detail := 'blocked=' || v_invalid_cond_blocked::text; RETURN NEXT;

  -- B1.3: assign_asset_custodian happy path.
  SELECT count(*) INTO v_assigned_pre FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.assigned' AND entity_id = v_asset;
  v_event_uuid := public.assign_asset_custodian(v_asset, v_membership_b_x, 'smoke assign', 'cid-assign-1');
  SELECT custodian_membership_id INTO v_custodian FROM public.group_resource_assets WHERE resource_id = v_asset;
  SELECT count(*) INTO v_assigned_post FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.assigned' AND entity_id = v_asset;
  step := 'B1.3.assign_custodian_happy';
  ok := v_event_uuid IS NOT NULL
        AND v_custodian = v_membership_b_x
        AND v_assigned_post = v_assigned_pre + 1;
  detail := 'event=' || COALESCE(v_event_uuid::text, 'NULL')
         || ' custodian_match=' || (v_custodian = v_membership_b_x)::text
         || ' delta=' || (v_assigned_post - v_assigned_pre); RETURN NEXT;

  -- B1.4: idempotent — replay returns same event uuid, no extra event row.
  v_event_uuid2 := public.assign_asset_custodian(v_asset, v_membership_b_x, 'smoke assign', 'cid-assign-1');
  SELECT count(*) INTO v_idemp_post FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.assigned' AND entity_id = v_asset;
  step := 'B1.4.assign_idempotent_client_id';
  ok := v_event_uuid2 = v_event_uuid AND v_idemp_post = v_assigned_post;
  detail := 'same_event=' || (v_event_uuid2 = v_event_uuid)::text
         || ' count_unchanged=' || (v_idemp_post = v_assigned_post)::text; RETURN NEXT;

  -- B1.5: release_asset_custodian happy path.
  SELECT count(*) INTO v_returned_pre FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.returned' AND entity_id = v_asset;
  v_event_uuid := public.release_asset_custodian(v_asset, 'smoke release', 'cid-release-1');
  SELECT custodian_membership_id INTO v_custodian FROM public.group_resource_assets WHERE resource_id = v_asset;
  SELECT count(*) INTO v_returned_post FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.returned' AND entity_id = v_asset;
  step := 'B1.5.release_custodian_happy';
  ok := v_event_uuid IS NOT NULL
        AND v_custodian IS NULL
        AND v_returned_post = v_returned_pre + 1;
  detail := 'event=' || COALESCE(v_event_uuid::text, 'NULL')
         || ' custodian_null=' || (v_custodian IS NULL)::text
         || ' delta=' || (v_returned_post - v_returned_pre); RETURN NEXT;

  -- B1.6: release without custodian fails 22023.
  BEGIN
    PERFORM public.release_asset_custodian(v_asset, 'smoke release again', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_release_empty_blocked := true;
  END;
  step := 'B1.6.release_without_custodian_blocked'; ok := v_release_empty_blocked;
  detail := 'blocked=' || v_release_empty_blocked::text; RETURN NEXT;

  -- B1.7: mark_asset_condition 'damaged' -> resource.damaged.
  SELECT count(*) INTO v_damaged_pre FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.damaged' AND entity_id = v_asset;
  v_event_uuid := public.mark_asset_condition(v_asset, 'damaged', 'smoke damaged', 'cid-cond-1');
  SELECT condition INTO v_cond FROM public.group_resource_assets WHERE resource_id = v_asset;
  SELECT count(*) INTO v_damaged_post FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.damaged' AND entity_id = v_asset;
  step := 'B1.7.mark_damaged_emits_damaged';
  ok := v_event_uuid IS NOT NULL
        AND v_cond = 'damaged'
        AND v_damaged_post = v_damaged_pre + 1;
  detail := 'cond=' || COALESCE(v_cond, 'NULL')
         || ' delta=' || (v_damaged_post - v_damaged_pre); RETURN NEXT;

  -- B1.8: mark_asset_condition 'repaired' after damaged -> resource.repaired.
  SELECT count(*) INTO v_repaired_pre FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.repaired' AND entity_id = v_asset;
  v_event_uuid := public.mark_asset_condition(v_asset, 'repaired', 'smoke repaired', 'cid-cond-2');
  SELECT condition INTO v_cond FROM public.group_resource_assets WHERE resource_id = v_asset;
  SELECT count(*) INTO v_repaired_post FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.repaired' AND entity_id = v_asset;
  step := 'B1.8.mark_repaired_from_damaged_emits_repaired';
  ok := v_event_uuid IS NOT NULL
        AND v_cond = 'repaired'
        AND v_repaired_post = v_repaired_pre + 1;
  detail := 'cond=' || COALESCE(v_cond, 'NULL')
         || ' delta=' || (v_repaired_post - v_repaired_pre); RETURN NEXT;

  -- B1.9: mark_asset_condition 'good' from 'repaired' -> resource.status_changed.
  SELECT count(*) INTO v_status_pre FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.status_changed' AND entity_id = v_asset;
  v_event_uuid := public.mark_asset_condition(v_asset, 'good', 'smoke good', 'cid-cond-3');
  SELECT count(*) INTO v_status_post FROM public.group_events
   WHERE group_id = v_group_x AND event_type = 'resource.status_changed' AND entity_id = v_asset;
  step := 'B1.9.mark_other_emits_status_changed';
  ok := v_event_uuid IS NOT NULL
        AND v_status_post = v_status_pre + 1;
  detail := 'delta=' || (v_status_post - v_status_pre); RETURN NEXT;

  -- B1.10: outsider cannot assign_asset_custodian.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_outsider::text)::text, true);
  BEGIN
    PERFORM public.assign_asset_custodian(v_asset, v_membership_a_x, 'evil', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_outsider_blocked := true;
  END;
  step := 'B1.10.assign_outsider_blocked'; ok := v_outsider_blocked;
  detail := 'blocked=' || v_outsider_blocked::text; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$$;

REVOKE ALL ON FUNCTION public._smoke_resources_b1_asset() FROM public, anon;
GRANT EXECUTE ON FUNCTION public._smoke_resources_b1_asset() TO authenticated;
