-- 00110 — Extend seed_event_default_capabilities with two more event-shape
-- primitives so the universal detail surface lights up their dedicated
-- capability sections regardless of module config:
--
--   location — surfaces a LocationSection (name + map button) when
--              metadata.location_name is set. Section renders EmptyView
--              when absent, so always-on is safe.
--   capacity — surfaces a CapacityProgressSection (X/Y + LLENO pill)
--              when metadata.capacity_max is set. EmptyView when absent.
--
-- Same idempotent pattern as 00109: ON CONFLICT DO NOTHING preserves any
-- manual overrides made via EnableCapabilitySheet.

create or replace function public.seed_event_default_capabilities(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id       uuid;
  v_active_modules jsonb;
begin
  select r.group_id, g.active_modules
    into v_group_id, v_active_modules
    from public.resources r
    join public.groups g on g.id = r.group_id
   where r.id = p_event_id
     and r.resource_type = 'event';

  if v_group_id is null then return; end if;

  -- Module-derived capabilities (unchanged from 00096).
  insert into public.resource_capabilities (
      resource_id, capability_block_id, enabled, enabled_at, enabled_by
    )
    select distinct
      p_event_id,
      block,
      true,
      now(),
      null::uuid
    from jsonb_array_elements_text(coalesce(v_active_modules, '[]'::jsonb)) AS active(module_id)
    join public.modules m on m.id = active.module_id
    cross join lateral unnest(coalesce(m.provided_capability_blocks, '{}'::text[])) AS block
  on conflict (resource_id, capability_block_id) do nothing;

  -- Event-shape primitives — always-on for events regardless of module config.
  insert into public.resource_capabilities (
      resource_id, capability_block_id, enabled, enabled_at, enabled_by
    )
    values
      (p_event_id, 'description',  true, now(), null::uuid),
      (p_event_id, 'host_actions', true, now(), null::uuid),
      (p_event_id, 'location',     true, now(), null::uuid),
      (p_event_id, 'capacity',     true, now(), null::uuid)
  on conflict (resource_id, capability_block_id) do nothing;
end;
$$;

comment on function public.seed_event_default_capabilities(uuid) is
  'Idempotent seeding of resource_capabilities for an event resource. Combines (1) modules.provided_capability_blocks of active group modules with (2) event-shape primitives (description, host_actions, location, capacity) hard-coded here. Safe to call multiple times via ON CONFLICT DO NOTHING.';

-- Backfill — re-run the seeder for every existing event. Idempotent.
do $$
declare
  e_id uuid;
begin
  for e_id in select id from public.resources where resource_type = 'event' loop
    perform public.seed_event_default_capabilities(e_id);
  end loop;
end;
$$;
