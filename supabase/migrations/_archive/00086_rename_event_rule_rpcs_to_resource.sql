-- 00086 — Generalize event-rule RPCs to resource-rule RPCs (Phase 4 R4).
--
-- Mig 00083 / 00085 named the RPCs `create_event_rule` and
-- `list_event_rules_with_inherited`. They were already polymorphic
-- internally (the host check only kicks in for resource_type='event';
-- everything else falls through to admin-only). The names were
-- event-centric because slice 1 only had event surfaces.
--
-- Per founder framing 2026-05-10 (4-layer model: Group / Resource /
-- Capability / Rule), the rules engine must apply to ANY resource. This
-- migration adds two cleanly-named functions that mirror the existing
-- ones; the originals stay as redundant entry points until the iOS app
-- is rebuilt + reinstalled. They can be dropped in a follow-up mig.

create or replace function public.create_resource_rule(
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

  select * into v_resource from public.resources r where r.id = p_resource_id;
  if not found then
    raise exception 'resource not found';
  end if;
  if v_resource.group_id <> p_group_id then
    raise exception 'resource does not belong to group';
  end if;

  -- Authorization: group admin always; for events the host of that
  -- specific event may also author rules on it (host owns the event).
  -- Other resource types stay admin-only until they grow their own
  -- ownership concept.
  if not public.is_group_admin(p_group_id, v_uid) then
    if v_resource.resource_type = 'event' then
      if not exists (
        select 1 from public.events e
         where e.id = p_resource_id and e.host_id = v_uid
      ) then
        raise exception 'only group admins or the event host can create rules for this event';
      end if;
    else
      raise exception 'only group admins can create rules for this resource';
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

revoke execute on function public.create_resource_rule(uuid, uuid, text, jsonb, jsonb, jsonb) from public, anon;
grant  execute on function public.create_resource_rule(uuid, uuid, text, jsonb, jsonb, jsonb) to authenticated;

comment on function public.create_resource_rule(uuid, uuid, text, jsonb, jsonb, jsonb) is
  'Creates a user-authored rule scoped to a Resource (rules.resource_id set). Polymorphic over resource type per Taxonomy §29. Caller must be group admin OR (for event resources) the event host. Supersedes create_event_rule.';

-- =========================================================
-- list_resource_rules_with_inherited
-- =========================================================
-- Returns event-scope / series-scope / group-scope rules in one go.
-- Same JOIN pattern as list_event_rules_with_inherited (mig 00085) —
-- already polymorphic; renamed for clarity.

create or replace function public.list_resource_rules_with_inherited(p_resource_id uuid)
returns setof public.rules
language sql security definer set search_path = public stable as $$
  -- 1. resource scope
  select r.*
    from public.rules r
   where r.resource_id = p_resource_id

  union all

  -- 2. series scope (only when the resource is part of a series)
  select r.*
    from public.rules r
    join public.resources res on res.id = p_resource_id
   where res.series_id is not null
     and r.series_id = res.series_id
     and r.resource_id is null

  union all

  -- 3. group scope
  select r.*
    from public.rules r
    join public.resources res on res.id = p_resource_id
   where r.group_id = res.group_id
     and r.resource_id is null
     and r.series_id is null;
$$;

revoke execute on function public.list_resource_rules_with_inherited(uuid) from public, anon;
grant  execute on function public.list_resource_rules_with_inherited(uuid) to authenticated;

comment on function public.list_resource_rules_with_inherited(uuid) is
  'Returns rules applicable to a resource in one query: own-scope + series + group. Polymorphic over resource type. Supersedes list_event_rules_with_inherited.';
