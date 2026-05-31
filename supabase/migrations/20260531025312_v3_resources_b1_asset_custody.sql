-- Fase B.1: Asset custody + condition lifecycle.
-- Adds CHECK on condition + 3 RPCs (assign/release custodian, mark condition).

-- 1. CHECK constraint on condition.
ALTER TABLE public.group_resource_assets
  ADD CONSTRAINT group_resource_assets_condition_check
  CHECK (condition IS NULL OR condition IN ('good','used','damaged','repaired','retired'));

-- 2. assign_asset_custodian
CREATE OR REPLACE FUNCTION public.assign_asset_custodian(
  p_resource_id uuid,
  p_membership_id uuid,
  p_reason text DEFAULT NULL,
  p_client_id text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid          uuid := auth.uid();
  v_r            public.group_resources%ROWTYPE;
  v_member_group uuid;
  v_prev         uuid;
  v_dup          uuid;
  v_event        uuid;
  v_payload      jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id;
  IF v_r.id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = '22023';
  END IF;
  IF v_r.resource_type <> 'asset' THEN
    RAISE EXCEPTION 'resource is not an asset' USING errcode = '22023';
  END IF;
  IF v_r.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'resource is archived' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update');

  SELECT group_id INTO v_member_group
    FROM public.group_memberships WHERE id = p_membership_id;
  IF v_member_group IS NULL THEN
    RAISE EXCEPTION 'membership not found' USING errcode = '22023';
  END IF;
  IF v_member_group <> v_r.group_id THEN
    RAISE EXCEPTION 'membership not in resource group' USING errcode = '22023';
  END IF;

  -- Idempotency: replays with same client_id return prior event.
  IF p_client_id IS NOT NULL THEN
    SELECT ge.uuid_id INTO v_dup
      FROM public.group_events ge
     WHERE ge.group_id = v_r.group_id
       AND ge.event_type = 'resource.assigned'
       AND ge.entity_id = p_resource_id
       AND ge.payload->>'client_id' = p_client_id
       AND ge.payload->>'role' = 'custodian'
     LIMIT 1;
    IF v_dup IS NOT NULL THEN RETURN v_dup; END IF;
  END IF;

  -- Capture previous custodian for the payload.
  SELECT custodian_membership_id INTO v_prev
    FROM public.group_resource_assets WHERE resource_id = p_resource_id;

  INSERT INTO public.group_resource_assets (resource_id, custodian_membership_id, updated_at)
       VALUES (p_resource_id, p_membership_id, now())
  ON CONFLICT (resource_id)
    DO UPDATE SET custodian_membership_id = EXCLUDED.custodian_membership_id,
                  updated_at = now();

  v_payload := jsonb_build_object(
    'subtype', 'asset',
    'role', 'custodian',
    'membership_id', p_membership_id,
    'previous_membership_id', v_prev,
    'reason', p_reason
  );
  IF p_client_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('client_id', p_client_id);
  END IF;

  SELECT rse.uuid_id INTO v_event
    FROM public.record_system_event(
      v_r.group_id,
      'resource.assigned',
      'resource',
      p_resource_id,
      COALESCE(p_reason, 'Custodia asignada'),
      v_payload
    ) rse;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.assign_asset_custodian(uuid, uuid, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assign_asset_custodian(uuid, uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.assign_asset_custodian(uuid, uuid, text, text) IS
'Asset Fase B.1: assigns or replaces the custodian of an asset resource. Emits resource.assigned (role=custodian). Idempotent via p_client_id.';

-- 3. release_asset_custodian
CREATE OR REPLACE FUNCTION public.release_asset_custodian(
  p_resource_id uuid,
  p_reason text DEFAULT NULL,
  p_client_id text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_r       public.group_resources%ROWTYPE;
  v_prev    uuid;
  v_dup     uuid;
  v_event   uuid;
  v_payload jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id;
  IF v_r.id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = '22023';
  END IF;
  IF v_r.resource_type <> 'asset' THEN
    RAISE EXCEPTION 'resource is not an asset' USING errcode = '22023';
  END IF;
  IF v_r.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'resource is archived' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update');

  SELECT custodian_membership_id INTO v_prev
    FROM public.group_resource_assets WHERE resource_id = p_resource_id;
  IF v_prev IS NULL THEN
    RAISE EXCEPTION 'asset has no custodian' USING errcode = '22023';
  END IF;

  IF p_client_id IS NOT NULL THEN
    SELECT ge.uuid_id INTO v_dup
      FROM public.group_events ge
     WHERE ge.group_id = v_r.group_id
       AND ge.event_type = 'resource.returned'
       AND ge.entity_id = p_resource_id
       AND ge.payload->>'client_id' = p_client_id
     LIMIT 1;
    IF v_dup IS NOT NULL THEN RETURN v_dup; END IF;
  END IF;

  UPDATE public.group_resource_assets
     SET custodian_membership_id = NULL,
         updated_at = now()
   WHERE resource_id = p_resource_id;

  v_payload := jsonb_build_object(
    'subtype', 'asset',
    'role', 'custodian',
    'previous_membership_id', v_prev,
    'reason', p_reason
  );
  IF p_client_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('client_id', p_client_id);
  END IF;

  SELECT rse.uuid_id INTO v_event
    FROM public.record_system_event(
      v_r.group_id,
      'resource.returned',
      'resource',
      p_resource_id,
      COALESCE(p_reason, 'Custodia liberada'),
      v_payload
    ) rse;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.release_asset_custodian(uuid, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.release_asset_custodian(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.release_asset_custodian(uuid, text, text) IS
'Asset Fase B.1: releases the custodian of an asset resource (sets NULL). Emits resource.returned (role=custodian). Idempotent via p_client_id.';

-- 4. mark_asset_condition
CREATE OR REPLACE FUNCTION public.mark_asset_condition(
  p_resource_id uuid,
  p_condition   text,
  p_reason      text DEFAULT NULL,
  p_client_id   text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_r       public.group_resources%ROWTYPE;
  v_prev    text;
  v_etype   text;
  v_dup     uuid;
  v_event   uuid;
  v_payload jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id;
  IF v_r.id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = '22023';
  END IF;
  IF v_r.resource_type <> 'asset' THEN
    RAISE EXCEPTION 'resource is not an asset' USING errcode = '22023';
  END IF;
  IF v_r.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'resource is archived' USING errcode = '22023';
  END IF;
  IF p_condition NOT IN ('good','used','damaged','repaired','retired') THEN
    RAISE EXCEPTION 'invalid condition %', p_condition USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update');

  SELECT condition INTO v_prev
    FROM public.group_resource_assets WHERE resource_id = p_resource_id;

  IF p_condition = 'damaged' THEN
    v_etype := 'resource.damaged';
  ELSIF p_condition = 'repaired' AND v_prev = 'damaged' THEN
    v_etype := 'resource.repaired';
  ELSE
    v_etype := 'resource.status_changed';
  END IF;

  IF p_client_id IS NOT NULL THEN
    SELECT ge.uuid_id INTO v_dup
      FROM public.group_events ge
     WHERE ge.group_id = v_r.group_id
       AND ge.event_type = v_etype
       AND ge.entity_id = p_resource_id
       AND ge.payload->>'client_id' = p_client_id
       AND ge.payload->>'to' = p_condition
     LIMIT 1;
    IF v_dup IS NOT NULL THEN RETURN v_dup; END IF;
  END IF;

  INSERT INTO public.group_resource_assets (resource_id, condition, updated_at)
       VALUES (p_resource_id, p_condition, now())
  ON CONFLICT (resource_id)
    DO UPDATE SET condition = EXCLUDED.condition,
                  updated_at = now();

  v_payload := jsonb_build_object(
    'subtype', 'asset',
    'from', v_prev,
    'to', p_condition,
    'reason', p_reason
  );
  IF p_client_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('client_id', p_client_id);
  END IF;

  SELECT rse.uuid_id INTO v_event
    FROM public.record_system_event(
      v_r.group_id,
      v_etype,
      'resource',
      p_resource_id,
      COALESCE(p_reason, 'Estado del activo actualizado'),
      v_payload
    ) rse;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_asset_condition(uuid, text, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.mark_asset_condition(uuid, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.mark_asset_condition(uuid, text, text, text) IS
'Asset Fase B.1: updates asset condition. Emits resource.damaged (->damaged), resource.repaired (damaged->repaired), or resource.status_changed otherwise. Idempotent via p_client_id.';
