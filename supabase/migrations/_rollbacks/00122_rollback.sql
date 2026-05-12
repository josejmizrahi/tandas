-- 00122_rollback.sql
-- Reverts the rule-create RPCs to the pre-00122 shape (is_group_admin
-- direct gate, no governance routing). Existing rules remain; this only
-- changes the gate for FUTURE creates. WARNING: rolling back
-- re-introduces the bypass where admins can add rules in groups whose
-- rule.create policy is vote_required.

create or replace function public.create_initial_rule(
  p_group_id     uuid,
  p_slug         text,
  p_name         text,
  p_is_active    boolean,
  p_trigger      jsonb,
  p_conditions   jsonb,
  p_consequences jsonb
) returns public.rules
language plpgsql security definer set search_path = public as $$
declare
  r public.rules;
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'only admins can seed rules';
  end if;
  insert into public.rules (
    group_id, slug, name, is_active, trigger, conditions, consequences, proposed_by
  ) values (
    p_group_id, p_slug, p_name, p_is_active,
    p_trigger, coalesce(p_conditions, '[]'::jsonb), coalesce(p_consequences, '[]'::jsonb),
    auth.uid()
  ) returning * into r;
  return r;
end;
$$;

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
  if v_uid is null then raise exception 'auth required'; end if;
  if p_name is null or length(trim(p_name)) < 2 then raise exception 'rule name must be at least 2 characters'; end if;
  if p_trigger is null then raise exception 'rule trigger required'; end if;
  select * into v_resource from public.resources r where r.id = p_resource_id;
  if not found then raise exception 'resource not found'; end if;
  if v_resource.group_id <> p_group_id then raise exception 'resource does not belong to group'; end if;
  if not public.is_group_admin(p_group_id, v_uid) then
    if v_resource.resource_type = 'event' then
      if not exists (
        select 1 from public.events e where e.id = p_resource_id and e.host_id = v_uid
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
    module_key, series_id, membership_id, proposed_by
  )
  values (
    p_group_id, p_resource_id, null, trim(p_name), true,
    coalesce(p_trigger, '{}'::jsonb), coalesce(p_conditions, '[]'::jsonb),
    coalesce(p_consequences, '[]'::jsonb),
    null, null, null, v_uid
  )
  returning * into v_rule;
  return v_rule;
end;
$$;

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
begin
  return public.create_resource_rule(
    p_group_id, p_resource_id, p_name, p_trigger, p_conditions, p_consequences
  );
end;
$$;
