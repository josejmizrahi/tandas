-- 00083 — create_event_rule RPC (Phase 4 in-event rule creation slice 1).
--
-- Adds a SECURITY DEFINER write path for `public.rules` scoped to a single
-- resource (an event for V1, but the RPC is shape-agnostic — works for any
-- resource id). The Taxonomy §29 scope contract:
--
--     rules.resource_id IS NOT NULL  → applies to that resource only
--     rules.module_key  IS NULL       → not a module-shipped rule
--     rules.slug        IS NULL       → user-authored, no platform identity
--
-- create_initial_rule (mig 00058) is admin-only and writes group-level
-- rules. This RPC is broader: a group admin OR the event's host may
-- author rules for that event. Hosts owning event-specific rules matches
-- the "host runs this dinner" mental model from Plans/Active/Beta1.md.
--
-- Future relaxation (Phase 4b): allow any member to propose an event rule
-- subject to a vote. Out of scope for this slice.

create or replace function public.create_event_rule(
  p_group_id     uuid,
  p_resource_id  uuid,
  p_name         text,
  p_trigger      jsonb,
  p_conditions   jsonb,
  p_consequences jsonb
)
returns public.rules
language plpgsql security definer set search_path = public as $$
declare
  v_rule public.rules;
  v_resource public.resources;
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;

  if p_name is null or length(trim(p_name)) < 2 then
    raise exception 'rule name must be at least 2 characters';
  end if;

  if p_trigger is null then
    raise exception 'rule trigger required';
  end if;

  -- Resolve the target resource + confirm it belongs to the group.
  select * into v_resource from public.resources r where r.id = p_resource_id;
  if not found then
    raise exception 'resource not found';
  end if;
  if v_resource.group_id <> p_group_id then
    raise exception 'resource does not belong to group';
  end if;

  -- Authorization: group admin OR event host (when the resource is an
  -- event). For non-event resource types the host check fails silently and
  -- the gate collapses to admin-only; relax per-type later as new resource
  -- kinds gain explicit owners.
  if not public.is_group_admin(p_group_id, v_uid) then
    if v_resource.resource_type = 'event' then
      if not exists (
        select 1 from public.events e
         where e.id = p_resource_id and e.host_id = v_uid
      ) then
        raise exception 'only group admins or the event host can create event rules';
      end if;
    else
      raise exception 'only group admins can create rules for this resource type';
    end if;
  end if;

  insert into public.rules (
    group_id, resource_id, slug, name, is_active,
    trigger, conditions, consequences,
    module_key, series_id, membership_id,
    proposed_by
  )
  values (
    p_group_id, p_resource_id, null, trim(p_name), true,
    coalesce(p_trigger, '{}'::jsonb),
    coalesce(p_conditions, '[]'::jsonb),
    coalesce(p_consequences, '[]'::jsonb),
    null, null, null,
    v_uid
  )
  returning * into v_rule;

  return v_rule;
end;
$$;

revoke execute on function public.create_event_rule(uuid, uuid, text, jsonb, jsonb, jsonb) from public, anon;
grant  execute on function public.create_event_rule(uuid, uuid, text, jsonb, jsonb, jsonb) to authenticated;

comment on function public.create_event_rule(uuid, uuid, text, jsonb, jsonb, jsonb) is
  'Creates a user-authored rule scoped to a specific resource (rules.resource_id set). Caller must be group admin OR (for event resources) the event host. Per Taxonomy §29: resource_id-scoped rules override module/group scope. Phase 4 in-event rules slice 1.';
