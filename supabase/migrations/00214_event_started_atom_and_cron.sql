-- Mig 00208: `eventStarted` lifecycle atom + cron emitter + lifecycle
-- view atom-aware.
--
-- Plans/Active/EventResource.md §8 lists `eventStarted` as a canonical
-- lifecycle atom; §17 says `is_live` derives from atoms, not from the
-- clock alone. Mig 00207 shipped `event_lifecycle_view` with a clock-
-- based fallback for `is_live` (correct enough until an upstream emitter
-- existed). This migration:
--
--   1. Adds `eventStarted` to the whitelist.
--   2. Registers `emit-event-started-atoms` cron (every 5 min) so the
--      atom actually gets emitted once `starts_at` elapses.
--   3. Refreshes `event_lifecycle_view` so `is_live` prefers the atom
--      when present (cleaner §17 derivation; clock fallback stays as
--      the bridge for events whose atom hasn't been emitted yet — the
--      first cron tick after a deploy or for forward-going events).
--
-- Cancellation interplay: the cron skips events with a `eventCancelled`
-- atom, so cancelled events never get `eventStarted`. The view's
-- `is_live` formula short-circuits on cancellation/closure regardless.

-- =========================================================
-- 1. Whitelist update — append eventStarted
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
    'fundCreated', 'fundDeposit', 'fundThresholdReached', 'fundLocked', 'fundUnlocked',
    'positionChanged', 'memberJoined', 'memberLeft',
    'ruleEnabledChanged', 'ruleAmountChanged',
    'pendingChangeApplied', 'inviteCodeRotated',
    'groupCreated', 'groupArchived', 'groupUnarchived', 'groupRenamed', 'governanceUpdated',
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    'ledgerEntryCreated', 'warningEmitted',
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    'rightExpiringSoon',
    'assetTransferred', 'assetAssigned', 'assetReturned',
    'custodyAssigned', 'custodyReleased',
    'maintenanceLogged', 'maintenanceCompleted', 'damageReported',
    'assetUsed', 'assetCheckedOut', 'assetCheckedIn',
    'valuationRecorded',
    'resourceLinked', 'resourceUnlinked',
    'eventCancelled',
    -- mig 00208: cron-emitted lifecycle atom (Plans/Active/EventResource.md §8)
    'eventStarted'
  ]);
$$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist of system_events.event_type values. v_post_reconcile_3 (00208): adds eventStarted. CHECK constraint system_events_event_type_known_chk (00095) enforces this at INSERT.';

-- =========================================================
-- 2. event_lifecycle_view — prefer atom over clock for is_live
-- =========================================================
--
-- Adds an `eventStarted` atom subquery and changes the `is_live` formula
-- to require either (atom present) OR (no atom yet AND clock past
-- starts_at). The "no atom yet" branch is the bridge for events whose
-- atom hasn't been emitted (e.g., first cron tick after starts_at).

