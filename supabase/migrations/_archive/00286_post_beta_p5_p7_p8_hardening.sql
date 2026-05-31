-- 00286_post_beta_p5_p7_p8_hardening.sql
--
-- Post-Beta safe hardening bundle (round 2) per ConsistencyAudit_2026-05-17 §6.B:
--
-- P5 / F15: book_slot idempotency.
--   Currently book_slot only checks slot.status. If a caller races two
--   parallel requests for the same slot, both pass the status check but
--   only one wins the resources UPDATE — the loser inserts a duplicate
--   bookings row that the slot.status mutation no-ops on. Fix: short-
--   circuit if an active (non-cancelled, non-expired) booking already
--   exists for (slot_id, caller_member_id) and return its id.
--
-- P7 / F16: member_capability_overrides emits deactivation atom.
--   The existing on_member_capability_overridden trigger emits an atom
--   on INSERT. When `effective_until` is flipped from null → ts (override
--   manually deactivated), no atom fires — the change is silent. Add a
--   companion trigger that emits memberCapabilityOverrideDeactivated on
--   that one-way transition. Whitelist the new event_type.
--
-- P8 / F18: fund.target_amount_cents post-create immutability.
--   No update_fund_target RPC exists today, but resources.metadata is
--   open to service_role / future generic update RPCs. Block silent
--   value→value mutations of metadata.target_amount_cents on fund rows
--   via a trigger. null→value (rare backfill) is still allowed; once
--   a target is set, only an explicit migration / atom-emitting RPC
--   can change it.

-- =============================================================================
-- P5 — book_slot idempotency
-- =============================================================================
CREATE OR REPLACE FUNCTION public.book_slot(p_slot_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id          uuid := auth.uid();
  v_group_id           uuid;
  v_slot_status        text;
  v_metadata           jsonb;
  v_assigned_member_id uuid;
  v_caller_member_id   uuid;
  v_booking_id         uuid;
  v_existing_booking   uuid;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT group_id, status, metadata
    INTO v_group_id, v_slot_status, v_metadata
    FROM public.resources
   WHERE id = p_slot_id AND resource_type = 'slot';
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'slot not found' USING errcode = '02000';
  END IF;

  IF NOT public.has_permission(v_group_id, v_caller_id, 'bookSlot') THEN
    RAISE EXCEPTION 'permission denied: bookSlot required' USING errcode = '42501';
  END IF;

  SELECT id INTO v_caller_member_id
    FROM public.group_members
   WHERE group_id = v_group_id AND user_id = v_caller_id AND active;
  IF v_caller_member_id IS NULL THEN
    RAISE EXCEPTION 'caller not active member' USING errcode = '42501';
  END IF;

  -- P5 idempotency check (mig 00286). If an active booking by this caller
  -- already exists for this slot, return it. Active = booking row exists
  -- AND no bookingCancelled / bookingExpired atom references it.
  SELECT b.id INTO v_existing_booking
    FROM public.bookings b
   WHERE b.slot_id = p_slot_id
     AND b.member_id = v_caller_member_id
     AND NOT EXISTS (
       SELECT 1 FROM public.system_events se
        WHERE se.event_type IN ('bookingCancelled', 'bookingExpired')
          AND (se.payload->>'booking_id')::uuid = b.id
     )
   LIMIT 1;
  IF v_existing_booking IS NOT NULL THEN
    RETURN v_existing_booking;
  END IF;

  IF v_slot_status NOT IN ('unassigned', 'assigned') THEN
    RAISE EXCEPTION 'slot is %, cannot book', v_slot_status USING errcode = '22023';
  END IF;

  v_assigned_member_id := NULLIF(v_metadata->>'assigned_member_id', '')::uuid;
  IF v_assigned_member_id IS NOT NULL AND v_assigned_member_id <> v_caller_member_id THEN
    RAISE EXCEPTION 'slot assigned to a different member' USING errcode = '42501';
  END IF;

  INSERT INTO public.bookings (group_id, slot_id, member_id, metadata, created_by)
  VALUES (
    v_group_id,
    p_slot_id,
    v_caller_member_id,
    jsonb_build_object('booked_at', now()),
    v_caller_id
  )
  RETURNING id INTO v_booking_id;

  UPDATE public.resources
     SET status   = 'booked',
         metadata = metadata || jsonb_build_object('booking_id', v_booking_id::text)
   WHERE id = p_slot_id;

  PERFORM public.record_system_event(
    v_group_id,
    'bookingCreated',
    v_booking_id,
    v_caller_member_id,
    jsonb_build_object('slot_id', p_slot_id)
  );

  RETURN v_booking_id;
END;
$$;

COMMENT ON FUNCTION public.book_slot(uuid) IS
  'P5 (mig 00286) per ConsistencyAudit F15. Idempotent: short-circuits to existing active booking for (slot_id, caller_member_id) if one exists (no bookingCancelled/Expired atom).';

-- =============================================================================
-- P7 — member_capability_overrides deactivation atom
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
    'assetBookingsLocked', 'assetBookingsUnlocked',
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
    'capabilityToggled', 'capabilityConfigUpdated',
    'memberCapabilityOverridden', 'memberCapabilityOverrideDeactivated',
    'ledgerEntryCreated', 'warningEmitted',
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    'rightExpiringSoon', 'rightMetadataUpdated',
    'resourceLinked', 'resourceUnlinked',
    'roleAssigned', 'roleUnassigned'
  ]);
