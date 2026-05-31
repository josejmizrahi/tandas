-- 00104 — Polymorphic resources_view.
--
-- Audit task M.13. Today iOS reads occurrences/event-shaped resources via
-- public.events_view (mig 00014) which only knows about the `events` table.
-- Once Phase 2 ships Slot/Booking/Asset, callers want a polymorphic
-- read path that exposes every Resource row enriched with its series and
-- capability config without joining N tables per query.
--
-- This view does NOT replace events_view (cohabitation window stays open
-- through Phase 5 per OpenPlatform §I). It is additive: Phase 2 consumers
-- read from resources_view; legacy event consumers keep using events_view
-- until the EventRepository migration lands.
--
-- Columns:
--   resources.*                  — every resource row, polymorphic
--   series_pattern (jsonb)       — resource_series.pattern when series_id set
--   series_active  (bool)        — resource_series.active   when series_id set
--   capability_count (int)       — how many resource_capabilities rows
--                                  with enabled=true the resource has
--
-- Notes:
--   - Capability count is an O(n) lateral aggregate, but the index
--     idx_resource_capabilities_enabled (mig 00078) is partial on
--     enabled=true so the count is cheap. If volume grows enough to
--     hurt, swap for a materialized view.
--   - Does NOT join member counts / RSVP rolls / ledger totals — those
--     belong on per-capability views (attendance_view, balance_view).
--   - SECURITY INVOKER (default) so RLS on resources passes through;
--     reading the view never bypasses the caller's group membership.

create or replace view public.resources_view as
select
  r.id,
  r.group_id,
  r.resource_type,
  r.status,
  r.metadata,
  r.series_id,
  r.created_by,
  r.created_at,
  r.updated_at,
  s.pattern   as series_pattern,
  s.active    as series_active,
  coalesce(c.capability_count, 0) as capability_count
from public.resources r
left join public.resource_series s
       on s.id = r.series_id
left join lateral (
  select count(*)::int as capability_count
    from public.resource_capabilities rc
   where rc.resource_id = r.id
     and rc.enabled = true
) c on true;

comment on view public.resources_view is
  'Polymorphic Resource read projection per Taxonomy §1. Every resources row enriched with its ResourceSeries (when present) and enabled capability count. Additive to events_view during the Phase 2-5 cohabitation window; new code reads from here, legacy event paths stay on events_view until EventRepository migrates.';
