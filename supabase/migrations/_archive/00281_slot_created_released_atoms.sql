-- 00281_slot_created_released_atoms.sql
--
-- Sprint 3.7 doctrinal fix per Plans/Active/ConsistencyAudit_2026-05-17.md
-- Finding F22 + part of F4: slot lifecycle currently lacks two essential atoms:
--   - slotCreated — slot creation is unauditable from atoms; only the row
--     exists. Replaying atoms cannot reconstruct that the slot ever existed.
--   - slotReleased — when cancel_booking or expire_booking turn a slot back
--     to unassigned, only bookingCancelled/Expired atoms exist. There is no
--     atom representing the slot's transition back to available. The future
--     slot_state_view (Sprint 3.8) cannot derive status='unassigned' purely
--     from atoms without inferring it from negative space.
--
-- This migration:
-- - Whitelists 'slotCreated' and 'slotReleased' in is_known_system_event_type.
-- - create_slot emits slotCreated atom after INSERT.
-- - cancel_booking emits slotReleased atom after the resources update when
--   target is a slot.
-- - expire_booking same pattern.
-- - Pre-existing slot UPDATE writes (resources.status='unassigned' on
--   cancel/expire) are preserved as operational cache. Sprint 3.9 decides
--   whether to keep, document, or drop them after slot_state_view (3.8) is
--   in place.
--
-- atom payloads:
--   slotCreated  { asset_id, starts_at, ends_at, created_by }
--   slotReleased { released_via: 'cancel_booking'|'expire_booking',
--                  booking_id, prior_assigned_member_id?, reason? }

