-- 00235 — Event RPCs gated on has_permission (Permission catalog v2).

alter table public.groups
  alter column roles set default
    jsonb_build_object(
      'founder', jsonb_build_object(
        'system', true,
        'permissions', jsonb_build_array(
          'modifyGovernance','modifyRules','modifyMembers',
          'assignRoles','removeMember',
          'issueFine','voidFine','markFinePaid','closeAppeal',
          'createVotes','manageEvents'
        )
      ),
      'member', jsonb_build_object(
        'system', true,
        'permissions', jsonb_build_array('createVotes','castVote')
      )
    );

update public.groups
   set roles = jsonb_set(
     roles,
     '{founder,permissions}',
     (
       select coalesce(jsonb_agg(distinct p), '[]'::jsonb)
       from (
         select jsonb_array_elements_text(
           coalesce(roles -> 'founder' -> 'permissions', '[]'::jsonb)
         ) as p
         union
         select unnest(array['manageEvents']) as p
       ) merged
     )
   )
 where roles ? 'founder';

update public.templates
   set config = jsonb_set(
     config,
     '{defaultRoles,founder,permissions}',
     (
       select coalesce(jsonb_agg(distinct p), '[]'::jsonb)
       from (
         select jsonb_array_elements_text(
           coalesce(config -> 'defaultRoles' -> 'founder' -> 'permissions', '[]'::jsonb)
         ) as p
         union
         select unnest(array['manageEvents']) as p
       ) merged
     )
   )
 where config -> 'defaultRoles' -> 'founder' is not null;

create or replace function public.close_event(p_event_id uuid)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
begin
  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  if not public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents') then
    raise exception 'manageEvents permission required' using errcode = '42501';
  end if;

  update public.resources
     set status = 'completed',
         metadata = jsonb_set(metadata, '{closed_at}', to_jsonb(now()::text)),
         updated_at = now()
   where id = p_event_id;

  perform public.record_system_event(
    v_resource.group_id, 'eventClosed', p_event_id, null,
    jsonb_build_object(
      'title', v_resource.metadata->>'title',
      'closed_at', now(),
      'status', 'completed'
    )
  );

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.close_event(uuid) is
  'v2 (mig 00235): auth gate is has_permission(manageEvents) instead of is_group_admin.';

create or replace function public.close_event_no_fines(p_event_id uuid)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
  v_host_id  uuid;
begin
  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  v_host_id := (v_resource.metadata->>'host_id')::uuid;
  if not (v_host_id = auth.uid()
          or public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents')) then
    raise exception 'host or manageEvents permission required' using errcode = '42501';
  end if;

  update public.resources
     set status = 'completed',
         metadata = jsonb_set(metadata, '{closed_at}', to_jsonb(now()::text)),
         updated_at = now()
   where id = p_event_id;

  perform public.record_system_event(
    v_resource.group_id, 'eventClosed', p_event_id, null,
    jsonb_build_object(
      'title', v_resource.metadata->>'title',
      'closed_at', now(),
      'status', 'completed'
    )
  );

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.close_event_no_fines(uuid) is
  'v2 (mig 00235): auth gate is host OR has_permission(manageEvents) instead of host OR is_group_admin.';

create or replace function public.cancel_event(p_event_id uuid, p_reason text default null)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
  v_host_id  uuid;
begin
  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  v_host_id := (v_resource.metadata->>'host_id')::uuid;
  if not (v_host_id = auth.uid()
          or public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents')) then
    raise exception 'host or manageEvents permission required' using errcode = '42501';
  end if;

  update public.resources
     set status   = 'cancelled',
         metadata = case
           when p_reason is null then metadata
           else jsonb_set(metadata, '{cancellation_reason}', to_jsonb(p_reason::text))
         end,
         updated_at = now()
   where id = p_event_id;

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.cancel_event(uuid, text) is
  'v2 (mig 00235): auth gate is host OR has_permission(manageEvents) instead of host OR is_group_admin.';

create or replace function public.update_event_metadata(p_event_id uuid, p_patch jsonb)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_host_id  uuid;
  v_view_row public.events_view;
begin
  select * into v_resource from public.resources
   where id = p_event_id and resource_type = 'event';
  if v_resource.id is null then raise exception 'event not found'; end if;

  v_host_id := (v_resource.metadata->>'host_id')::uuid;
  if not (v_host_id = auth.uid()
          or public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents')) then
    raise exception 'host or manageEvents permission required' using errcode = '42501';
  end if;

  update public.resources
     set metadata = metadata || p_patch,
         updated_at = now()
   where id = p_event_id;

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.update_event_metadata(uuid, jsonb) is
  'v2 (mig 00235): auth gate is host OR has_permission(manageEvents) instead of host OR is_group_admin.';

create or replace function public.check_in_v2(
  p_event_id           uuid,
  p_user_id            uuid,
  p_method             text default 'self',
  p_location_verified  boolean default false,
  p_arrived_at         timestamptz default null
)
returns public.attendance_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource  public.resources;
  v_member_id uuid;
  v_view_row  public.attendance_view;
begin
  if p_method not in ('self', 'qr_scan', 'host_marked') then
    raise exception 'invalid method: %', p_method;
  end if;
  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  if not (auth.uid() = p_user_id
          or public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents')) then
    raise exception 'self or manageEvents permission required' using errcode = '42501';
  end if;

  select id into v_member_id from public.group_members
   where group_id = v_resource.group_id and user_id = p_user_id limit 1;
  if v_member_id is null then raise exception 'membership not found'; end if;

  insert into public.check_in_actions (
    resource_id, member_id, arrived_at, metadata
  ) values (
    p_event_id, v_member_id, coalesce(p_arrived_at, now()),
    jsonb_strip_nulls(jsonb_build_object(
      'check_in_method', p_method,
      'check_in_location_verified', coalesce(p_location_verified, false),
      'marked_by', auth.uid(),
      'via', 'check_in_v2'
    ))
  );

  select * into v_view_row from public.attendance_view
   where resource_id = p_event_id and member_id = v_member_id;
  return v_view_row;
end;
$$;

comment on function public.check_in_v2(uuid, uuid, text, boolean, timestamptz) is
  'v2 (mig 00235): auth gate is self OR has_permission(manageEvents) instead of self OR is_group_admin. Self check-in always allowed without permission.';
