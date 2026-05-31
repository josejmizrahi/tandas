-- 00269 — Whitelist `bookingNoCheckIn` synthetic atom.
--
-- Plans/Active/SpaceRules.md PR-2 — adds the synthetic atom that the
-- `emit-space-no-check-in-events` cron will emit when a booking on a
-- space passes its starts_at without a matching checkInRecorded.
--
-- The cron lives in supabase/functions/emit-space-no-check-in-events/
-- and is scheduled via pg_cron (separate migration).
--
-- The atom is "synthetic" — no user-facing RPC fires it. The cron is
-- the canonical writer. Engine evaluators in PR-3 will consume the
-- atom to drive `space_no_check_in_release` rule template (releases
-- the booking by calling expire_booking).
--
-- `is_known_system_event_type` is a single CREATE OR REPLACE — the
-- whitelist below is the UNION of every prior atom plus `bookingNoCheckIn`.

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable
parallel safe
set search_path = pg_catalog
as $function$
  select p_event_type = any (array[
    -- Event lifecycle
    'eventClosed', 'eventCreated', 'rsvpDeadlinePassed', 'hoursBeforeEvent',
    'eventCancelled', 'eventStarted', 'eventUpdated',
    -- RSVP / attendance
    'rsvpSubmitted', 'rsvpChangedSameDay', 'checkInRecorded', 'checkInMissed',
    'eventDescriptionMissing',
    -- Slot
    'slotAssigned', 'slotDeclined', 'slotExpired', 'slotSwapRequested', 'slotSwapApproved',
    -- Booking (atom-level, shared across slot/space/asset)
    'bookingCreated', 'bookingCancelled', 'bookingExpired',
    -- mig 00269: synthetic atom emitted by emit-space-no-check-in-events cron.
    -- Plans/Active/SpaceRules.md PR-2.
    'bookingNoCheckIn',
    -- Asset
    'assetCreated', 'assetTransferred', 'assetAssigned', 'assetReturned',
    'custodyAssigned', 'custodyReleased',
    'maintenanceLogged', 'maintenanceCompleted', 'damageReported',
    'assetUsed', 'assetCheckedOut', 'assetCheckedIn',
    'valuationRecorded',
    'assetCheckoutOverdue', 'assetMaintenanceOverdue',
    -- Fines + appeals + votes
    'fineOfficialized', 'fineVoided', 'finePaid', 'fineReminderSent',
    'appealCreated', 'appealResolved',
    'voteOpened', 'voteCast', 'voteResolved',
    -- Fund
    'fundCreated', 'fundDeposit', 'fundThresholdReached',
    'fundLocked', 'fundUnlocked',
    -- Space (mig 00207 + 00264 — canonical space spec §9)
    'spaceCreated',
    'spaceBooked', 'spaceReleased', 'spaceCapacityReached',
    'spaceWaitlistJoined', 'spaceWaitlistPromoted',
    'spaceAccessGranted', 'spaceAccessRevoked',
    -- Rotation / membership
    'positionChanged', 'memberJoined', 'memberLeft',
    -- Rule audit
    'ruleEnabledChanged', 'ruleAmountChanged',
    -- Governance
    'pendingChangeApplied', 'inviteCodeRotated',
    -- Group lifecycle
    'groupCreated', 'groupArchived', 'groupUnarchived', 'groupRenamed', 'governanceUpdated',
    -- Resource lifecycle (generic across all resource_types)
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    -- Capability lifecycle
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    -- Money / governance side-effects
    'ledgerEntryCreated', 'warningEmitted',
    -- Right lifecycle
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    'rightExpiringSoon',
    -- Resource links (event uses space/asset/fund/right)
    'resourceLinked', 'resourceUnlinked',
    -- Role lifecycle
    'roleAssigned', 'roleUnassigned'
  ]);
$function$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist check for system_events.event_type values. Mirrors the SystemEventType Swift enum. v13 (00269): adds bookingNoCheckIn synthetic atom emitted by emit-space-no-check-in-events cron (Plans/Active/SpaceRules.md PR-2).';
