-- 00093 — Tighten search_path + role grants on the system_event
-- validation pair introduced in 00092. Two advisor findings surfaced
-- after the 00092 deploy:
--
--   1. function_search_path_mutable on is_known_system_event_type
--      → SQL functions need an explicit search_path even when IMMUTABLE,
--        otherwise a caller can shadow `array` / cast functions via a
--        local schema. Pin to public so the array literal resolves.
--
--   2. anon_security_definer_function_executable on record_system_event
--      → pre-existing (inherited from 00014's missing REVOKE) — anon
--        could invoke a SECURITY DEFINER function and insert
--        system_events for any group_id. Tighten to the same pattern
--        create_initial_rule / has_permission already use
--        (authenticated + service_role only).

-- Re-create with set search_path = public.
create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable
parallel safe
set search_path = public
as $$
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
    'ruleAmountChanged'
  ]);
$$;

-- Lock down execute privileges on both functions.
revoke execute on function public.is_known_system_event_type(text) from public, anon;
grant  execute on function public.is_known_system_event_type(text) to authenticated, service_role;

revoke execute on function public.record_system_event(uuid, text, uuid, uuid, jsonb) from public, anon;
grant  execute on function public.record_system_event(uuid, text, uuid, uuid, jsonb) to authenticated, service_role;
