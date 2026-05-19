-- Rollback for 20260519173412_reopen_event_for_update_atomic.sql.
-- Restores the pre-V1-06 body of reopen_event from mig 00295.
-- WARNING: reintroduces the race (two admins → duplicate eventReopened
-- atoms). Emergency revert only.

create or replace function public.reopen_event(p_event_id uuid)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
  v_host_id uuid;
  v_prev_status text;
begin
  select * into v_resource from public.resources
   where id = p_event_id and resource_type = 'event';
  if v_resource.id is null then
    raise exception 'event not found' using errcode = '02000';
  end if;

  v_host_id := nullif(v_resource.metadata->>'host_id', '')::uuid;
  if not (v_host_id = auth.uid()
          or public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents')) then
    raise exception 'host or manageEvents permission required' using errcode = '42501';
  end if;

  v_prev_status := v_resource.status;
  if v_prev_status not in ('completed', 'cancelled') then
    select * into v_view_row from public.events_view where id = p_event_id;
    return v_view_row;
  end if;

  update public.resources
     set status = 'scheduled',
         metadata = ((metadata - 'closed_at') - 'cancelled_at') - 'cancellation_reason',
         updated_at = now()
   where id = p_event_id;

  perform public.record_system_event(
    v_resource.group_id, 'eventReopened', p_event_id, null,
    jsonb_build_object(
      'title', v_resource.metadata->>'title',
      'previous_status', v_prev_status,
      'reopened_by', auth.uid(),
      'reopened_at', now()
    )
  );

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;
