-- 00109 rollback — restore the pre-00109 seeder (without event-shape primitives).
--
-- Does NOT remove the description / host_actions rows from
-- resource_capabilities — those rows survive rollback. Hand-edit if a true
-- revert is required.

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
