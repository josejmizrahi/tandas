-- 00039 — Dual-write trigger from `events` to `resources`.
--
-- Audit doc § 5.3 items 9+11 (combined sprint, step 1/3). Activates
-- decision #3 of Vision: every event also lands in the generic
-- `resources` table. This is the foundation for `fines.resource_id`
-- (item 9) and for Phase 2 templates that ship non-event resources
-- (slot, fund, position).
--
-- Strategy:
--   - `resources.id = events.id` (same UUID). Simplifies backfill +
--     keeps `fines.resource_id = fines.event_id` post-backfill.
--   - INSERT/UPDATE on events → UPSERT on resources (ON CONFLICT id).
--   - DELETE on events → DELETE on resources (FK cascade keeps fines
--     consistent later when fines.resource_id is added).
--   - Trigger is AFTER so the events row is fully written first.
--
-- Cohabitation:
--   - The legacy `events` table remains the source of truth for V1.
--     `resources` is a mirror — never written-to-directly until Phase 2
--     templates ship non-event resources.
--   - `events_view` (00014) continues to project from `events` only,
--     unchanged.
--   - Backfill of existing events runs in 00040 (separate migration so
--     this trigger ships isolated).
--
-- Idempotent: trigger function uses CREATE OR REPLACE; trigger uses
-- DROP IF EXISTS / CREATE.

create or replace function public.sync_event_to_resource()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'DELETE' then
    delete from public.resources where id = OLD.id;
    return OLD;
  end if;

  -- INSERT or UPDATE: upsert into resources with same id, projecting
  -- non-PII metadata. Mirrors the shape of `events_view` (00014).
  insert into public.resources (
    id, group_id, resource_type, status, metadata,
    created_by, created_at, updated_at
  ) values (
    NEW.id,
    NEW.group_id,
    'event',
    NEW.status,
    jsonb_build_object(
      'title',                      NEW.title,
      'cover_image_name',           NEW.cover_image_name,
      'cover_image_url',            NEW.cover_image_url,
      'description',                NEW.description,
      'starts_at',                  NEW.starts_at,
      'ends_at',                    NEW.ends_at,
      'duration_minutes',           NEW.duration_minutes,
      'location_name',              NEW.location,
      'location_lat',               NEW.location_lat,
      'location_lng',               NEW.location_lng,
      'host_id',                    NEW.host_id,
      'cycle_number',               NEW.cycle_number,
      'rsvp_deadline',              NEW.rsvp_deadline,
      'rules_evaluated_at',         NEW.rules_evaluated_at,
      'notes',                      NEW.notes,
      'apply_rules',                NEW.apply_rules,
      'is_recurring_generated',     NEW.is_recurring_generated,
      'parent_event_id',            NEW.parent_event_id,
      'auto_no_show_at',            NEW.auto_no_show_at,
      'closed_at',                  NEW.closed_at,
      'cancellation_reason',        NEW.cancellation_reason,
      'capacity_max',               NEW.capacity_max,
      'allow_plus_ones',            NEW.allow_plus_ones,
      'max_plus_ones_per_member',   NEW.max_plus_ones_per_member
    ),
    NEW.created_by,
    NEW.created_at,
    NEW.updated_at
  )
  on conflict (id) do update
  set group_id      = excluded.group_id,
      resource_type = excluded.resource_type,
      status        = excluded.status,
      metadata      = excluded.metadata,
      updated_at    = excluded.updated_at;

  return NEW;
end;
$$;

comment on function public.sync_event_to_resource() is
  'Dual-write trigger: mirrors INSERT/UPDATE/DELETE on events into resources. resources.id = events.id. Audit doc § 5.3 item 11.';

drop trigger if exists events_sync_to_resources on public.events;

create trigger events_sync_to_resources
  after insert or update or delete on public.events
  for each row execute function public.sync_event_to_resource();

-- =============================================================================
-- Verification helper
-- =============================================================================
-- Quick parity check used by ops scripts during the cohabitation window.
-- Returns the count diff between events and resources(type='event').
-- Should be 0 after backfill (00040) completes; thereafter the trigger
-- keeps them in sync.

create or replace function public.events_resources_parity_check()
returns table (
  events_count bigint,
  resources_event_count bigint,
  diff bigint
)
language sql
stable
security definer
set search_path = public
as $$
  with e as (select count(*) as c from public.events),
       r as (select count(*) as c from public.resources where resource_type = 'event')
  select e.c, r.c, e.c - r.c
    from e, r;
$$;

comment on function public.events_resources_parity_check() is
  'Parity check for the events→resources dual-write. Should return diff=0 after 00040 backfill. Audit doc § 5.3 items 9+11.';

revoke execute on function public.events_resources_parity_check() from public, anon;
grant  execute on function public.events_resources_parity_check() to authenticated;
