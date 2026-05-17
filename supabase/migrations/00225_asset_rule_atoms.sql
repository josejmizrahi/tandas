-- Mig 00225 — Asset rule atoms (Plans/Active/AssetRules.md §2 + §5)
--
-- Adds two synthetic asset atoms emitted by the new
-- `emit-asset-overdue-events` cron (mig 00227 wires the cron schedule,
-- the edge function code itself ships in the supabase/functions tree):
--
--   - assetCheckoutOverdue    fires when an `assetCheckedOut` row's
--                             `expected_return_at` has passed AND no
--                             matching `assetCheckedIn` row closed it.
--                             Drives the `not_returned_fine` template.
--   - assetMaintenanceOverdue fires when a `maintenanceLogged` row has
--                             not been closed (`maintenanceCompleted`)
--                             within the configured grace window AND
--                             no `damageReported` re-escalated it.
--                             Drives the `maintenance_overdue_lock`
--                             template.
--
-- Whitelist snapshot
-- ==================
-- CREATE OR REPLACE rewrites the function body wholesale, so every
-- prior atom must stay in the array or it silently falls off the
-- `system_events_event_type_known_chk` check. Mig 00219 already
-- documents the discipline: append-only at the bottom, never replace
-- a prior entry. We snapshot the post-00219 + post-00214 union (which
-- mig 00219 had partially dropped — restored here defensively per the
-- "if you replace the whole function, you own restoring everything"
-- comment) and append the 2 new atoms.
--
-- Source of truth: `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/SystemEventType.swift`
-- + `supabase/functions/_shared/types/systemEventType.ts` (both extended
-- in the same commit as this migration; codegen reconciles them).

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable parallel safe
set search_path = pg_catalog
as $function$
  -- Post mig 00214 union + post mig 00219 right_* restoration + post
  -- mig 00210_event_updated + mig 00207 (spaceCreated). Mig 00225
  -- appends the 2 new asset-overdue atoms at the end.
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
    -- right_* canonical (post mig 00198 + 00203 + 00219 restoration)
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    'rightExpiringSoon',
    -- asset_universal (post mig 00204)
    'assetTransferred', 'assetAssigned', 'assetReturned',
    'custodyAssigned', 'custodyReleased',
    'maintenanceLogged', 'maintenanceCompleted', 'damageReported',
    'assetUsed', 'assetCheckedOut', 'assetCheckedIn',
    'valuationRecorded',
    -- resource links + event lifecycle (post mig 00202 + 00210 + 00214)
    'resourceLinked', 'resourceUnlinked',
    'eventCancelled', 'eventStarted', 'eventUpdated',
    -- space (post mig 00207)
    'spaceCreated',
    -- mig 00225: asset rule overdue atoms (Plans/Active/AssetRules.md §5).
    -- Emitted by emit-asset-overdue-events cron (1/min).
    'assetCheckoutOverdue', 'assetMaintenanceOverdue'
  ]);
$function$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist gate for system_events.event_type. v10 (00225): adds assetCheckoutOverdue + assetMaintenanceOverdue. Append-only — future additions go at the end of the array, never replace prior entries.';
