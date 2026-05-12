-- 00093_rollback.sql
-- Reverts grants on the system_event validation pair to the pre-00093
-- state (PUBLIC + anon EXECUTE), and drops the search_path pin on
-- is_known_system_event_type.
--
-- This restores the pre-existing security exposure on record_system_event
-- (anon could insert system_events for any group_id). Only run if 00093
-- broke a caller that was depending on anon-role access — none should,
-- since iOS uses authenticated and edge functions use service_role.

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable
parallel safe
as $$
  select p_event_type = any (array[
    'eventClosed','eventCreated','rsvpDeadlinePassed','hoursBeforeEvent',
    'rsvpSubmitted','rsvpChangedSameDay','checkInRecorded','checkInMissed',
    'eventDescriptionMissing','slotAssigned','slotDeclined','slotExpired',
    'slotSwapRequested','slotSwapApproved','bookingCreated','bookingCancelled',
    'bookingExpired','assetCreated','fineOfficialized','fineVoided',
    'finePaid','fineReminderSent','appealCreated','appealResolved',
    'voteOpened','voteCast','voteResolved','fundDeposit',
    'fundThresholdReached','positionChanged','memberJoined','memberLeft',
    'ruleEnabledChanged','ruleAmountChanged'
  ]);
$$;

grant execute on function public.is_known_system_event_type(text) to public, anon;
grant execute on function public.record_system_event(uuid, text, uuid, uuid, jsonb) to public, anon;
