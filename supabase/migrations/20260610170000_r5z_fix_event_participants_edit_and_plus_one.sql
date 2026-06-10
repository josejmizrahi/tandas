-- R.5Z.fix.EVENT.PARTICIPANTS (2026-06-10 founder smoke Campo Marte) —
-- 3 RPCs nuevos para editar el roster de un evento + flag +1 por participant.
-- Sin alterar el schema (plus_one se guarda en event_participants.metadata).

-- Add: agrega 1+ actors como participants. Solo host o events.manage.
-- Si el actor ya es participant (cualquier status), no-op idempotente.
create or replace function public.add_event_participants(
  p_event_id uuid,
  p_actor_ids uuid[]
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_ev public.calendar_events%rowtype;
  v_added int := 0;
  v_actor_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ev from public.calendar_events where id = p_event_id;
  if v_ev.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if v_ev.status in ('completed','cancelled') then
    raise exception 'cannot edit participants of a terminal event' using errcode = '22023';
  end if;
  if v_ev.host_actor_id <> v_caller
     and not public.has_actor_authority(v_ev.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized (host o events.manage)' using errcode = '42501';
  end if;

  foreach v_actor_id in array p_actor_ids loop
    if not exists (
      select 1 from public.actor_memberships
      where context_actor_id = v_ev.context_actor_id
        and member_actor_id = v_actor_id
        and membership_status = 'active'
    ) then
      continue;
    end if;
    insert into public.event_participants (event_id, participant_actor_id, status)
    values (p_event_id, v_actor_id, 'invited')
    on conflict do nothing;
    if found then
      v_added := v_added + 1;
    end if;
  end loop;

  return jsonb_build_object('added', v_added);
end;
$function$;

create or replace function public.remove_event_participants(
  p_event_id uuid,
  p_actor_ids uuid[]
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_ev public.calendar_events%rowtype;
  v_removed int;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ev from public.calendar_events where id = p_event_id;
  if v_ev.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if v_ev.status in ('completed','cancelled') then
    raise exception 'cannot edit participants of a terminal event' using errcode = '22023';
  end if;
  if v_ev.host_actor_id <> v_caller
     and not public.has_actor_authority(v_ev.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized (host o events.manage)' using errcode = '42501';
  end if;

  update public.event_participants
  set status = 'cancelled',
      cancelled_at = now()
  where event_id = p_event_id
    and participant_actor_id = any(p_actor_ids)
    and status not in ('cancelled');

  get diagnostics v_removed = row_count;
  return jsonb_build_object('removed', v_removed);
end;
$function$;

create or replace function public.set_event_participant_plus_one(
  p_event_id uuid,
  p_actor_id uuid,
  p_plus_one boolean
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_ev public.calendar_events%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ev from public.calendar_events where id = p_event_id;
  if v_ev.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if v_ev.status in ('completed','cancelled') then
    raise exception 'cannot edit a terminal event' using errcode = '22023';
  end if;
  if p_actor_id <> v_caller
     and v_ev.host_actor_id <> v_caller
     and not public.has_actor_authority(v_ev.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized (solo el participant, host o admin)' using errcode = '42501';
  end if;

  update public.event_participants
  set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('plus_one', p_plus_one)
  where event_id = p_event_id
    and participant_actor_id = p_actor_id;

  if not found then
    raise exception 'participant not found in event' using errcode = 'P0002';
  end if;

  return jsonb_build_object('plus_one', p_plus_one);
end;
$function$;

grant execute on function public.add_event_participants(uuid, uuid[]) to authenticated;
grant execute on function public.remove_event_participants(uuid, uuid[]) to authenticated;
grant execute on function public.set_event_participant_plus_one(uuid, uuid, boolean) to authenticated;
