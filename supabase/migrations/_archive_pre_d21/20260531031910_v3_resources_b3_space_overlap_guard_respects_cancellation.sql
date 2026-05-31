-- Patch overlap guard in book_resource: ignore confirmed bookings that
-- already have a cancellation audit row (cancel_booking inserts a row
-- with status='cancelled' + metadata.cancels_booking_id linking back).

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

  SELECT b.id INTO v_overlap_id
    FROM public.group_resource_bookings b
   WHERE b.resource_id = p_resource_id
     AND b.status = 'confirmed'
     AND NOT EXISTS (
       SELECT 1 FROM public.group_resource_bookings c
        WHERE c.status = 'cancelled'
          AND (c.metadata->>'cancels_booking_id') IS NOT NULL
          AND (c.metadata->>'cancels_booking_id')::uuid = b.id
     )
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
