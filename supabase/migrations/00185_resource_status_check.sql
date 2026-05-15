-- Mig 00185: CHECK constraint on resources.status per resource_type
--
-- Today `resources.status` is free-text. A typo (`compleeted`) creates a
-- silent invalid row. We add a composite validator `is_known_resource_status`
-- that checks the (resource_type, status) pair against the canonical
-- per-type set, then promote it to a CHECK constraint with NOT VALID +
-- VALIDATE (the standard pattern for adding a CHECK to a populated
-- table — same as mig 00095 for system_events).
--
-- Canonical statuses per resource_type (mig 00147 froze the enum at
-- event / fund / asset / slot / space / right):
--   event:    scheduled, completed, cancelled
--   fund:     active, closed, archived
--   asset:    active, archived
--   space:    active, archived
--   slot:     pending, assigned, declined, expired
--   right:    active, expired, revoked
--
-- Update this whitelist via a new migration whenever a status is added.

create or replace function public.is_known_resource_status(
  p_resource_type text,
  p_status text
) returns boolean
language sql
immutable
parallel safe
set search_path = pg_catalog
as $$
  select case p_resource_type
    when 'event'  then p_status in ('scheduled', 'completed', 'cancelled')
    when 'fund'   then p_status in ('active', 'closed', 'archived')
    when 'asset'  then p_status in ('active', 'archived')
    when 'space'  then p_status in ('active', 'archived')
    when 'slot'   then p_status in ('pending', 'assigned', 'declined', 'expired')
    when 'right'  then p_status in ('active', 'expired', 'revoked')
    else false
  end;
$$;

comment on function public.is_known_resource_status(text, text) is
  'Whitelist check for (resource_type, status) pair on public.resources. Update via new migration when a status is added. Mirrors the is_known_system_event_type pattern (mig 00092 → 00095).';

alter table public.resources
  drop constraint if exists resources_status_known_chk;

alter table public.resources
  add constraint resources_status_known_chk
  check (public.is_known_resource_status(resource_type, status)) not valid;

alter table public.resources
  validate constraint resources_status_known_chk;
