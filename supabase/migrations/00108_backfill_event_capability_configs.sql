-- 00108 — Backfill resource_capabilities.config from event metadata
-- and keep new events in sync.
--
-- Audit task M.9 (safe step — column drop is Phase 5).
--
-- Today (post-00078 + 00096):
--   - Every event has resource_capabilities rows for the blocks its
--     active modules provide (appeal, assignment, attendance, check_in,
--     consequence, deadline, ledger, participants, rotation, rsvp,
--     rules, voting).
--   - 100% of those rows carry config = '{}' jsonb — empty.
--   - The capability-shaped data (rsvp_deadline, capacity_max,
--     allow_plus_ones, max_plus_ones_per_member) lives only in
--     events.* columns + resources.metadata (mirrored by 00039
--     dual-write trigger).
--   - capacity and guest_access blocks are NOT seeded by any V1
--     module today; their rows do not exist at all.
--
-- This migration:
--   1. Extends seed_event_default_capabilities(p_event_id) to also
--      populate config jsonb from resources.metadata after seeding
--      the rows. Idempotent — re-running on an event that already has
--      filled config is a noop because the UPDATE only writes when the
--      computed config differs from '{}'.
--   2. Creates capacity / guest_access rows when the metadata signals
--      the event uses them, even though no module currently provides
--      those blocks. This is forward-compat: when Phase 2 wires those
--      blocks into a module, the rows are already there with the right
--      config.
--   3. Runs the seeder over every existing event so production becomes
--      consistent. ~100 events estimated, idempotent loop.
--
-- iOS read path is unchanged — Event.swift keeps reading the columns.
-- The config jsonb is the secondary copy that becomes canonical when
-- Phase 5 drops the columns.

create or replace function public.seed_event_default_capabilities(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id       uuid;
  v_active_modules jsonb;
  v_metadata       jsonb;
  v_rsvp_deadline       text;
  v_capacity_max        int;
  v_allow_plus_ones     boolean;
  v_max_plus_ones       int;
begin
  select r.group_id, g.active_modules, r.metadata
    into v_group_id, v_active_modules, v_metadata
    from public.resources r
    join public.groups g on g.id = r.group_id
   where r.id = p_event_id
     and r.resource_type = 'event';

  if v_group_id is null then return; end if;

  -- 1. Seed default capability rows from groups.active_modules
  --    × modules.provided_capability_blocks (original behavior).
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

  -- 2. Extract capability-shaped fields from metadata. Defensive casts
  --    so a malformed value (string where int expected, etc.) does not
  --    crash the seeder — the field falls through to null and we skip
  --    its config row instead of aborting the whole event.
  v_rsvp_deadline    := v_metadata ->> 'rsvp_deadline';
  begin
    v_capacity_max := (v_metadata ->> 'capacity_max')::int;
  exception when others then v_capacity_max := null; end;
  begin
    v_allow_plus_ones := (v_metadata ->> 'allow_plus_ones')::boolean;
  exception when others then v_allow_plus_ones := false; end;
  begin
    v_max_plus_ones := coalesce((v_metadata ->> 'max_plus_ones_per_member')::int, 0);
  exception when others then v_max_plus_ones := 0; end;

  -- 3a. rsvp config: deadline. Only update when the metadata has it;
  --     never overwrite a non-empty config with empty.
  if v_rsvp_deadline is not null then
    update public.resource_capabilities
       set config = jsonb_build_object('deadline', v_rsvp_deadline)
     where resource_id = p_event_id
       and capability_block_id = 'rsvp'
       and config = '{}'::jsonb;
  end if;

  -- 3b. capacity config: max. Block may not be seeded by any module,
  --     so upsert the row alongside its config.
  if v_capacity_max is not null then
    insert into public.resource_capabilities (resource_id, capability_block_id, enabled, config, enabled_at)
      values (p_event_id, 'capacity', true, jsonb_build_object('max', v_capacity_max), now())
    on conflict (resource_id, capability_block_id) do update
      set config = excluded.config
      where public.resource_capabilities.config = '{}'::jsonb;
  end if;

  -- 3c. guest_access config: perMemberLimit + approvalRequired.
  --     Only when the event indicates plus-ones are allowed or a per-
  --     member limit was set explicitly.
  if v_allow_plus_ones or v_max_plus_ones > 0 then
    insert into public.resource_capabilities (resource_id, capability_block_id, enabled, config, enabled_at)
      values (
        p_event_id,
        'guest_access',
        true,
        jsonb_build_object(
          'perMemberLimit',   v_max_plus_ones,
          'approvalRequired', false
        ),
        now()
      )
    on conflict (resource_id, capability_block_id) do update
      set config = excluded.config
      where public.resource_capabilities.config = '{}'::jsonb;
  end if;
end;
$$;

comment on function public.seed_event_default_capabilities(uuid) is
  'Idempotent seeding + config backfill for an event resource. Populates default rows from groups.active_modules × modules.provided_capability_blocks (Taxonomy §2), then fills config jsonb for rsvp / capacity / guest_access from resources.metadata. The capacity / guest_access rows are upserted when the event metadata signals usage, even though no V1 module owns those blocks yet. Audit task M.9.';

-- 4. One-shot backfill: run the seeder for every existing event so
--    production becomes consistent post-migration. Idempotent.
do $$
declare
  e_id uuid;
begin
  for e_id in select id from public.resources where resource_type = 'event' loop
    perform public.seed_event_default_capabilities(e_id);
  end loop;
end;
$$;
