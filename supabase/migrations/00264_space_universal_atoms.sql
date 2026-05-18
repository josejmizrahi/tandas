-- 00264 — Space universal atoms (canonical space spec §9).
--
-- Plans/Active/Space.md ships the canonical model: space coordinates
-- occupation / availability / capacity / access via atoms + projections.
-- Mig 00207 created `spaceCreated`; the lifecycle ended there. Without
-- the 7 space.* atoms below the rule engine, projections, and UI cannot
-- derive occupancy state from atoms (they'd have no atoms to fold).
--
-- This migration extends the SystemEventType whitelist with the canonical
-- space atoms (spec §9):
--
--   Booking lifecycle:    space.booked, space.released, space.capacity_reached
--   Waitlist:             space.waitlist_joined, space.waitlist_promoted
--   Access control:       space.access_granted, space.access_revoked
--
-- Notes:
--   - `bookingCreated`/`bookingCancelled`/`bookingExpired` already in
--     whitelist (mig 00207/00204). Space-scoped booking lifecycle reuses
--     those atoms (booking is action, not space-specific). `spaceBooked` /
--     `spaceReleased` are coarser atoms emitted when the *entire* space
--     is claimed/released (vs a single slot inside it) — they let
--     projections distinguish "Palco entero reservado por Maria viernes"
--     from "slot 19:00 reservado by Jose".
--   - `checkInRecorded` is also reused; the projection filters by
--     `resource_id IN (SELECT id FROM resources WHERE resource_type='space')`.
--   - `resourceArchived`/`resourceUnarchived`/`resourceRenamed` already
--     cover the generic space lifecycle (mig 00186).
--
-- `is_known_system_event_type` is a single CREATE OR REPLACE — the
-- whitelist below is the UNION of every prior whitelist plus the 7 new
-- space atoms. Every prior atom must be repeated or it falls off the
-- whitelist on the next replace. The list mirrors prod state at
-- migration 00263 (separate_founder_from_admin / sync_role_text).

-- =============================================================================
-- 1. Extend the SystemEventType whitelist
-- =============================================================================

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable
parallel safe
set search_path = pg_catalog
as $function$
  -- Keep in sync with
  -- ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/SystemEventType.swift
  -- and supabase/functions/_shared/types/systemEventType.ts.
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
    -- mig 00264: space lifecycle atoms (Plans/Active/Space.md §9)
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
  'Whitelist check for system_events.event_type values. Mirrors the SystemEventType Swift enum. v12 (00264): adds 7 space.* lifecycle atoms (spaceBooked, spaceReleased, spaceCapacityReached, spaceWaitlistJoined, spaceWaitlistPromoted, spaceAccessGranted, spaceAccessRevoked) per Plans/Active/Space.md §9.';
