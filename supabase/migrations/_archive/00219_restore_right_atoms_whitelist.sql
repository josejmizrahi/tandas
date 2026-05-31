-- 00205 — restore `right*` system event atoms to is_known_system_event_type
--
-- Regression fix. Mig 00198_right_resource_canonical seeded 8 right_* atoms
-- (`rightCreated, rightTransferred, rightDelegated, rightRevoked,
-- rightExpired, rightExercised, rightSuspended, rightRestored`) into the
-- whitelist. Mig 00203 introduced `rightExpiringSoon` as the 9th. A
-- subsequent migration (likely `event_resource_links` or `event_cancelled_atom`
-- — both visible in the prod migrations list but missing from the local
-- repo) replaced `is_known_system_event_type` wholesale without
-- preserving the right_* entries.
--
-- Symptom: any INSERT into `system_events` with `event_type LIKE 'right%'`
-- raises `check_violation` from `system_events_event_type_known_chk`.
-- All 9 right RPCs (`create_right`, `transfer_right`, `delegate_right`,
-- `revoke_right`, `suspend_right`, `restore_right`, `exercise_right`,
-- and the rightExpiring crons) silently produce zero downstream signal,
-- which means the rule engine can't react to right lifecycle either.
--
-- Today the breakage is invisible because prod has zero right resources
-- (verified 2026-05-15). Fixing it now restores correctness before
-- anyone tries to create one.
--
-- Both Swift (`SystemEventType.swift`) and the shared TS catalog
-- (`_shared/types/systemEventType.ts`) already declare all 9 cases —
-- the gap is purely SQL. No client-side change needed.
--
-- Snapshot
-- ========
-- This rewrite mirrors the prod array (post mig 00203) verbatim and
-- appends the 9 right_* atoms in a single block. Every entry currently
-- in the whitelist stays. Append-only doctrine for the catalog: future
-- additions go at the end of the array, never replacing prior entries.

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable parallel safe
set search_path = pg_catalog
as $function$
  -- Snapshot of prod array (post mig 00203) plus 9 right_* atoms (mig
  -- 00205). CREATE OR REPLACE rewrites the body wholesale, so every
  -- prior entry must stay. New atoms always append at the end.
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
    'positionChanged', 'memberJoined', 'memberLeft',
    'ruleEnabledChanged', 'ruleAmountChanged',
    'pendingChangeApplied', 'inviteCodeRotated',
    'groupCreated', 'groupArchived', 'groupUnarchived', 'groupRenamed', 'governanceUpdated',
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    'ledgerEntryCreated', 'warningEmitted',
    'resourceLinked', 'resourceUnlinked',
    'eventCancelled',
    'fundLocked', 'fundUnlocked',
    'spaceCreated',
    -- mig 00205: restored right_* lifecycle atoms (regressed by a prior
    -- whitelist rewrite that did not preserve mig 00198's seed).
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    'rightExpiringSoon'
  ]);
$function$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist gate for system_events.event_type. v9 (00205): restored 9 right_* atoms regressed by a prior whitelist rewrite. Append-only — future additions go at the end of the array, never replace prior entries.';
