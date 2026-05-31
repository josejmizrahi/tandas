-- 00152 — Invert events_view to project FROM public.resources.
--
-- Constitution §14 step 5a. Until now `events_view` (00014) was a
-- read-shape over `public.events` and `public.resources` was a mirror
-- kept in sync by `events_sync_to_resources` (00039 + 00126). That
-- backwards: per §14 art. 2 `resources` is the universal Resource
-- primitive — the view should derive from it, not feed it.
--
-- This migration flips the direction. After this:
--   - public.resources  is the source of truth for event-shaped rows
--     (resource_type = 'event'). The dual-write trigger on
--     public.events keeps writing here, so the row data is
--     unchanged.
--   - public.events_view selects FROM resources WHERE
--     resource_type = 'event'. Every consumer keeps the same column
--     shape (resource_id / resource_type / group_id / status /
--     created_by / created_at / updated_at / metadata) so no
--     callsite changes.
--   - public.events  remains live as a writer-facing table for V1
--     RPCs (create_event, cancel_event, …); 00153/5b/5c will retire
--     it after the writers are refactored.
--
-- Why this is safe today
-- ======================
-- The metadata jsonb the view returns was built from `events.*` columns
-- via `jsonb_build_object`. The dual-write trigger constructs the
-- *exact same* jsonb keys/values when it upserts into
-- `resources.metadata` (see 00039 lines 53-76 and 00126 lines 116-139).
-- So `r.metadata` is byte-equivalent to the old expression — the only
-- difference is which physical table it reads from. Parity helper
-- `events_resources_parity_check` (00039) returns diff = 0 today, so
-- both rowsets are already in lockstep.
--
-- What this migration does NOT do
-- ===============================
-- - Touch the `events` table (kept for writers).
-- - Drop the dual-write trigger (kept until 5c).
-- - Change `series_id` exposure (events_view never surfaced it; the
--   only reader, process-system-events, pulls it from the resources
--   row directly — see _shared/ruleContext.ts).
--
-- Rollback path: replace the view body with the original events-based
-- SELECT from 00014. No data migration needed in either direction.
--
-- Idempotency: CREATE OR REPLACE VIEW is repeatable.

create or replace view public.events_view as
select
  r.id            as resource_id,
  r.resource_type,
  r.group_id,
  r.status,
  r.created_by,
  r.created_at,
  r.updated_at,
  r.metadata
from public.resources r
where r.resource_type = 'event';

comment on view public.events_view is
  'Event-shaped projection over public.resources (Constitution §14 step 5a). Filters resource_type=event. Column shape unchanged from 00014 so existing readers (process-system-events) stay green; only the underlying physical source flipped from public.events to public.resources.';

-- Re-grant select to authenticated (CREATE OR REPLACE preserves
-- privileges, but being explicit guards against any future apply
-- order that resets them).
grant select on public.events_view to authenticated;
