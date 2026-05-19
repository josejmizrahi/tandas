-- 00333 — Fix mig 00332: emit hostAssigned atom from the LIVE trigger function.
-- Mig 00332 patched the orphan on_event_inserted_host_assigned() whose trigger
-- died when public.events was dropped in mig 00158. The active trigger is
-- on_resource_event_inserted() on public.resources. Add system_event emission
-- there; drop the orphan.

create or replace function public.on_resource_event_inserted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host_id    uuid;
  v_starts_at  timestamptz;
  v_tz         text;
  v_title      text;
  v_cycle      int;
  v_payload    jsonb;
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

    v_payload := jsonb_build_object(
      'title',       coalesce(v_title, 'Evento'),
      'starts_at',   to_char(v_starts_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'assigned_by', NEW.created_by,
      'cycle',       v_cycle
    );

    perform public.record_system_event(
      p_group_id    => NEW.group_id,
      p_event_type  => 'hostAssigned',
      p_resource_id => NEW.id,
      p_member_id   => v_host_id,
      p_payload     => v_payload
    );
  end if;
  return NEW;
end;
$$;

revoke execute on function public.on_resource_event_inserted() from public, anon;
grant  execute on function public.on_resource_event_inserted() to authenticated, service_role;

comment on function public.on_resource_event_inserted() is
  'mig 00333: emits user_action(hostAssigned) + system_event(hostAssigned) when a resources row of type=event lands with host_id != created_by. Replaces the orphan on_event_inserted_host_assigned() function which mig 00332 mistakenly patched.';

drop function if exists public.on_event_inserted_host_assigned();;
