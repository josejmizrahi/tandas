-- 00284_asset_booking_lock_atom_rpc.sql
--
-- Sprint 4.12 doctrinal fix per Plans/Active/ConsistencyAudit_2026-05-17.md
-- Finding F8: setBookingsLocked (rule consequence sink in
--   process-system-events/index.ts:403-446) writes resources.metadata
--   directly from edge function code, then best-effort emits a warningEmitted
--   atom for audit. This violates the rule engine doctrine: consequences
--   emit atoms or invoke canonical RPCs; they do NOT mutate state tables
--   directly.
--
-- This migration:
-- - Whitelists 'assetBookingsLocked' and 'assetBookingsUnlocked' atoms.
-- - Creates lock_asset_bookings(p_asset_id, p_reason, p_rule_id) RPC —
--   SECURITY DEFINER, emits assetBookingsLocked atom + writes the cache
--   field resources.metadata.bookings_locked=true (atom-backed cache per
--   OperationalCacheDoctrine §5).
-- - Creates unlock_asset_bookings(p_asset_id, p_reason) RPC — symmetric.
-- - Creates asset_booking_lock_view derived from atoms (ordered by seq DESC
--   per mig 00275) — canonical source of is_locked state.
-- - The TS consequence sink (Sprint 4 follow-up edit) will be rewritten to
--   call lock_asset_bookings() instead of UPDATE-ing resources directly.

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
-- 2) lock_asset_bookings — atom emit + cache write.
--    Idempotent: if asset_booking_lock_view already says is_locked=true,
--    short-circuit with no atom emission.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.lock_asset_bookings(
  p_asset_id uuid,
  p_reason   text DEFAULT NULL,
  p_rule_id  uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id uuid := auth.uid();
  v_group_id  uuid;
  v_archived  timestamptz;
BEGIN
  SELECT group_id, archived_at
    INTO v_group_id, v_archived
    FROM public.resources
   WHERE id = p_asset_id AND resource_type = 'asset'
   FOR UPDATE;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'asset not found' USING errcode = '02000';
  END IF;
  IF v_archived IS NOT NULL THEN
    RAISE EXCEPTION 'asset is archived' USING errcode = 'check_violation';
  END IF;

  -- Permission: auth.uid() is null when called from cron (service role) —
  -- allowed. Otherwise require admin.
  IF v_caller_id IS NOT NULL AND NOT public.is_group_admin(v_group_id, v_caller_id) THEN
    RAISE EXCEPTION 'caller is not a group admin' USING errcode = '42501';
  END IF;

  -- Idempotency: short-circuit if already locked per atom-derived view.
  IF (SELECT is_locked FROM public.asset_booking_lock_view WHERE asset_id = p_asset_id) THEN
    RETURN;
  END IF;

  PERFORM public.record_system_event(
    v_group_id,
    'assetBookingsLocked',
    p_asset_id,
    NULL,
    jsonb_build_object(
      'locked_by', v_caller_id,
      'reason',    p_reason,
      'rule_id',   p_rule_id
    )
  );

  -- Cache write (atom-backed per OperationalCacheDoctrine §5).
  UPDATE public.resources
     SET metadata = metadata || jsonb_build_object(
       'bookings_locked',              true,
       'bookings_locked_at',           now(),
       'bookings_locked_by_rule_id',   p_rule_id
     ),
         updated_at = now()
   WHERE id = p_asset_id;
END;
$$;

-- =============================================================================
-- 3) unlock_asset_bookings — symmetric.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.unlock_asset_bookings(
  p_asset_id uuid,
  p_reason   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id uuid := auth.uid();
  v_group_id  uuid;
BEGIN
  SELECT group_id INTO v_group_id
    FROM public.resources
   WHERE id = p_asset_id AND resource_type = 'asset'
   FOR UPDATE;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'asset not found' USING errcode = '02000';
  END IF;
  IF v_caller_id IS NOT NULL AND NOT public.is_group_admin(v_group_id, v_caller_id) THEN
    RAISE EXCEPTION 'caller is not a group admin' USING errcode = '42501';
  END IF;

  IF NOT (SELECT is_locked FROM public.asset_booking_lock_view WHERE asset_id = p_asset_id) THEN
    RETURN;
  END IF;

  PERFORM public.record_system_event(
    v_group_id,
    'assetBookingsUnlocked',
    p_asset_id,
    NULL,
    jsonb_build_object('unlocked_by', v_caller_id, 'reason', p_reason)
  );

  UPDATE public.resources
     SET metadata = ((metadata - 'bookings_locked') - 'bookings_locked_at') - 'bookings_locked_by_rule_id',
         updated_at = now()
   WHERE id = p_asset_id;
END;
$$;

-- =============================================================================
-- 4) asset_booking_lock_view — atom-derived canonical state.
-- =============================================================================
CREATE OR REPLACE VIEW public.asset_booking_lock_view
WITH (security_invoker = on) AS
WITH lock_events AS (
  SELECT
    se.resource_id AS asset_id,
    se.event_type,
    se.occurred_at,
    se.payload,
    se.seq,
    ROW_NUMBER() OVER (
      PARTITION BY se.resource_id ORDER BY se.seq DESC
    ) AS rn
  FROM public.system_events se
  JOIN public.resources r ON r.id = se.resource_id AND r.resource_type = 'asset'
  WHERE se.event_type IN ('assetBookingsLocked', 'assetBookingsUnlocked')
)
SELECT
  r.id   AS asset_id,
  r.group_id,
  COALESCE(le.event_type = 'assetBookingsLocked', false) AS is_locked,
  CASE WHEN le.event_type = 'assetBookingsLocked' THEN le.occurred_at END AS locked_at,
  CASE WHEN le.event_type = 'assetBookingsLocked' THEN le.payload->>'reason' END AS reason,
  CASE WHEN le.event_type = 'assetBookingsLocked'
       THEN (le.payload->>'rule_id')::uuid END AS rule_id
FROM public.resources r
LEFT JOIN lock_events le ON le.asset_id = r.id AND le.rn = 1
WHERE r.resource_type = 'asset';

REVOKE EXECUTE ON FUNCTION public.lock_asset_bookings(uuid, text, uuid)  FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.lock_asset_bookings(uuid, text, uuid)  TO authenticated;
REVOKE EXECUTE ON FUNCTION public.unlock_asset_bookings(uuid, text)      FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.unlock_asset_bookings(uuid, text)      TO authenticated;

COMMENT ON FUNCTION public.lock_asset_bookings(uuid, text, uuid) IS
  'Sprint 4.12 (mig 00284) per ConsistencyAudit F8. Canonical RPC replacing direct UPDATE from edge function. Emits assetBookingsLocked atom, then writes cache resources.metadata.bookings_locked=true. Idempotent against asset_booking_lock_view. Callable from cron (auth.uid() null bypasses admin check).';
COMMENT ON FUNCTION public.unlock_asset_bookings(uuid, text) IS
  'Sprint 4.12 (mig 00284) per ConsistencyAudit F8. Symmetric to lock_asset_bookings; emits assetBookingsUnlocked atom + clears cache.';
COMMENT ON VIEW public.asset_booking_lock_view IS
  'Sprint 4.12 (mig 00284). Atom-derived canonical is_locked state per asset. Replaces metadata.bookings_locked as source of truth (which becomes operational cache).';
