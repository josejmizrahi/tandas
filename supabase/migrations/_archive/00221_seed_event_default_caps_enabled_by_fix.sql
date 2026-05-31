-- Mig 00221 — fix seed_event_default_capabilities enabled_by violation.
--
-- Bug
-- ===
-- Mig 00096 defined `seed_event_default_capabilities(p_event_id)` to
-- INSERT into resource_capabilities with `null::uuid` for enabled_by.
-- The function is invoked by `trg_resources_seed_event_caps` AFTER
-- INSERT on resources (resource_type='event'), so every event created
-- via create_event_v2 / build_resource_from_draft fires this path.
--
-- Mig 00190 later added NOT NULL on `resource_capabilities.enabled_by`
-- and backfilled existing NULL rows from `resources.created_by`. But
-- the trigger function was never updated, so the next event creation
-- raises:
--
--   ERROR: null value in column "enabled_by" of relation
--   "resource_capabilities" violates not-null constraint
--
-- Surfaced 2026-05-15 when migration prefix collisions were resolved
-- and CI's `supabase start` reached the e2e test phase for the first
-- time in days. All create_event_v2 / build_resource_from_draft tests
-- failed with this exact error.
--
-- Fix
-- ===
-- Replace the function with the same logic, but source enabled_by from
-- the resource's `created_by` — matching mig 00190's backfill
-- semantics ("the actor who created the resource enabled the seeded
-- capabilities"). All other behavior unchanged: idempotent via
-- ON CONFLICT DO NOTHING, SECURITY DEFINER, fixed search_path.

create or replace function public.seed_event_default_capabilities(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id       uuid;
  v_active_modules jsonb;
  v_created_by     uuid;
begin
  select r.group_id, g.active_modules, r.created_by
    into v_group_id, v_active_modules, v_created_by
    from public.resources r
    join public.groups g on g.id = r.group_id
   where r.id = p_event_id
     and r.resource_type = 'event';

  if v_group_id is null then return; end if;

  -- enabled_by = resources.created_by; mirrors mig 00190's NOT NULL
  -- backfill ("every enablement has provenance"). Without this, the
  -- AFTER INSERT auto-seed path breaks the constraint on every event
  -- creation.
  insert into public.resource_capabilities (
      resource_id, capability_block_id, enabled, enabled_at, enabled_by
    )
    select distinct
      p_event_id,
      block,
      true,
      now(),
      v_created_by
    from jsonb_array_elements_text(coalesce(v_active_modules, '[]'::jsonb)) AS active(module_id)
    join public.modules m on m.id = active.module_id
    cross join lateral unnest(coalesce(m.provided_capability_blocks, '{}'::text[])) AS block
  on conflict (resource_id, capability_block_id) do nothing;
end;
$$;

comment on function public.seed_event_default_capabilities(uuid) is
  'Idempotent seeding of resource_capabilities for an event resource. Derives the default set from groups.active_modules × modules.provided_capability_blocks. enabled_by = resources.created_by (mig 00221 — mig 00190 added NOT NULL on enabled_by, breaking the original null::uuid path). Safe to call multiple times — purely additive via ON CONFLICT DO NOTHING.';
