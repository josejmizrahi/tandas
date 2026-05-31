-- Drift fix: group_resource_slots.slot_starts_at is NOT NULL, so assign_slot
-- must either provide one or default it. Add p_starts_at + p_ends_at
-- optional params (defaults: now() and now() + 1 hour).

CREATE OR REPLACE FUNCTION public.assign_slot(
  p_resource_id   uuid,
  p_membership_id uuid,
  p_reason        text DEFAULT NULL,
  p_client_id     text DEFAULT NULL,
  p_starts_at     timestamptz DEFAULT NULL,
  p_ends_at       timestamptz DEFAULT NULL
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
  v_starts    timestamptz;
  v_ends      timestamptz;
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
  IF p_ends_at IS NOT NULL AND p_starts_at IS NOT NULL AND p_ends_at <= p_starts_at THEN
    RAISE EXCEPTION 'ends_at must be after starts_at' USING errcode = '22023';
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

  SELECT assigned_membership_id, released_at, expired_at,
         slot_starts_at, slot_ends_at
    INTO v_prev, v_released, v_expired, v_starts, v_ends
    FROM public.group_resource_slots WHERE resource_id = p_resource_id;
  IF v_expired IS NOT NULL THEN
    RAISE EXCEPTION 'slot is expired' USING errcode = '22023';
  END IF;

  -- Pick window: explicit args > existing row > defaults (now + 1h).
  v_starts := COALESCE(p_starts_at, v_starts, now());
  v_ends   := COALESCE(p_ends_at, v_ends, v_starts + interval '1 hour');

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
    resource_id, slot_starts_at, slot_ends_at,
    assigned_membership_id, released_at, expired_at, updated_at
  ) VALUES (
    p_resource_id, v_starts, v_ends,
    p_membership_id, NULL, NULL, now()
  )
  ON CONFLICT (resource_id)
    DO UPDATE SET assigned_membership_id = EXCLUDED.assigned_membership_id,
                  slot_starts_at         = COALESCE(p_starts_at, group_resource_slots.slot_starts_at),
                  slot_ends_at           = COALESCE(p_ends_at, group_resource_slots.slot_ends_at),
                  released_at            = NULL,
                  updated_at             = now();

  v_payload := jsonb_build_object(
    'subtype', 'slot',
    'role', 'assignee',
    'membership_id', p_membership_id,
    'previous_membership_id', v_prev,
    'slot_starts_at', v_starts,
    'slot_ends_at', v_ends,
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

REVOKE ALL ON FUNCTION public.assign_slot(uuid, uuid, text, text, timestamptz, timestamptz) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assign_slot(uuid, uuid, text, text, timestamptz, timestamptz) TO authenticated;

-- Drop the previous 4-arg overload so callers don't keep targeting it.
DROP FUNCTION IF EXISTS public.assign_slot(uuid, uuid, text, text);

COMMENT ON FUNCTION public.assign_slot(uuid, uuid, text, text, timestamptz, timestamptz) IS
'Slot Fase B.5 (hardened): assigns a slot with optional starts/ends window. Defaults: now and +1h. Emits resource.assigned (role=assignee). Idempotent.';
