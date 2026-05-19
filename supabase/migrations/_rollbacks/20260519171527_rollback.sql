-- Rollback for 20260519171527_close_event_for_update_atomic.sql.
-- Restores the pre-V1-02 bodies of close_event + close_event_no_fines from
-- mig 00236. WARNING: reintroduces the race (two admins → duplicate
-- eventClosed atoms → duplicate fines). Emergency revert only.

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
