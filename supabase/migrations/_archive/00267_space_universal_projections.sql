-- 00267 — Space universal projections (Plans/Active/Space.md §10).
--
-- The 4 canonical views that derive space state from atoms — never
-- mutable truth. Companion of mig 00264 (atoms) and mig 00266 (RPCs).
--
-- All projections are `security_invoker = on` so RLS on the underlying
-- atoms (`system_events`, `bookings`, `check_in_actions`, `resources`)
-- applies as if the caller had read the base tables directly. No new
-- RLS policies needed at this layer.
--
-- Doctrine reminder (Space.md §10/§17): the views fold atoms; if
-- corrupt, they recompute by replaying. `metadata.capacity` is the
-- declared ceiling, NOT the current count.
--
--   1. space_availability_view
--      Active bookings on a space within their time window. Each row
--      represents one outstanding claim. UI derives "free / occupied"
--      by checking row presence per window.
--
--   2. space_capacity_view
--      Per-space snapshot: declared capacity, active booking count,
--      waitlist count, simple "is_full" derivation. Drives capacity
--      progress UI + the gate book_space uses.
--
--   3. space_occupancy_view
--      Members currently inside (check_in_actions where the latest
--      atom for the (space, member) pair is a check-in with no later
--      release / cancel). Drives "AHORA" UI section.
--
--   4. space_history_view
--      Append-only feed of every space-relevant atom — feeds Activity
--      tab. Subset filter on system_events keeps the iOS query simple
--      (one WHERE on event_type catalog, no joins on resource_type).

-- =============================================================================
-- 1. space_availability_view — active bookings per space
-- =============================================================================

create or replace view public.space_availability_view
with (security_invoker = on)
as
with cancellations as (
  select distinct
    (se.payload->>'booking_id')::uuid as booking_id
  from public.system_events se
  where se.event_type in ('bookingCancelled', 'bookingExpired')
)
select
  b.id                                              as booking_id,
  b.slot_id                                         as space_id,
  b.group_id,
  b.member_id,
  (b.metadata->>'starts_at')::timestamptz           as starts_at,
  (b.metadata->>'ends_at')::timestamptz             as ends_at,
  nullif(b.metadata->>'notes', '')                  as notes,
  b.created_at                                      as booked_at
from public.bookings b
join public.resources r
  on r.id = b.slot_id
 and r.resource_type = 'space'
where not exists (
  select 1 from cancellations c where c.booking_id = b.id
);

comment on view public.space_availability_view is
  'Plans/Active/Space.md §10 — active (non-cancelled, non-expired) bookings on each space. starts_at/ends_at come from booking.metadata (null = open-ended claim). UI derives "free / occupied" per time window by checking row presence.';

-- =============================================================================
-- 2. space_capacity_view — declared capacity vs current load + waitlist
-- =============================================================================

create or replace view public.space_capacity_view
with (security_invoker = on)
as
with active_bookings as (
  select space_id, count(*)::int as active_count
  from public.space_availability_view
  group by space_id
),
waitlist as (
  select
    j.resource_id as space_id,
    count(*)::int as waitlist_count
  from public.system_events j
  where j.event_type = 'spaceWaitlistJoined'
    and not exists (
      select 1 from public.system_events p
      where p.event_type = 'spaceWaitlistPromoted'
        and p.resource_id = j.resource_id
        and p.member_id   = j.member_id
        and p.occurred_at > j.occurred_at
    )
  group by j.resource_id
)
select
  r.id                                              as space_id,
  r.group_id,
  nullif(r.metadata->>'capacity', '')::int          as capacity,
  coalesce(ab.active_count, 0)                      as active_bookings,
  coalesce(wl.waitlist_count, 0)                    as waitlist_count,
  case
    when nullif(r.metadata->>'capacity', '')::int is null then false
    else coalesce(ab.active_count, 0) >= nullif(r.metadata->>'capacity', '')::int
  end                                               as is_full
from public.resources r
left join active_bookings ab on ab.space_id = r.id
left join waitlist wl        on wl.space_id = r.id
where r.resource_type = 'space'
  and r.archived_at is null;

comment on view public.space_capacity_view is
  'Plans/Active/Space.md §10 — per-space snapshot of declared capacity vs active bookings vs waitlist count. is_full derivation matches the book_space capacity gate. NULL capacity = unlimited (is_full always false).';

-- =============================================================================
-- 3. space_occupancy_view — members currently inside
-- =============================================================================

create or replace view public.space_occupancy_view
with (security_invoker = on)
as
with latest_per_member as (
  select
    ca.resource_id as space_id,
    ca.member_id,
    ca.id          as action_id,
    ca.recorded_at,
    ca.metadata    as checkin_metadata,
    row_number() over (
      partition by ca.resource_id, ca.member_id
      order by ca.recorded_at desc
    ) as rn
  from public.check_in_actions ca
  join public.resources r
    on r.id = ca.resource_id
   and r.resource_type = 'space'
   and r.archived_at is null
)
select
  lpm.space_id,
  lpm.member_id,
  lpm.action_id              as last_check_in_action_id,
  lpm.recorded_at            as checked_in_at,
  nullif(lpm.checkin_metadata->>'booking_id', '')::uuid as booking_id,
  nullif(lpm.checkin_metadata->>'notes', '')             as notes,
  r.group_id
from latest_per_member lpm
join public.resources r on r.id = lpm.space_id
where lpm.rn = 1;

comment on view public.space_occupancy_view is
  'Plans/Active/Space.md §10 — latest check-in per (space, member) on space resources. One row per member currently considered "inside" the space (no release atom defined yet, so latest check-in stands). Augment with a future spaceReleased / checkOut atom to expire occupants automatically.';

-- =============================================================================
-- 4. space_history_view — append-only activity feed
-- =============================================================================

create or replace view public.space_history_view
with (security_invoker = on)
as
select
  se.id              as event_id,
  se.resource_id     as space_id,
  se.group_id,
  se.event_type,
  se.member_id,
  se.payload,
  se.occurred_at
from public.system_events se
join public.resources r
  on r.id = se.resource_id
 and r.resource_type = 'space'
where se.event_type in (
  'spaceCreated',
  'spaceBooked',
  'spaceReleased',
  'spaceCapacityReached',
  'spaceWaitlistJoined',
  'spaceWaitlistPromoted',
  'spaceAccessGranted',
  'spaceAccessRevoked',
  'bookingCreated',
  'bookingCancelled',
  'bookingExpired',
  'checkInRecorded',
  'resourceArchived',
  'resourceUnarchived',
  'resourceRenamed',
  'resourceLinked',
  'resourceUnlinked'
);

comment on view public.space_history_view is
  'Plans/Active/Space.md §10/§22 Activity tab — append-only feed of every space-relevant atom on a space resource. Subset filter on system_events keeps the iOS query simple. Includes booking / check-in / access / link atoms in addition to the space.* lifecycle subset.';
