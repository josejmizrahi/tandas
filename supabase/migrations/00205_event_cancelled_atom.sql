-- Mig 00203: `eventCancelled` lifecycle atom (Plans/Active/EventResource.md §8)
--
-- (Originally drafted as 00199 on the event-resource-specification branch
-- and applied to prod under the snake_case name `event_cancelled_atom`.
-- Renumbered to 00203 at merge time — see 00202 for context. Prod
-- state is unaffected: migration tracking is by name.)
--
-- Today `cancel_event` (mig 00158) emits a generic `eventClosed` atom
-- with `status: cancelled` in the payload, the same atom that `close_event`
-- emits when an event ends. The rule engine's `eventClosed` evaluator
-- doesn't distinguish, so a cancellation runs the same fine-enumeration
-- pipeline as a completion — which the spec rejects (§8 lists
-- `event.cancelled` as a distinct atom; §17 says "real states derive from
-- atoms", and "cancelled" and "ended" are different real states).
--
-- This migration is additive — it does NOT remove the legacy
-- `eventClosed` emission from `cancel_event`, so existing rule-engine
-- consumers keep working unchanged. It adds a new `eventCancelled` atom
-- emitted by a trigger on `resources` whenever status transitions to
-- 'cancelled' for an event. That covers the RPC path AND any future
-- code that flips status directly. A follow-up can:
--   1. Re-point rule shapes from `eventClosed` to `eventCancelled` for
--      cancellation-only rules
--   2. Stop emitting `eventClosed` from `cancel_event`
-- once the rule engine handles both.
--
-- `eventStarted` and `eventDeadlinePassed` (also spec §8) require cron
-- emitters reading the clock — out of scope for this slice.

-- =========================================================
-- 1. Whitelist update: add eventCancelled
-- =========================================================

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable parallel safe
set search_path = pg_catalog
as $$
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
    -- mig 00199: distinct cancellation atom (Plans/Active/EventResource.md §8)
    'eventCancelled'
  ]);
$$;

-- =========================================================
-- 2. Trigger: emit eventCancelled on status → 'cancelled' for events
-- =========================================================

create or replace function public.handle_event_status_cancelled()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  -- Only events. Only the scheduled→cancelled (or any-non-cancelled→cancelled)
  -- transition. Idempotent against repeated updates that leave status
  -- already 'cancelled' (old.status = new.status case is excluded by the
  -- WHEN clause below, but kept here as a defensive guard).
  if new.resource_type <> 'event' then
    return new;
  end if;
  if new.status <> 'cancelled' then
    return new;
  end if;
  if old.status = 'cancelled' then
    return new;
  end if;

  insert into public.system_events (group_id, event_type, resource_id, payload)
  values (
    new.group_id,
    'eventCancelled',
    new.id,
    jsonb_build_object(
      'title',         new.metadata->>'title',
      'previous_status', old.status,
      'reason',        new.metadata->>'cancellation_reason',
      'cancelled_by',  auth.uid()
    )
  );

  return new;
end;
$$;
revoke execute on function public.handle_event_status_cancelled() from public, anon, authenticated;

drop trigger if exists on_event_status_cancelled on public.resources;
create trigger on_event_status_cancelled
  after update of status on public.resources
  for each row
  when (new.status = 'cancelled' and (old.status is null or old.status <> 'cancelled'))
  execute function public.handle_event_status_cancelled();

comment on function public.handle_event_status_cancelled() is
  'Emits eventCancelled atom on resources.status transition to cancelled (resource_type=event only). Additive to the legacy eventClosed emission from cancel_event RPC — both fire today, future migration can drop the legacy. Plans/Active/EventResource.md §8 + §17.';
