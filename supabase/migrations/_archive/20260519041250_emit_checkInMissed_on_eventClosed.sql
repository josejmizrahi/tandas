create or replace function public.on_event_closed_emit_check_in_missed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource_metadata jsonb;
  v_starts_at         timestamptz;
  v_title             text;
  v_host_id           uuid;
  v_payload           jsonb;
  v_rec               record;
begin
  if NEW.event_type <> 'eventClosed' then
    return NEW;
  end if;

  select metadata into v_resource_metadata
    from public.resources
   where id = NEW.resource_id;
  if not found then
    return NEW;
  end if;

  v_starts_at := (v_resource_metadata->>'starts_at')::timestamptz;
  v_title     := v_resource_metadata->>'title';
  v_host_id   := (v_resource_metadata->>'host_id')::uuid;

  v_payload := jsonb_strip_nulls(jsonb_build_object(
    'title',     coalesce(v_title, 'Evento'),
    'starts_at', case when v_starts_at is not null
                      then to_char(v_starts_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                      else null end,
    'host_id',   v_host_id,
    'reason',    'no_check_in_after_close'
  ));

  for v_rec in
    select member_id
      from public.attendance_view
     where resource_id = NEW.resource_id
       and no_show     = true
       and member_id   is not null
  loop
    if not exists (
      select 1 from public.system_events
       where resource_id = NEW.resource_id
         and member_id   = v_rec.member_id
         and event_type  = 'checkInMissed'
    ) then
      perform public.record_system_event(
        p_group_id    => NEW.group_id,
        p_event_type  => 'checkInMissed',
        p_resource_id => NEW.resource_id,
        p_member_id   => v_rec.member_id,
        p_payload     => v_payload
      );
    end if;
  end loop;

  return NEW;
end;
$$;

revoke execute on function public.on_event_closed_emit_check_in_missed() from public, anon;
grant  execute on function public.on_event_closed_emit_check_in_missed() to authenticated, service_role;

drop trigger if exists trg_on_event_closed_emit_check_in_missed on public.system_events;
create trigger trg_on_event_closed_emit_check_in_missed
  after insert on public.system_events
  for each row
  when (NEW.event_type = 'eventClosed')
  execute function public.on_event_closed_emit_check_in_missed();

comment on function public.on_event_closed_emit_check_in_missed() is
  'mig 00338: per-member checkInMissed fan-out when eventClosed lands. Reads attendance_view.no_show. Per-(resource,member) dedup. Covers manual close_event + auto-close cron.';;
