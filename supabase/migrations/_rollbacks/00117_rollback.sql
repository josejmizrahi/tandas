-- 00117_rollback.sql
-- Reverts is_known_system_event_type to the 00095 shape (without
-- `pendingChangeApplied`). Any pendingChangeApplied rows already in
-- system_events stay — the CHECK constraint validates new inserts only.
-- WARNING: rolling back re-introduces the check_violation that blocks
-- apply_pending_change. Only run if `pendingChangeApplied` needs to be
-- temporarily quarantined for a different reason.

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable
parallel safe
set search_path = public
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
