-- 00096 — Auto-seed default capability_blocks on every new event resource.
--
-- The audit gap closed by this migration: events shipped to prod without
-- any `resource_capabilities` rows because the only writer was the iOS
-- `EnableCapabilitySheet` (manual user action). The "Ver como recurso
-- (Beta)" path in EventDetailView opened a near-empty universal view —
-- the section catalog gated everything except `activity` on a
-- capability that was never set. The existing 6 events have wildly
-- different sets (3-8 caps each) because they were configured manually
-- during dev.
--
-- Default rule mirrors `CapabilityResolver.availableCapabilities(for: .event)`
-- in iOS: union of `provided_capability_blocks` across every module
-- in the group's `active_modules`. Adds only, never removes — events
-- with extra caps (e.g. `money`, `schedule`, `participants` enabled
-- manually) keep them.

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

  -- Insert distinct (resource_id, capability_block_id) pairs derived from
  -- the union of provided_capability_blocks across active modules.
  -- ON CONFLICT keeps existing rows untouched — purely additive.
  -- null::uuid cast required because the column is uuid and the bare
  -- `null` literal would otherwise resolve to text in the union projection.
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
end;
$$;

comment on function public.seed_event_default_capabilities(uuid) is
  'Idempotent seeding of resource_capabilities for an event resource. Derives the default set from groups.active_modules × modules.provided_capability_blocks. Mirrors CapabilityResolver.availableCapabilities(for: .event, in: group) in iOS. Safe to call multiple times — purely additive via ON CONFLICT DO NOTHING.';

-- Trigger: every new event resource picks up its default capabilities.
-- Fires after the polymorphic resources row is inserted (either directly
-- in Phase 2 flows or via the 00039 dual-write trigger from events).
create or replace function public.trg_resources_seed_event_caps()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.resource_type = 'event' then
    perform public.seed_event_default_capabilities(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists resources_seed_event_caps_after_insert on public.resources;
create trigger resources_seed_event_caps_after_insert
  after insert on public.resources
  for each row
  execute function public.trg_resources_seed_event_caps();

comment on trigger resources_seed_event_caps_after_insert on public.resources is
  'Calls seed_event_default_capabilities for new event resources. Phase 2 non-event types will need their own seeding hooks per the audit doc.';

-- Backfill: run the seeder for every existing event so the prod data
-- becomes consistent with the trigger from now on. Idempotent.
do $$
declare
  e_id uuid;
begin
  for e_id in select id from public.resources where resource_type = 'event' loop
    perform public.seed_event_default_capabilities(e_id);
  end loop;
end;
$$;

revoke execute on function public.seed_event_default_capabilities(uuid) from public, anon;
grant  execute on function public.seed_event_default_capabilities(uuid) to authenticated, service_role;
