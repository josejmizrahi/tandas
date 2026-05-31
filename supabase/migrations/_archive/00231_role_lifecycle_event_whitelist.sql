-- 00231 — Extend is_known_system_event_type whitelist with role lifecycle atoms.
--
-- Pairs with mig 00229 (assign_role / unassign_role RPCs). Both emit
-- via record_system_event, which 00094 gates on
-- is_known_system_event_type. Without this extension the INSERT trips
-- the CHECK constraint (00095) and the RPC fails after applying the
-- role mutation — partial state.
--
-- Whitelist authoring rule (per mig 00211): re-emit the FULL union
-- rather than tactical appends; a parallel branch landing between this
-- migration and the next would otherwise silently drop entries.

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable parallel safe
set search_path = pg_catalog
as $$
  select p_event_type = any (array[
    'eventClosed', 'eventCreated', 'rsvpDeadlinePassed', 'hoursBeforeEvent',
    'rsvpSubmitted', 'rsvpChangedSameDay', 'checkInRecorded', 'checkInMissed',
    'eventDescriptionMissing',
    'slotAssigned', 'slotDeclined', 'slotExpired', 'slotSwapRequested', 'slotSwapApproved',
    'bookingCreated', 'bookingCancelled', 'bookingExpired',
    'assetCreated',
    'fineOfficialized', 'fineVoided', 'finePaid', 'fineReminderSent',
    'appealCreated', 'appealResolved',
    'voteOpened', 'voteCast', 'voteResolved',
    'fundCreated', 'fundDeposit', 'fundThresholdReached', 'fundLocked', 'fundUnlocked',
    'positionChanged', 'memberJoined', 'memberLeft',
    'ruleEnabledChanged', 'ruleAmountChanged',
    'pendingChangeApplied', 'inviteCodeRotated',
    'groupCreated', 'groupArchived', 'groupUnarchived', 'groupRenamed', 'governanceUpdated',
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    'ledgerEntryCreated', 'warningEmitted',
    -- right_resource_canonical + right_expiration_warning
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    'rightExpiringSoon',
    -- asset_universal_atoms
    'assetTransferred', 'assetAssigned', 'assetReturned',
    'custodyAssigned', 'custodyReleased',
    'maintenanceLogged', 'maintenanceCompleted', 'damageReported',
    'assetUsed', 'assetCheckedOut', 'assetCheckedIn',
    'valuationRecorded',
    -- event_resource_links + event_cancelled_atom
    'resourceLinked', 'resourceUnlinked',
    'eventCancelled',
    -- mig 00214 + 00210
    'eventStarted', 'eventUpdated',
    -- mig 00203
    'spaceCreated',
    -- mig 00225 asset rule overdue atoms
    'assetCheckoutOverdue', 'assetMaintenanceOverdue',
    -- mig 00231: Phase 5 role lifecycle atoms (assign_role / unassign_role)
    'roleAssigned', 'roleUnassigned'
  ]);
$$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist of system_events.event_type values. v_post_phase5_roles (00231): adds roleAssigned + roleUnassigned. Mirrors SystemEventType Swift enum. CHECK constraint system_events_event_type_known_chk (00095) enforces this at INSERT.';
