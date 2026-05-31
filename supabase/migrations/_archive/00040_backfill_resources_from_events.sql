-- 00040 — Backfill `resources` from existing `events`.
--
-- Audit doc § 5.3 items 9+11 (combined sprint, step 2/3). Fills the
-- `resources` table with the existing `events` rows now that the
-- dual-write trigger (00039) keeps new events in sync. Result:
-- `resources.where(type='event')` ≡ `events`.
--
-- Idempotent: uses INSERT ... ON CONFLICT (id) DO UPDATE so re-running
-- is safe and converges. Skips rows already mirrored.
--
-- Single statement (no batching loop) because:
--   - Current prod row count (~10s of groups, hundreds of events) fits
--     well within a single transaction. If/when this grows, swap to a
--     batched version with `LIMIT N OFFSET M` + sleep.
--   - The `resources` table is empty in prod today (decision #3 of
--     Vision was scaffolded in 00014 but never activated), so no
--     conflict resolution is meaningful — each event row inserts fresh.
--
-- Verification: SELECT * FROM events_resources_parity_check() should
-- return diff = 0 after this migration.

insert into public.resources (
  id, group_id, resource_type, status, metadata,
  created_by, created_at, updated_at
)
select
  e.id,
  e.group_id,
  'event',
  e.status,
  jsonb_build_object(
    'title',                      e.title,
    'cover_image_name',           e.cover_image_name,
    'cover_image_url',            e.cover_image_url,
    'description',                e.description,
    'starts_at',                  e.starts_at,
    'ends_at',                    e.ends_at,
    'duration_minutes',           e.duration_minutes,
    'location_name',              e.location,
    'location_lat',               e.location_lat,
    'location_lng',               e.location_lng,
    'host_id',                    e.host_id,
    'cycle_number',               e.cycle_number,
    'rsvp_deadline',              e.rsvp_deadline,
    'rules_evaluated_at',         e.rules_evaluated_at,
    'notes',                      e.notes,
    'apply_rules',                e.apply_rules,
    'is_recurring_generated',     e.is_recurring_generated,
    'parent_event_id',            e.parent_event_id,
    'auto_no_show_at',            e.auto_no_show_at,
    'closed_at',                  e.closed_at,
    'cancellation_reason',        e.cancellation_reason,
    'capacity_max',               e.capacity_max,
    'allow_plus_ones',            e.allow_plus_ones,
    'max_plus_ones_per_member',   e.max_plus_ones_per_member
  ),
  e.created_by,
  e.created_at,
  e.updated_at
from public.events e
on conflict (id) do update
set group_id      = excluded.group_id,
    resource_type = excluded.resource_type,
    status        = excluded.status,
    metadata      = excluded.metadata,
    updated_at    = excluded.updated_at;
