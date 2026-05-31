-- 00292 — Add identityPromoted atom + re-add groupRolesChanged (lost AGAIN).
--
-- Plans/Active/RolesRemediation_2026-05-17.md Sprint D.
-- Closes V25 (verify-otp emits no atom on anon→phone upgrade).
--
-- Retrospective
-- =============
-- Mig 00288 (Sprint B recovery) added groupRolesChanged and embedded
-- this exact warning: "every modification MUST re-emit the FULL UNION".
-- Subsequent parallel migrations landed assetBookingsLocked/Unlocked +
-- memberCapabilityOverrideDeactivated and AGAIN dropped groupRolesChanged.
--
-- This is the SECOND time this happens. The whitelist-as-array-in-fn
-- pattern is structurally fragile against parallel work. Sprint F should
-- migrate to a `known_event_types` TABLE that gets INSERT'd into, not a
-- function body that gets REPLACED.
--
-- For now: union the live body + groupRolesChanged + identityPromoted.

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
    'slotCreated', 'slotReleased',
    -- Booking (atom-level, shared across slot/space/asset)
    'bookingCreated', 'bookingCancelled', 'bookingExpired', 'bookingNoCheckIn',
    -- Asset
    'assetCreated', 'assetTransferred', 'assetAssigned', 'assetReturned',
    'custodyAssigned', 'custodyReleased',
    'maintenanceLogged', 'maintenanceCompleted', 'damageReported',
    'assetUsed', 'assetCheckedOut', 'assetCheckedIn', 'valuationRecorded',
    'assetCheckoutOverdue', 'assetMaintenanceOverdue',
    'assetBookingsLocked', 'assetBookingsUnlocked',
    -- Fines + appeals + votes
    'fineOfficialized', 'fineVoided', 'finePaid', 'fineReminderSent',
    'appealCreated', 'appealResolved',
    'voteOpened', 'voteCast', 'voteResolved',
    -- Fund
    'fundCreated', 'fundDeposit', 'fundThresholdReached',
    'fundLocked', 'fundUnlocked',
    -- Space
    'spaceCreated', 'spaceBooked', 'spaceReleased', 'spaceCapacityReached',
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
    -- Resource lifecycle
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    -- Capability lifecycle
    'capabilityToggled', 'capabilityConfigUpdated',
    'memberCapabilityOverridden', 'memberCapabilityOverrideDeactivated',
    -- Money / governance side-effects
    'ledgerEntryCreated', 'warningEmitted',
    -- Right lifecycle
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    'rightExpiringSoon', 'rightMetadataUpdated',
    -- Resource links
    'resourceLinked', 'resourceUnlinked',
    -- Role lifecycle (per-member)
    'roleAssigned', 'roleUnassigned',
    -- mig 00288/00292: role catalog mutation atom (REUNION, lost twice)
    -- Emitted by upsert_group_role + delete_group_role (mig 00286/00289)
    'groupRolesChanged',
    -- mig 00292 (Sprint D): identity promotion atom
    -- Emitted by verify-otp edge function on anon→phone upgrade
    'identityPromoted'
  ]);
$function$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist for system_events.event_type. v16 (00292): adds identityPromoted + re-adds groupRolesChanged (lost twice to parallel migrations). DOCTRINE: every modification MUST re-emit the FULL UNION starting from pg_dump of live source, never from a previous migration. Long-term fix: migrate to a known_event_types table (Sprint F).';
