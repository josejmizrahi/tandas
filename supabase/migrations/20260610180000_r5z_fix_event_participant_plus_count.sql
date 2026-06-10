-- R.5Z.fix.EVENT.PLUS_N (2026-06-10) — founder pidió +N en lugar de +1.
-- Reemplaza plus_one bool por plus_count int (0..N).
-- Backfill: plus_one=true → plus_count=1, plus_one=false → plus_count=0.

create or replace function public.set_event_participant_plus_count(
  p_event_id uuid,
  p_actor_id uuid,
  p_count int
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
  if p_count is null or p_count < 0 or p_count > 20 then
    raise exception 'plus_count must be between 0 and 20' using errcode = '22023';
  end if;
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
  set metadata = coalesce(metadata, '{}'::jsonb)
                 - 'plus_one'
                 || jsonb_build_object('plus_count', p_count)
  where event_id = p_event_id
    and participant_actor_id = p_actor_id;

  if not found then
    raise exception 'participant not found in event' using errcode = 'P0002';
  end if;

  return jsonb_build_object('plus_count', p_count);
end;
$function$;

grant execute on function public.set_event_participant_plus_count(uuid, uuid, int) to authenticated;

update public.event_participants
set metadata = (metadata - 'plus_one')
               || jsonb_build_object(
                    'plus_count',
                    case when (metadata->>'plus_one')::boolean then 1 else 0 end
                  )
where metadata ? 'plus_one';
