create or replace function public.on_resource_event_inserted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host_id        uuid;
  v_host_member_id uuid;
  v_starts_at      timestamptz;
  v_tz             text;
  v_title          text;
  v_cycle          int;
  v_payload        jsonb;
begin
  if NEW.resource_type <> 'event' then return NEW; end if;

  v_host_id   := (NEW.metadata->>'host_id')::uuid;
  v_starts_at := (NEW.metadata->>'starts_at')::timestamptz;
  v_title     := NEW.metadata->>'title';
  v_cycle     := nullif(NEW.metadata->>'cycle_number', '')::int;

  if v_host_id is not null
     and (NEW.created_by is null or v_host_id <> NEW.created_by) then
    select nullif(trim(coalesce(timezone, '')), '')
      into v_tz
      from public.groups
     where id = NEW.group_id;
    v_tz := coalesce(v_tz, 'America/Mexico_City');

    insert into public.user_actions (
      user_id, group_id, action_type, reference_id, title, body, priority
    ) values (
      v_host_id, NEW.group_id, 'hostAssigned', NEW.id,
      'Te toca ser anfitrión',
      coalesce(v_title, 'Evento') || ' — ' || to_char(v_starts_at at time zone v_tz, 'DD Mon YYYY'),
      'medium'
    );

    select id
      into v_host_member_id
      from public.group_members
     where group_id = NEW.group_id
       and user_id  = v_host_id
       and active   = true
     limit 1;

    v_payload := jsonb_build_object(
      'title',       coalesce(v_title, 'Evento'),
      'starts_at',   to_char(v_starts_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'assigned_by', NEW.created_by,
      'host_user_id', v_host_id,
      'cycle',       v_cycle
    );

    perform public.record_system_event(
      p_group_id    => NEW.group_id,
      p_event_type  => 'hostAssigned',
      p_resource_id => NEW.id,
      p_member_id   => v_host_member_id,
      p_payload     => v_payload
    );
  end if;
  return NEW;
end;
$$;

revoke execute on function public.on_resource_event_inserted() from public, anon;
grant  execute on function public.on_resource_event_inserted() to authenticated, service_role;

comment on function public.on_resource_event_inserted() is
  'mig 00334: resolves host_user_id -> group_members.id before passing to record_system_event (the FK target).';;