-- =============================================================================
-- 1) Whitelist new atom types.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.is_known_system_event_type(p_event_type text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT p_event_type = ANY (ARRAY[
    'eventClosed', 'eventCreated', 'rsvpDeadlinePassed', 'hoursBeforeEvent',
    'eventCancelled', 'eventStarted', 'eventUpdated',
    'rsvpSubmitted', 'rsvpChangedSameDay', 'checkInRecorded', 'checkInMissed',
    'eventDescriptionMissing',
    'slotAssigned', 'slotDeclined', 'slotExpired', 'slotSwapRequested', 'slotSwapApproved',
    'slotCreated', 'slotReleased',
    'bookingCreated', 'bookingCancelled', 'bookingExpired', 'bookingNoCheckIn',
    'assetCreated', 'assetTransferred', 'assetAssigned', 'assetReturned',
    'custodyAssigned', 'custodyReleased',
    'maintenanceLogged', 'maintenanceCompleted', 'damageReported',
    'assetUsed', 'assetCheckedOut', 'assetCheckedIn', 'valuationRecorded',
    'assetCheckoutOverdue', 'assetMaintenanceOverdue',
    'fineOfficialized', 'fineVoided', 'finePaid', 'fineReminderSent',
    'appealCreated', 'appealResolved',
    'voteOpened', 'voteCast', 'voteResolved',
    'fundCreated', 'fundDeposit', 'fundThresholdReached',
    'fundLocked', 'fundUnlocked',
    'spaceCreated', 'spaceBooked', 'spaceReleased', 'spaceCapacityReached',
    'spaceWaitlistJoined', 'spaceWaitlistPromoted',
    'spaceAccessGranted', 'spaceAccessRevoked',
    'positionChanged', 'memberJoined', 'memberLeft',
    'ruleEnabledChanged', 'ruleAmountChanged',
    'pendingChangeApplied', 'inviteCodeRotated',
    'groupCreated', 'groupArchived', 'groupUnarchived', 'groupRenamed', 'governanceUpdated',
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    'ledgerEntryCreated', 'warningEmitted',
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    'rightExpiringSoon', 'rightMetadataUpdated',
    'resourceLinked', 'resourceUnlinked',
    'roleAssigned', 'roleUnassigned'
  ]);
$$;

-- =============================================================================
-- 2) create_slot — emit slotCreated atom after INSERT.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.create_slot(
  p_asset_id   uuid,
  p_starts_at  timestamptz,
  p_ends_at    timestamptz
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id    uuid := auth.uid();
  v_group_id     uuid;
  v_asset_status text;
  v_slot_id      uuid;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT group_id, status INTO v_group_id, v_asset_status
    FROM public.resources
   WHERE id = p_asset_id AND resource_type = 'asset';
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'asset not found' USING errcode = '02000';
  END IF;
  IF v_asset_status <> 'active' THEN
    RAISE EXCEPTION 'asset is %, cannot add slots', v_asset_status USING errcode = '22023';
  END IF;
  IF NOT public.has_permission(v_group_id, v_caller_id, 'assignSlot') THEN
    RAISE EXCEPTION 'permission denied: assignSlot required' USING errcode = '42501';
  END IF;
  IF p_starts_at >= p_ends_at THEN
    RAISE EXCEPTION 'starts_at must be before ends_at' USING errcode = '22023';
  END IF;

  INSERT INTO public.resources (group_id, resource_type, status, metadata, created_by)
  VALUES (
    v_group_id,
    'slot',
    'unassigned',
    jsonb_build_object(
      'asset_id',           p_asset_id,
      'starts_at',          p_starts_at,
      'ends_at',            p_ends_at,
      'assigned_member_id', NULL,
      'booking_id',         NULL
    ),
    v_caller_id
  )
  RETURNING id INTO v_slot_id;

  PERFORM public.record_system_event(
    v_group_id,
    'slotCreated',
    v_slot_id,
    NULL,
    jsonb_build_object(
      'asset_id',   p_asset_id,
      'starts_at',  p_starts_at,
      'ends_at',    p_ends_at,
      'created_by', v_caller_id
    )
  );

  RETURN v_slot_id;
END;
$$;

-- =============================================================================
-- 3) cancel_booking — emit slotReleased after slot UPDATE.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.cancel_booking(
  p_booking_id uuid,
  p_reason     text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id    uuid := auth.uid();
  v_group_id     uuid;
  v_booker_id    uuid;
  v_target_id    uuid;
  v_target_type  text;
  v_already_done boolean;
  v_prior_assignee uuid;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT b.group_id, b.member_id, b.slot_id
    INTO v_group_id, v_booker_id, v_target_id
    FROM public.bookings b WHERE b.id = p_booking_id;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'booking not found' USING errcode = '02000';
  END IF;

  SELECT resource_type INTO v_target_type
    FROM public.resources WHERE id = v_target_id;
  v_target_type := COALESCE(v_target_type, 'unknown');

  IF NOT (
    v_booker_id IN (SELECT id FROM public.group_members WHERE group_id = v_group_id AND user_id = v_caller_id AND active)
    OR public.is_group_admin(v_group_id, v_caller_id)
  ) THEN
    RAISE EXCEPTION 'only the booker or an admin may cancel' USING errcode = '42501';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.system_events se
    WHERE se.event_type IN ('bookingCancelled', 'bookingExpired')
      AND (se.payload->>'booking_id')::uuid = p_booking_id
  ) INTO v_already_done;
  IF v_already_done THEN RETURN; END IF;

  -- Capture prior assignee BEFORE we strip the metadata.
  IF v_target_type = 'slot' THEN
    SELECT NULLIF(metadata->>'assigned_member_id','')::uuid
      INTO v_prior_assignee
      FROM public.resources WHERE id = v_target_id;

    UPDATE public.resources
       SET status = 'unassigned', metadata = metadata - 'booking_id'
     WHERE id = v_target_id AND (metadata->>'booking_id')::uuid = p_booking_id;
  END IF;

  PERFORM public.record_system_event(
    v_group_id, 'bookingCancelled', v_target_id, v_booker_id,
    jsonb_strip_nulls(jsonb_build_object(
      'booking_id',   p_booking_id::text,
      'cancelled_by', v_caller_id,
      'target_kind',  v_target_type,
      'reason',       NULLIF(trim(COALESCE(p_reason, '')), '')
    ))
  );

  IF v_target_type = 'slot' THEN
    PERFORM public.record_system_event(
      v_group_id, 'slotReleased', v_target_id, v_booker_id,
      jsonb_strip_nulls(jsonb_build_object(
        'released_via',              'cancel_booking',
        'booking_id',                p_booking_id::text,
        'prior_assigned_member_id',  v_prior_assignee,
        'released_by',               v_caller_id,
        'reason',                    NULLIF(trim(COALESCE(p_reason, '')), '')
      ))
    );
  ELSIF v_target_type = 'space' THEN
    PERFORM public.record_system_event(
      v_group_id, 'spaceReleased', v_target_id, v_booker_id,
      jsonb_strip_nulls(jsonb_build_object(
        'booking_id',  p_booking_id::text,
        'reason',      'cancelled',
        'released_by', v_caller_id
      ))
    );
  END IF;
