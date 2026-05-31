-- Fase B.3: Space + bookings.
-- 1. Patch book_resource: validate starts<ends + reject overlapping confirmed bookings.
-- 2. New list_bookings_for_resource read RPC.

CREATE OR REPLACE FUNCTION public.book_resource(
  p_resource_id uuid,
  p_starts_at   timestamptz,
  p_ends_at     timestamptz DEFAULT NULL,
  p_reason      text DEFAULT NULL,
  p_client_id   text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_r          public.group_resources%ROWTYPE;
  v_membership uuid;
  v_id         uuid;
  v_overlap_id uuid;
BEGIN
  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id;
  IF v_r.id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = '22023';
  END IF;
  IF v_r.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'resource is archived' USING errcode = '22023';
  END IF;
  IF p_starts_at IS NULL THEN
    RAISE EXCEPTION 'starts_at is required' USING errcode = '22023';
  END IF;
  IF p_ends_at IS NOT NULL AND p_ends_at <= p_starts_at THEN
    RAISE EXCEPTION 'ends_at must be after starts_at' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'bookings.create');
  v_membership := public.assert_member_of_group(v_r.group_id);

  IF p_client_id IS NOT NULL THEN
    SELECT id INTO v_id
      FROM public.group_resource_bookings
     WHERE resource_id = p_resource_id
       AND metadata->>'client_id' = p_client_id
     LIMIT 1;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;

  -- Overlap guard: confirmed booking whose window overlaps blocks.
  -- NULL ends_at treated as starts_at + 1 minute for the guard math.
  SELECT id INTO v_overlap_id
    FROM public.group_resource_bookings b
   WHERE b.resource_id = p_resource_id
     AND b.status = 'confirmed'
     AND tstzrange(b.starts_at, COALESCE(b.ends_at, b.starts_at + interval '1 minute'), '[)')
         && tstzrange(p_starts_at, COALESCE(p_ends_at, p_starts_at + interval '1 minute'), '[)')
   LIMIT 1;
  IF v_overlap_id IS NOT NULL THEN
    RAISE EXCEPTION 'booking overlaps existing booking %', v_overlap_id USING errcode = '22023';
  END IF;

  INSERT INTO public.group_resource_bookings (
    group_id, resource_id, booked_by_membership_id, starts_at, ends_at, status, reason, metadata
  ) VALUES (
    v_r.group_id, p_resource_id, v_membership, p_starts_at, p_ends_at, 'confirmed',
    p_reason,
    CASE WHEN p_client_id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('client_id', p_client_id) END
  ) RETURNING id INTO v_id;

  PERFORM public.record_system_event(
    v_r.group_id, 'booking.created', 'booking', v_id, p_reason,
    jsonb_build_object('resource_id', p_resource_id, 'starts_at', p_starts_at, 'ends_at', p_ends_at)
  );
  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.book_resource(uuid, timestamptz, timestamptz, text, text) IS
'Space Fase B.3 hardened: validates starts<ends + rejects overlapping confirmed bookings. Idempotent via p_client_id.';

CREATE OR REPLACE FUNCTION public.list_bookings_for_resource(
  p_resource_id  uuid,
  p_starts_after timestamptz DEFAULT NULL,
  p_ends_before  timestamptz DEFAULT NULL,
  p_limit        int DEFAULT 50
) RETURNS TABLE(
  id uuid,
  resource_id uuid,
  group_id uuid,
  booked_by_membership_id uuid,
  starts_at timestamptz,
  ends_at timestamptz,
  status text,
  reason text,
  created_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_group_id  uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  SELECT gr.group_id INTO v_group_id FROM public.group_resources gr WHERE gr.id = p_resource_id;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = v_group_id AND gm.user_id = v_uid AND gm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'not a member' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT b.id, b.resource_id, b.group_id, b.booked_by_membership_id,
         b.starts_at, b.ends_at, b.status, b.reason, b.created_at
    FROM public.group_resource_bookings b
   WHERE b.resource_id = p_resource_id
     AND (p_starts_after IS NULL OR b.starts_at >= p_starts_after)
     AND (p_ends_before  IS NULL OR (b.ends_at IS NOT NULL AND b.ends_at <= p_ends_before))
   ORDER BY b.starts_at DESC
   LIMIT GREATEST(p_limit, 1);
END;
$$;

REVOKE ALL ON FUNCTION public.list_bookings_for_resource(uuid, timestamptz, timestamptz, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.list_bookings_for_resource(uuid, timestamptz, timestamptz, int) TO authenticated;

COMMENT ON FUNCTION public.list_bookings_for_resource(uuid, timestamptz, timestamptz, int) IS
'Space Fase B.3: lists bookings for a resource, optionally filtered by date window. Active-member gate.';
