-- 00092 — Soft validation of system_events.event_type against the
-- platform whitelist.
--
-- Closes audit gap "record_system_event sin validación — callers pueden
-- emitir event_type inválidos". The codegen layer keeps `systemEventType.ts`
-- and `SystemEventType.swift` in sync; this migration mirrors that whitelist
-- server-side so a typo in any caller (iOS, edge function, manual SQL)
-- surfaces as a NOTICE in the database log instead of disappearing into the
-- queue where the rule engine silently shrugs (no trigger evaluator for an
-- unknown type, structured log "unknown" — visible but easy to miss).
--
-- Why soft validation (RAISE NOTICE) instead of a CHECK constraint:
--   1. A CHECK on a populated table fails the migration if even one zombie
--      row exists (legacy iOS build, debug events, accidental writes). We
--      don't yet have the audit guaranteeing the whitelist is exhaustive.
--   2. RAISE EXCEPTION would fail every event_type insert that doesn't
--      match — risky during the V1→Phase 2 window when new event types
--      ship in iOS before this whitelist is regenerated.
--   3. RAISE NOTICE keeps the pipeline working and surfaces the signal
--      to Supabase log inspection / Sentry without dropping data.
--
-- Future hard validation (post-audit): replace NOTICE with EXCEPTION OR
-- add a CHECK constraint once `SELECT DISTINCT event_type FROM
-- system_events WHERE NOT public.is_known_system_event_type(event_type)`
-- returns zero rows for the production database. See follow-up audit
-- query at the bottom of this file.

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable
parallel safe
as $$
  -- Keep this list in sync with
  -- ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/SystemEventType.swift
  -- (and the codegen mirror in supabase/functions/_shared/types/systemEventType.ts).
  -- Adding a new case in Swift requires regenerating the TS catalog and
  -- shipping a new migration to update this function.
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

comment on function public.is_known_system_event_type(text) is
  'Whitelist check for system_events.event_type values. Mirrors the SystemEventType Swift enum. Used by record_system_event for soft validation (NOTICE on unknown). Update + redeploy whenever the enum grows.';

-- =========================================================
-- Soft validation inside record_system_event
-- =========================================================
-- Insert path stays the same; we add a RAISE NOTICE when the type is
-- unknown so the row still lands (the rule engine and downstream consumers
-- continue to work) but the typo is visible to log inspection / Sentry.
-- A nullable / blank p_event_type is rejected outright since that signals
-- a real caller bug rather than a roadmap-pending type.

create or replace function public.record_system_event(
  p_group_id uuid,
  p_event_type text,
  p_resource_id uuid default null,
  p_member_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
begin
  if p_event_type is null or length(trim(p_event_type)) = 0 then
    raise exception 'record_system_event: event_type required';
  end if;

  if not public.is_known_system_event_type(p_event_type) then
    raise notice 'record_system_event: unknown event_type % (group=% resource=%) — row inserted but no rule engine evaluator will match; either ship a whitelist update or fix the caller.',
      p_event_type, p_group_id, p_resource_id;
  end if;

  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (p_group_id, p_event_type, p_resource_id, p_member_id, p_payload)
  returning id into v_event_id;

  return v_event_id;
end;
$$;

comment on function public.record_system_event is
  'Inserts a row into system_events. Caller responsible for setting the right event_type — unknown types now RAISE NOTICE (see is_known_system_event_type). Hard validation pending an audit of historical rows. Sprint 1a Edge Function process-system-events picks it up.';

-- =========================================================
-- Operator audit query (run manually after deploy)
-- =========================================================
-- Returns event_type values present in system_events that aren't on the
-- whitelist. Run after applying this migration to find zombie types
-- before promoting NOTICE → CHECK / EXCEPTION:
--
--   SELECT event_type, count(*) AS rows
--     FROM public.system_events
--    WHERE NOT public.is_known_system_event_type(event_type)
--    GROUP BY event_type
--    ORDER BY rows DESC;
--
-- Empty result → safe to add a CHECK constraint:
--
--   alter table public.system_events
--     add constraint system_events_event_type_known_chk
--     check (public.is_known_system_event_type(event_type));
--
-- Non-empty result → either add the missing types to the whitelist
-- (regenerate from Swift enum) or null/delete the zombie rows.
