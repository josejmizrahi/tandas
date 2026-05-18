-- 00285 — Extend is_known_system_event_type with groupRolesChanged.
-- (Originally numbered 00278; renumbered to 00285 because parallel work
-- claimed 00278..00284 in untracked files. Live DB applied this under
-- timestamp 20260518040913 / name role_lifecycle_atom_whitelist_v2.)
--
-- Pairs with mig 00286 (upsert_group_role / delete_group_role emit
-- groupRolesChanged on catalog mutation). Without this whitelist
-- the emit fails the CHECK constraint (00095) and the RPC aborts
-- after mutating the catalog — partial state.
--
-- IMPORTANT: this entry was silently dropped by parallel migrations
-- that landed AFTER live-apply. Mig 00288 (reunion) re-adds it. Treat
-- the current file as historical only.
--
-- Per the convention established in mig 00211 / 00231 / 00269: the
-- function is a single CREATE OR REPLACE — the array below is the
-- UNION of every prior atom plus the new entry. We start from mig
-- 00269 (most recent whitelist, includes bookingNoCheckIn).
--
-- New entry: groupRolesChanged — emitted by upsert_group_role and
-- delete_group_role when the role catalog mutates. Sprint B of the
-- RolesRemediation plan (Plans/Active/RolesRemediation_2026-05-17.md).

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
    -- Space
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
    'roleAssigned', 'roleUnassigned',
    -- mig 00285 (was 00278, Sprint B): role catalog mutation atom.
    -- Emitted by upsert_group_role + delete_group_role (mig 00286).
    'groupRolesChanged'
  ]);
$function$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist check for system_events.event_type values. Mirrors the SystemEventType Swift enum. v14 (00285, was 00278): adds groupRolesChanged for role catalog mutations (Plans/Active/RolesRemediation_2026-05-17.md Sprint B). SUPERSEDED by 00288 after parallel migrations dropped the entry.';
