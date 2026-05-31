-- 00159 — Drop public.events and public.event_attendance tables.
--
-- Constitution §14 step 5c-iv (terminal cleanup).
--
-- Preconditions verified 2026-05-13:
--   - mig 00158 refactored every V2 writer RPC to write resources +
--     atoms directly. The dual-write trigger events_sync_to_resources
--     is gone; no remaining function body references public.events or
--     public.event_attendance (audit query: 0 fn refs, 0 view refs).
--   - The only remaining incoming FKs are event_attendance.event_id
--     (CASCADE) and events.parent_event_id (SET NULL, self-ref). Both
--     drop with the tables.
--   - iOS LiveEventRepository.updateEvent (the last direct .from("events")
--     .update() callsite) is migrated to the new update_event_metadata
--     RPC introduced here.
--   - The auto-close-events edge fn is redeployed against
--     UPDATE resources directly (no longer touches events table).
--
-- Adds before drop
-- ================
-- public.update_event_metadata(p_event_id uuid, p_patch jsonb): merges
-- the JSONB patch into resources.metadata for an event resource.
-- Replaces the legacy `from("events").update(...)` iOS write.

-- =============================================================================
-- 1. update_event_metadata RPC
-- =============================================================================

create or replace function public.update_event_metadata(
  p_event_id uuid,
  p_patch    jsonb
)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_host_id  uuid;
  v_view_row public.events_view;
begin
  select * into v_resource from public.resources
   where id = p_event_id and resource_type = 'event';
  if v_resource.id is null then raise exception 'event not found'; end if;

  v_host_id := (v_resource.metadata->>'host_id')::uuid;
  if not (public.is_group_admin(v_resource.group_id, auth.uid()) or v_host_id = auth.uid()) then
    raise exception 'host or admin only';
  end if;

  -- Merge p_patch over the existing metadata. The patch keys use the
  -- legacy events column names (title, location, starts_at, host_id,
  -- etc) — same vocabulary iOS already builds.
  update public.resources
     set metadata   = metadata || p_patch,
         updated_at = now()
   where id = p_event_id;

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

revoke execute on function public.update_event_metadata(uuid, jsonb) from public, anon;
grant  execute on function public.update_event_metadata(uuid, jsonb) to authenticated, service_role;

comment on function public.update_event_metadata(uuid, jsonb) is
  '§14 step 5c-iv: shallow-merges p_patch into resources.metadata for an event resource. Replaces the legacy `from("events").update(...)` iOS write.';

-- =============================================================================
-- 1b. bulk_close_stale_events RPC for the auto-close-events cron
-- =============================================================================
-- The cron previously batched `UPDATE events SET status=completed,
-- closed_at=now() WHERE id IN (...)`. PostgREST can't run that against
-- resources.metadata as a JSONB merge in one call, so we expose a
-- service-role RPC that does the per-row jsonb_set. Returns the closed
-- ids so the cron can keep its existing eventClosed system_event emit
-- (which it does outside this RPC to preserve the existing log shape).

create or replace function public.bulk_close_stale_events(p_ids uuid[])
returns setof uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id  uuid;
  v_now timestamptz := now();
begin
  foreach v_id in array p_ids loop
    update public.resources
       set status     = 'completed',
           metadata   = jsonb_set(metadata, '{closed_at}', to_jsonb(v_now::text)),
           updated_at = v_now
     where id = v_id
       and resource_type = 'event'
       and status in ('scheduled', 'in_progress');
    if found then return next v_id; end if;
  end loop;
end;
$$;

revoke execute on function public.bulk_close_stale_events(uuid[]) from public, anon;
grant  execute on function public.bulk_close_stale_events(uuid[]) to service_role;

comment on function public.bulk_close_stale_events(uuid[]) is
  '§14 step 5c-iv: per-row UPDATE on resources for the auto-close-events cron, preserving existing metadata via jsonb_set. Service-role only.';

-- =============================================================================
-- 2. Drop legacy tables
-- =============================================================================
-- CASCADE drops:
--   - event_attendance_event_id_fkey  (event_attendance → events)
--   - events_parent_event_id_fkey     (events self-ref)
--   - any remaining objects depending on the tables (there should be
--     none after 00158, but CASCADE is defensive).
--
-- public.events_view and public.attendance_view do NOT depend on these
-- tables (verified by audit) — they project from public.resources and
-- the atom tables. So callers reading via events_view / attendance_view
-- keep working.

drop table if exists public.event_attendance cascade;
drop table if exists public.events           cascade;
