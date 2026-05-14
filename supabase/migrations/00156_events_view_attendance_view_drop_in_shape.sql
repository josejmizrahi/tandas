-- 00156 — events_view + attendance_view as drop-in replacements
-- for the events / event_attendance tables.
--
-- Constitution §14 step 5c-iii preparation.
--
-- Why
-- ===
-- 5c-iii needs to migrate ~12 callsites (6 edge functions, 2 Swift repos,
-- 4 e2e tests) off direct reads of public.events / public.event_attendance.
-- Today each callsite hand-rolls a select over a different column shape:
-- events.title, events.host_id, event_attendance.event_id, etc.
--
-- The 5a / 5c-i projections currently expose a smaller (event-resource-id
-- + jsonb metadata) shape: consumers would have to dig into `metadata`
-- for every read. That turns a mechanical rename ("from events" → "from
-- events_view") into a semantic refactor on every callsite.
--
-- This migration rebuilds both views as **denormalized drop-ins** that
-- expose every column the legacy tables exposed, mirrored from
-- public.resources.metadata + the polymorphic atoms. The shape of the
-- views is byte-equivalent (column names, types) to the legacy tables
-- where the data exists. Callsites swap `.from("events")` →
-- `.from("events_view")` and `.from("event_attendance")` →
-- `.from("attendance_view")` with zero downstream changes.
--
-- Compatibility columns retained
-- ==============================
-- - events_view exposes both `id` and `resource_id` (same UUID). The only
--   existing consumer of the old shape, process-system-events, uses
--   `resource_id`; legacy consumers from the events table use `id`.
-- - attendance_view exposes both `resource_id` and `event_id` (same UUID).
--   Same rationale.
--
-- The non-NOT-NULL projection means consumers can't INSERT through the
-- view (it's a true read projection); writers continue going through
-- the V2 RPCs (or, post-5c-iii-C, through atoms directly).

-- =============================================================================
-- 1. events_view — denormalized drop-in for public.events
-- =============================================================================

drop view if exists public.events_view;

create view public.events_view as
select
  r.id                                              as id,
  r.id                                              as resource_id,
  r.resource_type                                   as resource_type,
  r.group_id                                        as group_id,
  r.status                                          as status,
  r.created_by                                      as created_by,
  r.created_at                                      as created_at,
  r.updated_at                                      as updated_at,
  r.series_id                                       as series_id,
  r.metadata                                        as metadata,
  -- Denormalized fields (match events table column names)
  (r.metadata->>'title')                            as title,
  (r.metadata->>'description')                      as description,
  (r.metadata->>'cover_image_name')                 as cover_image_name,
  (r.metadata->>'cover_image_url')                  as cover_image_url,
  (r.metadata->>'starts_at')::timestamptz           as starts_at,
  (r.metadata->>'ends_at')::timestamptz             as ends_at,
  (r.metadata->>'duration_minutes')::int            as duration_minutes,
  (r.metadata->>'location_name')                    as location,
  (r.metadata->>'location_lat')::numeric            as location_lat,
  (r.metadata->>'location_lng')::numeric            as location_lng,
  (r.metadata->>'host_id')::uuid                    as host_id,
  (r.metadata->>'cycle_number')::int                as cycle_number,
  (r.metadata->>'rsvp_deadline')::timestamptz       as rsvp_deadline,
  (r.metadata->>'rules_evaluated_at')::timestamptz  as rules_evaluated_at,
  (r.metadata->>'notes')                            as notes,
  coalesce((r.metadata->>'apply_rules')::boolean, true)
                                                    as apply_rules,
  coalesce((r.metadata->>'is_recurring_generated')::boolean, false)
                                                    as is_recurring_generated,
  (r.metadata->>'parent_event_id')::uuid            as parent_event_id,
  (r.metadata->>'auto_no_show_at')::timestamptz     as auto_no_show_at,
  (r.metadata->>'closed_at')::timestamptz           as closed_at,
  (r.metadata->>'cancellation_reason')              as cancellation_reason,
  (r.metadata->>'capacity_max')::int                as capacity_max,
  coalesce((r.metadata->>'allow_plus_ones')::boolean, false)
                                                    as allow_plus_ones,
  coalesce((r.metadata->>'max_plus_ones_per_member')::int, 0)
                                                    as max_plus_ones_per_member
from public.resources r
where r.resource_type = 'event';

comment on view public.events_view is
  'Drop-in projection for public.events, sourced from resources WHERE resource_type=event (Constitution §14 step 5c-iii prep). Exposes both id and resource_id (same UUID) for backward compat. Denormalizes the high-traffic metadata jsonb keys (title, starts_at, host_id, …) so callsites can swap from("events") → from("events_view") without touching field access.';

grant select on public.events_view to authenticated;

-- =============================================================================
-- 2. attendance_view — add event_id alias
-- =============================================================================
-- The 5c-i version is functionally complete; just need event_id as a
-- backward-compat alias so legacy callsites of public.event_attendance
-- can swap the table name and keep their column access unchanged.

create or replace view public.attendance_view as
with roster as (
  select resource_id, member_id from public.rsvp_actions
  union
  select resource_id, member_id from public.check_in_actions
),
latest_rsvp as (
  select distinct on (resource_id, member_id)
    resource_id,
    member_id,
    status                                 as rsvp_status,
    recorded_at                            as rsvp_at,
    coalesce((metadata->>'plus_ones')::int, 0)              as plus_ones,
    coalesce((metadata->>'cancelled_same_day')::boolean, false) as cancelled_same_day,
    (metadata->>'waitlist_position')::int  as waitlist_position,
    metadata->>'cancelled_reason'          as cancelled_reason
  from public.rsvp_actions
  order by resource_id, member_id, recorded_at desc
),
latest_check_in as (
  select distinct on (resource_id, member_id)
    resource_id,
    member_id,
    arrived_at,
    metadata->>'check_in_method'                                  as check_in_method,
    coalesce((metadata->>'check_in_location_verified')::boolean, false)
                                                                  as check_in_location_verified,
    (metadata->>'marked_by')::uuid                                as marked_by
  from public.check_in_actions
  order by resource_id, member_id, recorded_at desc
)
select
  roster.resource_id                         as resource_id,
  roster.resource_id                         as event_id,           -- alias
  r.group_id                                 as group_id,
  roster.member_id                           as member_id,
  gm.user_id                                 as user_id,
  coalesce(lr.rsvp_status, 'pending')        as rsvp_status,
  lr.rsvp_at                                 as rsvp_at,
  lc.arrived_at                              as arrived_at,
  coalesce(lr.plus_ones, 0)                  as plus_ones,
  coalesce(lr.cancelled_same_day, false)     as cancelled_same_day,
  lr.cancelled_reason                        as cancelled_reason,
  lr.waitlist_position                       as waitlist_position,
  lc.check_in_method                         as check_in_method,
  coalesce(lc.check_in_location_verified, false) as check_in_location_verified,
  lc.marked_by                               as marked_by,
  (r.status in ('completed','cancelled') and lc.arrived_at is null)
                                             as no_show
from roster
join public.resources r       on r.id  = roster.resource_id
                             and r.resource_type = 'event'
join public.group_members gm  on gm.id = roster.member_id
left join latest_rsvp lr
  on lr.resource_id = roster.resource_id and lr.member_id = roster.member_id
left join latest_check_in lc
  on lc.resource_id = roster.resource_id and lc.member_id = roster.member_id;

comment on view public.attendance_view is
  'Projection of event attendance from rsvp_actions + check_in_actions atoms (Constitution §14 step 5c-i). One row per (event-resource, member) pair that has at least one atom. Exposes both resource_id and event_id (same UUID) for backward compat. `no_show` derived from resource.status ∈ {completed, cancelled} ∧ arrived_at IS NULL.';

grant select on public.attendance_view to authenticated;
