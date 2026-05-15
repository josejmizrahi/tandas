-- Mig 00204: Reconcile is_known_system_event_type whitelist
--
-- Applied to prod under the snake_case name
-- `whitelist_reconcile_right_and_event_links`.
--
-- Bug history
-- ===========
-- Three parallel feature branches each shipped a CREATE OR REPLACE
-- function definition of is_known_system_event_type without first
-- pulling each other's values:
--   - right_resource_canonical       (added: rightCreated, rightTransferred,
--                                     rightDelegated, rightRevoked, rightExpired,
--                                     rightExercised, rightSuspended, rightRestored)
--   - 00198_asset_universal_atoms    (added: assetTransferred, assetAssigned,
--                                     assetReturned, custodyAssigned,
--                                     custodyReleased, maintenanceLogged,
--                                     maintenanceCompleted, damageReported,
--                                     assetUsed, assetCheckedOut,
--                                     assetCheckedIn, valuationRecorded)
--   - 00202 event_resource_links + 00203 event_cancelled_atom
--                                    (added: resourceLinked, resourceUnlinked,
--                                     eventCancelled)
--
-- Each subsequent migration's full-body CREATE OR REPLACE dropped the
-- prior branches' additions. Pre-reconcile prod had asset* + fund* but
-- was missing right* and event-links values, so record_system_event()
-- calls for those raise NOTICE + the CHECK constraint
-- system_events_event_type_known_chk rejects the INSERT.
--
-- This migration ships the union of all values. Future migrations should
-- prefer a tactical pattern (add ONE value at a time) over the full-body
-- replace to avoid re-introducing the clobber bug.

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
    -- right_resource_canonical
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    -- 00198_asset_universal_atoms
    'assetTransferred', 'assetAssigned', 'assetReturned',
    'custodyAssigned', 'custodyReleased',
    'maintenanceLogged', 'maintenanceCompleted', 'damageReported',
    'assetUsed', 'assetCheckedOut', 'assetCheckedIn',
    'valuationRecorded',
    -- 00202 event_resource_links + 00203 event_cancelled_atom
    'resourceLinked', 'resourceUnlinked',
    'eventCancelled'
  ]);
$$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist of system_events.event_type values. v_post_reconcile: union of right_resource_canonical + asset_universal_atoms + event_resource_links + event_cancelled_atom branches. CHECK constraint system_events_event_type_known_chk (00095) enforces this at INSERT. Future migrations: prefer tactical add over full-body replace.';
