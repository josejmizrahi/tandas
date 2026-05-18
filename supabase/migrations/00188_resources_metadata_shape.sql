-- Mig 00188: Minimum metadata shape CHECK per resource_type
--
-- Today `resources.metadata` is jsonb without contract. An event without
-- `title` or `starts_at` is silently accepted and breaks downstream
-- views (events_view) which assume those keys exist.
--
-- We add a function-based CHECK that requires the absolute minimum
-- per type so the data integrity is enforced at write time, not at
-- read time when views explode. Optional keys (description, cover, etc.)
-- are NOT enforced here — only the bare minimum every UI / engine
-- assumes is present.
--
-- Audit confirms 100% coverage in prod for the keys we require:
--   event: 12/12 have title + starts_at
--   fund:  1/1  has name + currency
--   asset: 2/2  has name
--
-- slot / space / right have no rows yet; we default to no constraint so
-- prototyping isn't blocked. Tighten via a new migration once those
-- types ship.

create or replace function public.is_valid_resource_metadata(
  p_resource_type text,
  p_metadata jsonb
) returns boolean
language sql
immutable
parallel safe
set search_path = pg_catalog
as $$
  select case p_resource_type
    when 'event' then
      p_metadata ? 'title'
      and p_metadata ? 'starts_at'
    when 'fund' then
      p_metadata ? 'name'
      and p_metadata ? 'currency'
    when 'asset' then
      p_metadata ? 'name'
    when 'space' then
      p_metadata ? 'name'
    when 'slot' then
      true  -- TBD when slot data lands
    when 'right' then
      true  -- TBD when right data lands
    else false
  end;
$$;

comment on function public.is_valid_resource_metadata(text, jsonb) is
  'Required-key check per resource_type. Update via a new migration as types ship optional contracts.';

alter table public.resources
  drop constraint if exists resources_metadata_shape_chk;

alter table public.resources
  add constraint resources_metadata_shape_chk
  check (public.is_valid_resource_metadata(resource_type, metadata)) not valid;

alter table public.resources
  validate constraint resources_metadata_shape_chk;
