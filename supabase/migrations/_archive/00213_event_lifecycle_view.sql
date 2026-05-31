-- Mig 00207: `event_lifecycle_view` — derive event state from atoms
--
-- Plans/Active/EventResource.md §17: "NO usar `status = active` como verdad
-- primaria. La realidad se deriva de atoms." §8 lists the lifecycle atoms
-- (`eventCreated`, `eventStarted`, `eventEnded`, `eventCancelled`,
-- `eventDeadlinePassed`); §17 lists the canonical projections derived
-- from those atoms (`is_live`, `is_past`, `is_cancelled`).
--
-- This view materialises those projections. It is read-only and stateless
-- — the truth lives in `resources.metadata` (starts_at/ends_at/duration)
-- and `system_events` (eventCancelled / eventClosed atoms). `resources
-- .status` remains the operational truth for now (existing readers rely
-- on it); this view exposes the spec-compliant DERIVED truth alongside,
-- so new consumers (rule engine evaluators, UI section logic, analytics)
-- can migrate at their own pace.
--
-- Caveats
-- =======
-- - `eventStarted` and `eventEnded` atoms aren't emitted yet (§8 marks
--   them out-of-scope until a cron emitter ships). `is_live` and `is_past`
--   therefore derive from clock + metadata + the cancelled/closed atom
--   gating. Once the cron lands, this view stays correct (atoms become
--   authoritative; the clock-fallback paths drop).
-- - `eventClosed` is overloaded today: `cancel_event` (legacy) emits it
--   in addition to the new `eventCancelled` atom. We treat `eventClosed`
--   as "past" regardless. If a cancellation atom is also present, that
--   wins for `is_cancelled`.

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

  -- Atom audit
  ca.cancelled_at,
  ca.cancelled_by_user,
  ca.cancellation_reason,
  cl.closed_at,

  -- Derived state (Plans/Active/EventResource.md §17)
  (ca.cancelled_at is not null) as is_cancelled,
  (cl.closed_at    is not null) as is_closed,

  -- is_live: started, hasn't ended, not cancelled, not closed.
  case
    when ca.cancelled_at is not null then false
    when cl.closed_at    is not null then false
    when (r.metadata->>'starts_at') is null then false
    when (r.metadata->>'starts_at')::timestamptz > now() then false
    when (r.metadata->>'ends_at') is not null
      then (r.metadata->>'ends_at')::timestamptz > now()
    when (r.metadata->>'duration_minutes') is not null
      then (r.metadata->>'starts_at')::timestamptz
         + ((r.metadata->>'duration_minutes')::int || ' minutes')::interval > now()
    else true  -- started, no end declared → live until manually closed
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
  end as is_past
from public.resources r
left join cancellation_atom ca on ca.resource_id = r.id
left join close_atom        cl on cl.resource_id = r.id
where r.resource_type = 'event'
  and r.archived_at is null;

comment on view public.event_lifecycle_view is
  'Atom-derived projection of event lifecycle per Plans/Active/EventResource.md §17. Exposes is_live/is_past/is_cancelled/is_closed plus the audit timestamps from eventCancelled + eventClosed atoms. Replaces resources.status as the canonical answer to "what state is this event in?" for new readers; existing readers keep using status until they migrate. Read-only; truth lives in resources.metadata + system_events.';

grant select on public.event_lifecycle_view to authenticated;
