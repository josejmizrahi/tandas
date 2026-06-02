-- V3 PARTE 13 (smoke): _smoke_resources() — 18 assertions sobre el
-- nuevo surface area (CHECK ampliado, 2 permissions, 3 RPCs).
CREATE OR REPLACE FUNCTION public._smoke_resources()
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

  v_res_vehicle   uuid;
  v_res_tool      uuid;
  v_res_realestate uuid;
  v_res_inventory  uuid;
  v_res_ip         uuid;
  v_res_y_vehicle  uuid;

  v_invalid_type_blocked boolean := false;
  v_archived_blocked     boolean := false;
  v_outsider_blocked     boolean := false;
  v_outsider_lifecycle_blocked boolean := false;
  v_invalid_lifecycle_blocked  boolean := false;
  v_cross_group_blocked  boolean := false;

  v_detail_rec record;
  v_created_event_cnt int;
  v_value_event_cnt int;
  v_lifecycle_event_cnt_pre int;
  v_lifecycle_event_cnt_post int;
  v_lifecycle_event_cnt_after_idemp int;
  v_archived_event_cnt int;
  v_metadata jsonb;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  -- Setup A, B, outsider + 2 groups
  INSERT INTO auth.users (id) VALUES (v_user_a), (v_user_b), (v_user_outsider);
  INSERT INTO public.profiles (id, display_name) VALUES
    (v_user_a, 'Smoke Res A'),
    (v_user_b, 'Smoke Res B'),
    (v_user_outsider, 'Smoke Res Out')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_x := public.create_group('Smoke Res X ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a_x FROM public.group_memberships gm
   WHERE gm.group_id = v_group_x AND gm.user_id = v_user_a;

  SELECT im.invite_id, im.code INTO v_invite_b_id, v_invite_b_code
    FROM public.invite_member(v_group_x, 'smoke-res-b@test', NULL, 'member', NULL) im;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  SELECT ai.membership_id INTO v_membership_b_x FROM public.accept_invite(v_invite_b_code) ai;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_y := public.create_group('Smoke Res Y ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a_y FROM public.group_memberships gm
   WHERE gm.group_id = v_group_y AND gm.user_id = v_user_a;

  -- N.13.1: create_group_resource accepts 'vehicle'
  v_res_vehicle := (public.create_group_resource(
    v_group_x, 'vehicle', 'Smoke Vehicle',
    'Pickup compartido', 'members', 'group', NULL, NULL)).id;
  step := 'N.13.1.create_vehicle'; ok := v_res_vehicle IS NOT NULL;
  detail := 'resource_id=' || COALESCE(v_res_vehicle::text, 'NULL'); RETURN NEXT;

  -- N.13.2: 'tool'
  v_res_tool := (public.create_group_resource(
    v_group_x, 'tool', 'Smoke Tool',
    'Taladro', 'members', 'group', NULL, NULL)).id;
  step := 'N.13.2.create_tool'; ok := v_res_tool IS NOT NULL;
  detail := 'resource_id=' || COALESCE(v_res_tool::text, 'NULL'); RETURN NEXT;

  -- N.13.3: 'real_estate'
  v_res_realestate := (public.create_group_resource(
    v_group_x, 'real_estate', 'Smoke Real Estate',
    'Casa', 'members', 'group', NULL, NULL)).id;
  step := 'N.13.3.create_real_estate'; ok := v_res_realestate IS NOT NULL;
  detail := 'resource_id=' || COALESCE(v_res_realestate::text, 'NULL'); RETURN NEXT;

  -- N.13.4: 'inventory'
  v_res_inventory := (public.create_group_resource(
    v_group_x, 'inventory', 'Smoke Inventory',
    NULL, 'members', 'group', NULL, NULL)).id;
  step := 'N.13.4.create_inventory'; ok := v_res_inventory IS NOT NULL;
  detail := 'resource_id=' || COALESCE(v_res_inventory::text, 'NULL'); RETURN NEXT;

  -- N.13.5: 'intellectual_property'
  v_res_ip := (public.create_group_resource(
    v_group_x, 'intellectual_property', 'Smoke IP',
    NULL, 'members', 'group', NULL, NULL)).id;
  step := 'N.13.5.create_intellectual_property'; ok := v_res_ip IS NOT NULL;
  detail := 'resource_id=' || COALESCE(v_res_ip::text, 'NULL'); RETURN NEXT;

  -- N.13.6: invalid type rejected
  BEGIN
    PERFORM public.create_group_resource(
      v_group_x, 'garbage_type', 'Smoke Bad',
      NULL, 'members', 'group', NULL, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_invalid_type_blocked := true;
  END;
  step := 'N.13.6.invalid_type_blocked'; ok := v_invalid_type_blocked;
  detail := 'blocked=' || v_invalid_type_blocked::text; RETURN NEXT;

  -- N.13.7: group_resource_detail returns row, subtype NULL for envelope-only type
  SELECT * INTO v_detail_rec FROM public.group_resource_detail(v_res_vehicle);
  step := 'N.13.7.detail_envelope_only';
  ok := v_detail_rec.id = v_res_vehicle
        AND v_detail_rec.resource_type = 'vehicle'
        AND v_detail_rec.subtype IS NULL;
  detail := 'id_match=' || (v_detail_rec.id = v_res_vehicle)::text
         || ' type=' || COALESCE(v_detail_rec.resource_type,'NULL')
         || ' subtype_null=' || (v_detail_rec.subtype IS NULL)::text; RETURN NEXT;

  -- N.13.8: resource.created event emitted on creation
  SELECT count(*) INTO v_created_event_cnt FROM public.group_events ge
   WHERE ge.group_id = v_group_x
     AND ge.event_type = 'resource.created'
     AND ge.entity_id = v_res_vehicle;
  step := 'N.13.8.resource_created_event_emitted';
  ok := v_created_event_cnt >= 1;
  detail := 'event_count=' || v_created_event_cnt; RETURN NEXT;

  -- N.13.9: update_resource_value on non-asset writes metadata.last_value + emits event
  PERFORM public.update_resource_value(v_res_vehicle, 250000.50, 'MXN', 'kbb');
  SELECT metadata INTO v_metadata FROM public.group_resources WHERE id = v_res_vehicle;
  SELECT count(*) INTO v_value_event_cnt FROM public.group_events ge
   WHERE ge.group_id = v_group_x
     AND ge.event_type = 'resource.value_updated'
     AND ge.entity_id = v_res_vehicle;
  step := 'N.13.9.update_value_non_asset_metadata_and_event';
  ok := v_metadata ? 'last_value'
        AND v_metadata->>'last_value' = '250000.50'
        AND v_metadata->>'last_value_unit' = 'MXN'
        AND v_metadata->>'last_value_basis' = 'kbb'
        AND v_value_event_cnt >= 1;
  detail := 'metadata=' || v_metadata::text || ' events=' || v_value_event_cnt; RETURN NEXT;

  -- N.13.10: outsider cannot update_resource_value
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_outsider::text)::text, true);
  BEGIN
    PERFORM public.update_resource_value(v_res_vehicle, 99, 'MXN', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_outsider_blocked := true;
  END;
  step := 'N.13.10.update_value_outsider_blocked'; ok := v_outsider_blocked;
  detail := 'blocked=' || v_outsider_blocked::text; RETURN NEXT;

  -- N.13.11: update_resource_value on archived resource blocked
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  PERFORM public.archive_resource(v_res_tool, 'smoke archive');
  BEGIN
    PERFORM public.update_resource_value(v_res_tool, 100, 'MXN', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_archived_blocked := true;
  END;
  step := 'N.13.11.update_value_archived_blocked'; ok := v_archived_blocked;
  detail := 'blocked=' || v_archived_blocked::text; RETURN NEXT;

  -- N.13.12: record_resource_lifecycle_event with valid type emits event
  SELECT count(*) INTO v_lifecycle_event_cnt_pre FROM public.group_events ge
   WHERE ge.group_id = v_group_x
     AND ge.event_type = 'resource.used'
     AND ge.entity_id = v_res_vehicle;
  PERFORM public.record_resource_lifecycle_event(
    v_res_vehicle, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a_x::text),
    'smoke-cid-used-1'
  );
  SELECT count(*) INTO v_lifecycle_event_cnt_post FROM public.group_events ge
   WHERE ge.group_id = v_group_x
     AND ge.event_type = 'resource.used'
     AND ge.entity_id = v_res_vehicle;
  step := 'N.13.12.lifecycle_event_emitted';
  ok := v_lifecycle_event_cnt_post = v_lifecycle_event_cnt_pre + 1;
  detail := 'pre=' || v_lifecycle_event_cnt_pre || ' post=' || v_lifecycle_event_cnt_post; RETURN NEXT;

  -- N.13.13: invalid lifecycle event type blocked
  BEGIN
    PERFORM public.record_resource_lifecycle_event(
      v_res_vehicle, 'resource.fake_type', '{}'::jsonb, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_invalid_lifecycle_blocked := true;
  END;
  step := 'N.13.13.lifecycle_invalid_type_blocked';
  ok := v_invalid_lifecycle_blocked;
  detail := 'blocked=' || v_invalid_lifecycle_blocked::text; RETURN NEXT;

  -- N.13.14: idempotent — second call same client_id is no-op
  PERFORM public.record_resource_lifecycle_event(
    v_res_vehicle, 'resource.used',
    jsonb_build_object('membership_id', v_membership_a_x::text),
    'smoke-cid-used-1'
  );
  SELECT count(*) INTO v_lifecycle_event_cnt_after_idemp FROM public.group_events ge
   WHERE ge.group_id = v_group_x
     AND ge.event_type = 'resource.used'
     AND ge.entity_id = v_res_vehicle;
  step := 'N.13.14.lifecycle_idempotent_client_id';
  ok := v_lifecycle_event_cnt_after_idemp = v_lifecycle_event_cnt_post;
  detail := 'after_idemp=' || v_lifecycle_event_cnt_after_idemp
         || ' expected=' || v_lifecycle_event_cnt_post; RETURN NEXT;

  -- N.13.15: outsider cannot record_resource_lifecycle_event
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_outsider::text)::text, true);
  BEGIN
    PERFORM public.record_resource_lifecycle_event(
      v_res_vehicle, 'resource.damaged', '{}'::jsonb, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_outsider_lifecycle_blocked := true;
  END;
  step := 'N.13.15.lifecycle_outsider_blocked';
  ok := v_outsider_lifecycle_blocked;
  detail := 'blocked=' || v_outsider_lifecycle_blocked::text; RETURN NEXT;

  -- N.13.16: cross-group — A creates res_y_vehicle in group_y;
  -- B (only member of group_x) cannot update_resource_value on res_y_vehicle.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_res_y_vehicle := (public.create_group_resource(
    v_group_y, 'vehicle', 'Smoke Vehicle Y',
    NULL, 'members', 'group', NULL, NULL)).id;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  BEGIN
    PERFORM public.update_resource_value(v_res_y_vehicle, 1000, 'MXN', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_cross_group_blocked := true;
  END;
  step := 'N.13.16.cross_group_update_value_blocked';
  ok := v_cross_group_blocked;
  detail := 'blocked=' || v_cross_group_blocked::text; RETURN NEXT;

  -- N.13.17: archive_resource still works on envelope-only type (real_estate)
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  PERFORM public.archive_resource(v_res_realestate, 'smoke archive realestate');
  step := 'N.13.17.archive_envelope_only_type_ok';
  ok := (SELECT status FROM public.group_resources WHERE id = v_res_realestate) = 'archived';
  detail := 'status=' || COALESCE(
    (SELECT status FROM public.group_resources WHERE id = v_res_realestate), 'NULL'); RETURN NEXT;

  -- N.13.18: resource.archived event emitted on archive
  SELECT count(*) INTO v_archived_event_cnt FROM public.group_events ge
   WHERE ge.group_id = v_group_x
     AND ge.event_type = 'resource.archived'
     AND ge.entity_id = v_res_realestate;
  step := 'N.13.18.resource_archived_event_emitted';
  ok := v_archived_event_cnt >= 1;
  detail := 'event_count=' || v_archived_event_cnt; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public._smoke_resources() FROM anon, public;