create or replace view public.event_lifecycle_view as
with cancellation_atom as (
  select distinct on (resource_id)
    resource_id,
    occurred_at as cancelled_at,
    member_id   as cancelled_by_member,
    payload->>'cancelled_by' as cancelled_by_user,
    payload->>'reason'       as cancellation_reason
  from public.system_events
  where event_type = 'eventCancelled'
    and resource_id is not null
  order by resource_id, occurred_at desc
),
close_atom as (
  select distinct on (resource_id)
    resource_id,
    occurred_at as closed_at
  from public.system_events
  where event_type = 'eventClosed'
    and resource_id is not null
  order by resource_id, occurred_at desc
),
start_atom as (
  select distinct on (resource_id)
    resource_id,
    occurred_at as started_at
  from public.system_events
  where event_type = 'eventStarted'
    and resource_id is not null
  order by resource_id, occurred_at desc
)
select
  r.id       as resource_id,
  r.group_id,
  (r.metadata->>'starts_at')::timestamptz as starts_at,
  case
    when (r.metadata->>'ends_at') is not null
      then (r.metadata->>'ends_at')::timestamptz
    when (r.metadata->>'starts_at') is not null
      and (r.metadata->>'duration_minutes') is not null
      then (r.metadata->>'starts_at')::timestamptz
         + ((r.metadata->>'duration_minutes')::int || ' minutes')::interval
    else null
  end as ends_at,

  -- Atom audit (started_at appended at the end so CREATE OR REPLACE
  -- doesn't try to re-order existing view columns — Postgres rejects
  -- column re-ordering on REPLACE).
  ca.cancelled_at,
  ca.cancelled_by_user,
  ca.cancellation_reason,
  cl.closed_at,

  -- Derived state (Plans/Active/EventResource.md §17)
  (ca.cancelled_at is not null) as is_cancelled,
  (cl.closed_at    is not null) as is_closed,

  -- is_live: started (atom OR clock fallback), not ended, not cancelled,
  -- not closed.
  case
    when ca.cancelled_at is not null then false
    when cl.closed_at    is not null then false
    when (r.metadata->>'starts_at') is null then false
    -- Started gate: atom wins; clock is the bridge until the cron emits.
    when sa.started_at is null
      and (r.metadata->>'starts_at')::timestamptz > now() then false
    -- End gate
    when (r.metadata->>'ends_at') is not null
      then (r.metadata->>'ends_at')::timestamptz > now()
    when (r.metadata->>'duration_minutes') is not null
      then (r.metadata->>'starts_at')::timestamptz
         + ((r.metadata->>'duration_minutes')::int || ' minutes')::interval > now()
    else true
  end as is_live,

  -- is_past: cancelled, closed, or clock past ends_at / starts_at+duration.
  case
    when ca.cancelled_at is not null then true
    when cl.closed_at    is not null then true
    when (r.metadata->>'ends_at') is not null
      and (r.metadata->>'ends_at')::timestamptz <= now() then true
    when (r.metadata->>'starts_at') is not null
      and (r.metadata->>'duration_minutes') is not null
      and ((r.metadata->>'starts_at')::timestamptz
           + ((r.metadata->>'duration_minutes')::int || ' minutes')::interval) <= now()
      then true
    else false
  end as is_past,
  sa.started_at
from public.resources r
left join cancellation_atom ca on ca.resource_id = r.id
left join close_atom        cl on cl.resource_id = r.id
left join start_atom        sa on sa.resource_id = r.id
where r.resource_type = 'event'
  and r.archived_at is null;

comment on view public.event_lifecycle_view is
  'Atom-derived projection of event lifecycle per Plans/Active/EventResource.md §17. v2 (00208): is_live now prefers the eventStarted atom when present (clock fallback bridges the gap until cron emits). Exposes is_live/is_past/is_cancelled/is_closed plus audit timestamps from eventCancelled / eventClosed / eventStarted atoms.';

grant select on public.event_lifecycle_view to authenticated;

-- =========================================================
-- 3. Cron registration — emit-event-started-atoms every 5 min
-- =========================================================
--
-- Idempotent via cron.schedule (upsert by name). Re-applying the
-- migration replaces schedule + command without duplicates.
--
-- Auth: anon JWT pattern matches mig 00131 (emit-event-reminder-events).
-- The function uses SERVICE_ROLE_KEY internally; the JWT only satisfies
-- the function's verify_jwt gate.

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'emit-event-started-atoms-5min',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := 'https://fpfvlrwcskhgsjuhrjpz.supabase.co/functions/v1/emit-event-started-atoms',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZwZnZscndjc2toZ3NqdWhyanB6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1MTU4NTIsImV4cCI6MjA5MzA5MTg1Mn0.Cy5fWfdPv1cqhPdy2UTI-cY7eApnG9UPoBv94EkGGBc'
    ),
    body := '{}'::jsonb
  );
  $$
);
