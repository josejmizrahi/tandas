-- Mig 00205: Re-reconcile is_known_system_event_type whitelist after
-- right_expiration_warning clobber.
--
-- Bug
-- ===
-- Mig 00203_right_expiration_warning (right branch) and mig 00204_whitelist_reconcile
-- (main branch) landed in parallel. Mig 00204 already shipped the union of
-- all parallel branches (right + asset + event-links + event-cancelled).
-- Mig 00203 then did its own full-body `create or replace function` to
-- ADD `rightExpiringSoon`, but because mig 00203 was written BEFORE
-- mig 00204 was visible, it only included the right-branch values it
-- knew about — dropping `assetTransferred`, `assetAssigned`,
-- `assetReturned`, `custodyAssigned`, `custodyReleased`,
-- `maintenanceLogged`, `maintenanceCompleted`, `damageReported`,
-- `assetUsed`, `assetCheckedOut`, `assetCheckedIn`, `valuationRecorded`,
-- `resourceLinked`, `resourceUnlinked`, `eventCancelled`, plus
-- `fundLocked`, `fundUnlocked`.
--
-- Repro: `select public.is_known_system_event_type('assetTransferred')`
-- returned `false` on prod after mig 00203 landed.
--
-- Fix
-- ===
-- Ship the union again, plus `rightExpiringSoon`. Future migrations
-- should follow mig 00204's note: add ONE value at a time via append
-- rather than full-body replace, so a parallel-branch addition doesn't
-- get clobbered.

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
    'eventCancelled'
  ]);
$$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist of system_events.event_type values. v_post_reconcile_2 (00205): union of all parallel branches + rightExpiringSoon. CHECK constraint system_events_event_type_known_chk (00095) enforces this at INSERT. Future migrations: prefer tactical add over full-body replace.';
