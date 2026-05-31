-- 00258 — Re-emit the full is_known_system_event_type whitelist after
-- the 00206-00211 → 00252-00257 rename batch.
--
-- The May-16 right_*/event_updated migrations originally numbered
-- 00207/00208/00210 each carried a `create or replace function
-- public.is_known_system_event_type` with the whitelist as it stood
-- at THAT moment in time. After CI-driven renames to 00253/00254/00256,
-- those older definitions now run AFTER mig 00231 (which had the full
-- post-Phase 5 whitelist), so 00256_event_updated_atom's older list
-- wipes the newer entries.
--
-- Symptom: `deno run -A scripts/codegen/check-sql-whitelist-drift.ts`
-- reports `assetCheckoutOverdue, assetMaintenanceOverdue, roleAssigned,
-- roleUnassigned, spaceCreated` as in-Swift-but-missing-from-SQL.
--
-- Fix: re-emit the full union one more time, after the renamed batch.
-- Authoring rule (per 00211 / 00231): always emit the full whitelist,
-- never tactical appends.
--
-- Idempotent (CREATE OR REPLACE).
-- Rollback: revert to 00256_event_updated_atom's body — but you'd
-- re-introduce the drift, so this rollback is no-op-friendly.

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
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    'rightExpiringSoon',
    'assetTransferred', 'assetAssigned', 'assetReturned',
    'custodyAssigned', 'custodyReleased',
    'maintenanceLogged', 'maintenanceCompleted', 'damageReported',
    'assetUsed', 'assetCheckedOut', 'assetCheckedIn',
    'valuationRecorded',
    'resourceLinked', 'resourceUnlinked',
    'eventCancelled',
    'eventStarted', 'eventUpdated',
    'spaceCreated',
    'assetCheckoutOverdue', 'assetMaintenanceOverdue',
    'roleAssigned', 'roleUnassigned'
  ]);
$$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist of system_events.event_type values. v_post_rename (00258): re-emits the 00231 union after the rename batch shifted 00210_event_updated_atom to 00256, where its older whitelist overrode the post-Phase 5 entries. Mirrors SystemEventType Swift enum.';
