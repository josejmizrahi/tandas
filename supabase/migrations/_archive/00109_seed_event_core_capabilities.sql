-- 00109 — Extend seed_event_default_capabilities with two core capabilities
-- inherent to every event:
--
--   description  — the event's free-text body. Every event has it (nullable
--                  in DB, possibly empty). Surfaces a DescriptionSection in
--                  the polymorphic detail when metadata.description is set.
--   host_actions — host-only action panel (reminders, edit, scanner, cancel,
--                  close, autogen toggle, manual fine). Inherent because
--                  every event has a host_id. The capability section renders
--                  EmptyView when the viewer is not the host.
--
-- These are NOT provided by any module — they're event-shape primitives.
-- Hard-coding them here reflects that truth and keeps modules focused on
-- truly optional behaviors (rotating host, appeals, slot assignment...).
--
-- Idempotent: ON CONFLICT DO NOTHING preserves any manual overrides made
-- via EnableCapabilitySheet.

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
      (p_event_id, 'host_actions', true, now(), null::uuid)
  on conflict (resource_id, capability_block_id) do nothing;
end;
$$;

comment on function public.seed_event_default_capabilities(uuid) is
  'Idempotent seeding of resource_capabilities for an event resource. Combines (1) modules.provided_capability_blocks of active group modules with (2) event-shape primitives (description, host_actions) hard-coded here. Safe to call multiple times via ON CONFLICT DO NOTHING.';

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
