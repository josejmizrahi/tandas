-- Mig 00203 — Asset universal atoms (canonical asset spec).
--
-- The canonical asset spec frames `resource_type='asset'` as a universal
-- "objeto persistente socialmente gobernable": car, speakers, palco, NFT,
-- equity, IP, locker, document, license, hardware, etc. Until now the
-- only asset-specific atom was `assetCreated` (mig 00070); creation +
-- archive was the entire lifecycle the system could record.
--
-- This migration extends the SystemEventType whitelist with the
-- canonical asset atoms (spec §13):
--
--   Lifecycle:  asset.transferred, asset.assigned, asset.returned
--   Custody:    custody.assigned, custody.released
--   Maintenance maintenance.logged, maintenance.completed,
--               damage.reported
--   Usage:      asset.used, asset.checked_out, asset.checked_in
--   Valuation:  valuation.recorded
--
-- Atoms are the only mutation surface for the asset model — projections
-- (current_custodian_view, asset_valuation_view, maintenance_status_view,
-- usage_history_view) derive from them. Append-only by design.
--
-- Notes:
-- - `assetCreated` already in whitelist via mig 00193; kept here for
--   readability of the canonical set.
-- - `bookingCreated` already covers the "asset.booked" atom from spec
--   §13. We do not duplicate it.
-- - `resourceArchived` already covers the "asset.archived" atom (generic
--   across all resource_types via mig 00186 trigger). We do not duplicate
--   it either.
-- - Renumbered from 00198 → 00203 to land after the right-resource
--   migrations 00198–00201 that landed on main concurrently.
--   `is_known_system_event_type` is a single CREATE OR REPLACE — the
--   whitelist below is the UNION of mig 00193 (warning/ledger), mig
--   00198 (fund lock), mig 00198_right (right.*), and the 12 new asset
--   atoms; every prior atom must be repeated or it falls off the
--   whitelist on the next replace.

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
    'eventClosed', 'eventCreated', 'rsvpDeadlinePassed', 'hoursBeforeEvent',
    'rsvpSubmitted', 'rsvpChangedSameDay', 'checkInRecorded', 'checkInMissed',
    'eventDescriptionMissing',
    'slotAssigned', 'slotDeclined', 'slotExpired', 'slotSwapRequested', 'slotSwapApproved',
    'bookingCreated', 'bookingCancelled', 'bookingExpired',
    'assetCreated',
    'fineOfficialized', 'fineVoided', 'finePaid', 'fineReminderSent',
    'appealCreated', 'appealResolved',
    'voteOpened', 'voteCast', 'voteResolved',
    'fundCreated', 'fundDeposit', 'fundThresholdReached',
    -- mig 00198: fund lock lifecycle
    'fundLocked', 'fundUnlocked',
    'positionChanged', 'memberJoined', 'memberLeft',
    'ruleEnabledChanged', 'ruleAmountChanged',
    'pendingChangeApplied', 'inviteCodeRotated',
    'groupCreated', 'groupArchived', 'groupUnarchived', 'groupRenamed', 'governanceUpdated',
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    -- pre-existing prod atoms preserved (event_resource_links, event_cancelled_atom)
    'resourceLinked', 'resourceUnlinked',
    'eventCancelled',
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    'ledgerEntryCreated', 'warningEmitted',
    -- mig 00198_right: right.* lifecycle atoms
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    -- mig 00203: canonical asset spec atoms (§13)
    'assetTransferred', 'assetAssigned', 'assetReturned',
    'custodyAssigned', 'custodyReleased',
    'maintenanceLogged', 'maintenanceCompleted', 'damageReported',
    'assetUsed', 'assetCheckedOut', 'assetCheckedIn',
    'valuationRecorded'
  ]);
$function$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist check for system_events.event_type values. Mirrors the SystemEventType Swift enum. v11 (00203): full union — fund lock + right lifecycle + resource link + event cancellation + 12 asset universal atoms.';
