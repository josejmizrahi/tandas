-- 00288 — Re-add groupRolesChanged to is_known_system_event_type.
-- (Originally numbered 00281; renumbered to 00288 — parallel work
-- claimed 00278..00284. Live applied under timestamp 20260518 / name
-- role_lifecycle_atom_whitelist_v3_reunion.)
--
-- Sprint B doctrinal-failure recovery: mig 00285 (was 00278) added
-- groupRolesChanged to the whitelist. Subsequent migrations landed
-- in parallel (slot_created_released_atoms, update_right_metadata_emit_diff_atom)
-- that re-emitted is_known_system_event_type using a stale base array
-- — silently dropping groupRolesChanged. The comment on the function
-- still claimed v14 (groupRolesChanged) because pg_dump-style snapshots
-- preserved it, but the body lost the entry.
--
-- Consequence: upsert_group_role / delete_group_role v3 (mig 00286)
-- raise CHECK violation on every call (system_events_event_type_known_chk).
-- Both RPCs are TOTALLY BROKEN until this lands.
--
-- This migration UNIONs:
--   - the current live whitelist body (includes the slot/right additions
--     that landed parallel to my work — preserved as-is here)
--   - groupRolesChanged
--
-- Going forward, whoever modifies this function MUST re-emit the FULL
-- union — that's the convention from mig 00211, broken once here, now
-- restored.

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
    -- Resource lifecycle (generic across all resource_types)
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    -- Capability lifecycle
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    -- Money / governance side-effects
    'ledgerEntryCreated', 'warningEmitted',
    -- Right lifecycle
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    'rightExpiringSoon', 'rightMetadataUpdated',
    -- Resource links (event uses space/asset/fund/right)
    'resourceLinked', 'resourceUnlinked',
    -- Role lifecycle (per-member assign/unassign)
    'roleAssigned', 'roleUnassigned',
    -- mig 00288 (was 00281, Sprint B recovery): role catalog mutation atom.
    -- Originally landed in mig 00285 (was 00278); dropped by parallel migrations.
    -- Emitted by upsert_group_role + delete_group_role v3 (mig 00286).
    'groupRolesChanged'
  ]);
$function$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist check for system_events.event_type values. Mirrors the SystemEventType Swift enum. v15 (00288, was 00281): re-adds groupRolesChanged after parallel migrations dropped it. CONVENTION: every modification MUST re-emit the FULL UNION (see mig 00211 / 00288 retrospective).';