END;
$$;

-- =============================================================================
-- 4) expire_booking — emit slotReleased after slot UPDATE.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.expire_booking(
  p_booking_id uuid,
  p_reason     text DEFAULT 'expired'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_id     uuid;
  v_booker_id    uuid;
  v_target_id    uuid;
  v_target_type  text;
  v_already_done boolean;
  v_prior_assignee uuid;
BEGIN
  SELECT b.group_id, b.member_id, b.slot_id
    INTO v_group_id, v_booker_id, v_target_id
    FROM public.bookings b WHERE b.id = p_booking_id;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'booking not found' USING errcode = '02000';
  END IF;

  SELECT resource_type INTO v_target_type
    FROM public.resources WHERE id = v_target_id;
  v_target_type := COALESCE(v_target_type, 'unknown');

  SELECT EXISTS (
    SELECT 1 FROM public.system_events se
    WHERE se.event_type IN ('bookingCancelled', 'bookingExpired')
      AND (se.payload->>'booking_id')::uuid = p_booking_id
  ) INTO v_already_done;
  IF v_already_done THEN RETURN; END IF;

  IF v_target_type = 'slot' THEN
    SELECT NULLIF(metadata->>'assigned_member_id','')::uuid
      INTO v_prior_assignee
      FROM public.resources WHERE id = v_target_id;

    UPDATE public.resources
       SET status = 'unassigned', metadata = metadata - 'booking_id'
     WHERE id = v_target_id AND (metadata->>'booking_id')::uuid = p_booking_id;
  END IF;

  PERFORM public.record_system_event(
    v_group_id, 'bookingExpired', v_target_id, v_booker_id,
    jsonb_build_object(
      'booking_id',  p_booking_id::text,
      'target_kind', v_target_type,
      'reason',      p_reason
    )
  );

  IF v_target_type = 'slot' THEN
    PERFORM public.record_system_event(
      v_group_id, 'slotReleased', v_target_id, v_booker_id,
      jsonb_strip_nulls(jsonb_build_object(
        'released_via',              'expire_booking',
        'booking_id',                p_booking_id::text,
        'prior_assigned_member_id',  v_prior_assignee,
        'reason',                    p_reason
      ))
    );
  ELSIF v_target_type = 'space' THEN
    PERFORM public.record_system_event(
      v_group_id, 'spaceReleased', v_target_id, v_booker_id,
      jsonb_build_object(
        'booking_id',  p_booking_id::text,
        'reason',      p_reason
      )
    );
  END IF;
END;
$$;

COMMENT ON FUNCTION public.create_slot(uuid, timestamptz, timestamptz) IS
  'Sprint 3.7 (mig 00281). Emits slotCreated atom after INSERT for atom-derivable slot existence.';

COMMENT ON FUNCTION public.cancel_booking(uuid, text) IS
  'Sprint 3.7 (mig 00281). Emits slotReleased atom (in addition to bookingCancelled) when target_kind=slot, with prior_assigned_member_id captured pre-strip.';

COMMENT ON FUNCTION public.expire_booking(uuid, text) IS
  'Sprint 3.7 (mig 00281). Emits slotReleased atom (in addition to bookingExpired) when target_kind=slot.';