$$;

CREATE OR REPLACE FUNCTION public.member_capability_override_deactivation_emit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- One-way null → ts transition: emit atom recording the deactivation.
  IF OLD.effective_until IS NULL AND NEW.effective_until IS NOT NULL THEN
    PERFORM public.record_system_event(
      NEW.group_id,
      'memberCapabilityOverrideDeactivated',
      NULL,                    -- no resource_id (override is policy, not a resource)
      NEW.member_id,
      jsonb_build_object(
        'override_id',     NEW.id,
        'capability',      NEW.capability,
        'override_value',  NEW.override,
        'effective_until', NEW.effective_until,
        'created_by',      NEW.created_by
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS member_capability_override_deactivation_trg
  ON public.member_capability_overrides;

CREATE TRIGGER member_capability_override_deactivation_trg
  AFTER UPDATE OF effective_until ON public.member_capability_overrides
  FOR EACH ROW EXECUTE FUNCTION public.member_capability_override_deactivation_emit();

COMMENT ON FUNCTION public.member_capability_override_deactivation_emit() IS
  'P7 (mig 00286) per ConsistencyAudit F16. Emits memberCapabilityOverrideDeactivated atom on effective_until null→ts transition. Companion to on_member_capability_overridden (insert-side emit).';

-- =============================================================================
-- P8 — fund.target_amount_cents post-create immutability
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fund_target_immutable_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_old_target jsonb;
  v_new_target jsonb;
BEGIN
  -- Only applies to fund resources.
  IF NEW.resource_type <> 'fund' OR OLD.resource_type <> 'fund' THEN
    RETURN NEW;
  END IF;

  v_old_target := OLD.metadata->'target_amount_cents';
  v_new_target := NEW.metadata->'target_amount_cents';

  -- Allowed: no change; null→value (backfill); value→null (clear, rare).
  -- Blocked: value→different-value (silent target mutation).
  IF v_old_target IS NOT NULL
     AND v_new_target IS NOT NULL
     AND v_old_target IS DISTINCT FROM v_new_target THEN
    RAISE EXCEPTION
      'fund.target_amount_cents is immutable post-create (fund_id=%): % → %',
      NEW.id, v_old_target, v_new_target
      USING errcode = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS fund_target_immutable_guard_trg ON public.resources;

CREATE TRIGGER fund_target_immutable_guard_trg
  BEFORE UPDATE OF metadata ON public.resources
  FOR EACH ROW
  WHEN (NEW.resource_type = 'fund')
  EXECUTE FUNCTION public.fund_target_immutable_guard();

COMMENT ON FUNCTION public.fund_target_immutable_guard() IS
  'P8 (mig 00286) per ConsistencyAudit F18. Blocks value→different-value mutation of fund.metadata.target_amount_cents. Future setter must explicitly drop this guard or emit a fundTargetChanged atom (not whitelisted today; intentional gate).';
