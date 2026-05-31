-- 00117 — Add `pendingChangeApplied` to the system_event whitelist.
--
-- The SystemEventType Swift enum grew a `pendingChangeApplied` case
-- (consumed by apply_pending_change in mig 00089 + iOS History view)
-- but the SQL whitelist + CHECK constraint from 00092/00095 didn't
-- get updated. Net effect: any call to apply_pending_change would
-- raise `check_violation` on the system_events INSERT.
--
-- Caught by the codegen sync test
-- (supabase/functions/_tests/system_event_whitelist_sync.test.ts).
-- Future drift will surface in CI before reaching prod again.

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable
parallel safe
set search_path = public
as $$
  -- Keep in sync with
  -- ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/SystemEventType.swift
  -- and supabase/functions/_shared/types/systemEventType.ts.
  select p_event_type = any (array[
    'eventClosed',
    'eventCreated',
    'rsvpDeadlinePassed',
    'hoursBeforeEvent',
    'rsvpSubmitted',
    'rsvpChangedSameDay',
    'checkInRecorded',
    'checkInMissed',
    'eventDescriptionMissing',
    'slotAssigned',
    'slotDeclined',
    'slotExpired',
    'slotSwapRequested',
    'slotSwapApproved',
    'bookingCreated',
    'bookingCancelled',
    'bookingExpired',
    'assetCreated',
    'fineOfficialized',
    'fineVoided',
    'finePaid',
    'fineReminderSent',
    'appealCreated',
    'appealResolved',
    'voteOpened',
    'voteCast',
    'voteResolved',
    'fundDeposit',
    'fundThresholdReached',
    'positionChanged',
    'memberJoined',
    'memberLeft',
    'ruleEnabledChanged',
    'ruleAmountChanged',
    'pendingChangeApplied'
  ]);
$$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist check for system_events.event_type values. Mirrors the SystemEventType Swift enum. Update + redeploy whenever the enum grows. CHECK constraint system_events_event_type_known_chk (00095) enforces this at INSERT time.';
