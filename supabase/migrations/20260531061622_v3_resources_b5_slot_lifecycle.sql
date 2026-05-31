-- Fase B.5: Slot assign/release/expire.

CREATE OR REPLACE FUNCTION public.assign_slot(
  p_resource_id   uuid,
  p_membership_id uuid,
  p_reason        text DEFAULT NULL,
  p_client_id     text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_r         public.group_resources%ROWTYPE;
  v_member_g  uuid;
  v_prev      uuid;
  v_released  timestamptz;
  v_expired   timestamptz;
  v_dup       uuid;
  v_event     uuid;
  v_payload   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id;
  IF v_r.id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = '22023';
  END IF;
  IF v_r.resource_type <> 'slot' THEN
    RAISE EXCEPTION 'resource is not a slot' USING errcode = '22023';
  END IF;
  IF v_r.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'resource is archived' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update');

  SELECT group_id INTO v_member_g
    FROM public.group_memberships WHERE id = p_membership_id;
  IF v_member_g IS NULL THEN
    RAISE EXCEPTION 'membership not found' USING errcode = '22023';
  END IF;
  IF v_member_g <> v_r.group_id THEN
    RAISE EXCEPTION 'membership not in resource group' USING errcode = '22023';
  END IF;

  SELECT assigned_membership_id, released_at, expired_at
    INTO v_prev, v_released, v_expired
    FROM public.group_resource_slots WHERE resource_id = p_resource_id;
  IF v_expired IS NOT NULL THEN
    RAISE EXCEPTION 'slot is expired' USING errcode = '22023';
  END IF;

  IF p_client_id IS NOT NULL THEN
    SELECT ge.uuid_id INTO v_dup
      FROM public.group_events ge
     WHERE ge.group_id = v_r.group_id
       AND ge.event_type = 'resource.assigned'
       AND ge.entity_id = p_resource_id
       AND ge.payload->>'client_id' = p_client_id
       AND ge.payload->>'role' = 'assignee'
     LIMIT 1;
    IF v_dup IS NOT NULL THEN RETURN v_dup; END IF;
  END IF;

  INSERT INTO public.group_resource_slots (
    resource_id, assigned_membership_id, released_at, expired_at, updated_at
  ) VALUES (
    p_resource_id, p_membership_id, NULL, NULL, now()
  )
  ON CONFLICT (resource_id)
    DO UPDATE SET assigned_membership_id = EXCLUDED.assigned_membership_id,
                  released_at = NULL,
                  updated_at = now();

  v_payload := jsonb_build_object(
    'subtype', 'slot',
    'role', 'assignee',
    'membership_id', p_membership_id,
    'previous_membership_id', v_prev,
    'reason', p_reason
  );
  IF p_client_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('client_id', p_client_id);
  END IF;

  SELECT rse.uuid_id INTO v_event
    FROM public.record_system_event(
      v_r.group_id, 'resource.assigned', 'resource', p_resource_id,
      COALESCE(p_reason, 'Turno asignado'), v_payload
    ) rse;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.assign_slot(uuid, uuid, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assign_slot(uuid, uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.assign_slot(uuid, uuid, text, text) IS
'Slot Fase B.5: assigns or reassigns a slot to a member. Emits resource.assigned (role=assignee). Idempotent.';

CREATE OR REPLACE FUNCTION public.release_slot(
  p_resource_id uuid,
  p_reason      text DEFAULT NULL,
  p_client_id   text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_r       public.group_resources%ROWTYPE;
  v_prev    uuid;
  v_released timestamptz;
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
  IF v_r.resource_type <> 'slot' THEN
    RAISE EXCEPTION 'resource is not a slot' USING errcode = '22023';
  END IF;
  IF v_r.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'resource is archived' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update');

  SELECT assigned_membership_id, released_at INTO v_prev, v_released
    FROM public.group_resource_slots WHERE resource_id = p_resource_id;
  IF v_prev IS NULL THEN
    RAISE EXCEPTION 'slot has no assignee' USING errcode = '22023';
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

  UPDATE public.group_resource_slots
     SET assigned_membership_id = NULL,
         released_at = now(),
         updated_at = now()
   WHERE resource_id = p_resource_id;

  v_payload := jsonb_build_object(
    'subtype', 'slot',
    'role', 'assignee',
    'previous_membership_id', v_prev,
    'reason', p_reason
  );
  IF p_client_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('client_id', p_client_id);
  END IF;

  SELECT rse.uuid_id INTO v_event
    FROM public.record_system_event(
      v_r.group_id, 'resource.returned', 'resource', p_resource_id,
      COALESCE(p_reason, 'Turno liberado'), v_payload
    ) rse;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.release_slot(uuid, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.release_slot(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.release_slot(uuid, text, text) IS
'Slot Fase B.5: releases the slot (sets released_at, clears assignee). Emits resource.returned.';

CREATE OR REPLACE FUNCTION public.expire_slot(
  p_resource_id uuid,
  p_client_id   text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_r       public.group_resources%ROWTYPE;
  v_ends    timestamptz;
  v_expired timestamptz;
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
  IF v_r.resource_type <> 'slot' THEN
    RAISE EXCEPTION 'resource is not a slot' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update');

  SELECT assigned_membership_id, slot_ends_at, expired_at
    INTO v_prev, v_ends, v_expired
    FROM public.group_resource_slots WHERE resource_id = p_resource_id;
  IF v_expired IS NOT NULL THEN
    RAISE EXCEPTION 'slot already expired' USING errcode = '22023';
  END IF;
  IF v_ends IS NULL OR v_ends > now() THEN
    RAISE EXCEPTION 'slot has not reached its end' USING errcode = '22023';
  END IF;

  IF p_client_id IS NOT NULL THEN
    SELECT ge.uuid_id INTO v_dup
      FROM public.group_events ge
     WHERE ge.group_id = v_r.group_id
       AND ge.event_type = 'resource.status_changed'
       AND ge.entity_id = p_resource_id
       AND ge.payload->>'client_id' = p_client_id
       AND ge.payload->>'to' = 'expired'
     LIMIT 1;
    IF v_dup IS NOT NULL THEN RETURN v_dup; END IF;
  END IF;

  UPDATE public.group_resource_slots
     SET expired_at = now(), updated_at = now()
   WHERE resource_id = p_resource_id;

  v_payload := jsonb_build_object(
    'subtype', 'slot',
    'from', 'active',
    'to', 'expired',
    'previous_membership_id', v_prev,
    'slot_ends_at', v_ends
  );
  IF p_client_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('client_id', p_client_id);
  END IF;

  SELECT rse.uuid_id INTO v_event
    FROM public.record_system_event(
      v_r.group_id, 'resource.status_changed', 'resource', p_resource_id,
      'Turno expirado', v_payload
    ) rse;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.expire_slot(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.expire_slot(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.expire_slot(uuid, text) IS
'Slot Fase B.5: marks a slot as expired after slot_ends_at <= now(). Emits resource.status_changed (to=expired).';
