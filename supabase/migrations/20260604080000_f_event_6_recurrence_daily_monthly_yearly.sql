-- F.EVENT.6 — extend close_event recurrence beyond weekly.
-- Founder doctrine 2026-06-04: "yo debería de poder definir la recurrencia".
--
-- Reglas:
-- - weekly  → +7 días, host rota al siguiente miembro activo (preserva R4 behavior)
-- - daily   → +1 día,  host se mantiene
-- - monthly → +1 mes,  host se mantiene
-- - yearly  → +1 año,  host se mantiene
-- - Acepta tanto "daily"/"weekly"/... como "freq=daily"/"freq=weekly"/... (case-insensitive).

create or replace function public.close_event(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth'
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_event public.calendar_events%rowtype;
  v_next_id uuid;
  v_next_start timestamptz;
  v_next_host uuid;
  v_no_shows integer;
  v_rule text;
  v_interval interval;
  v_rotate_host boolean;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_event from public.calendar_events where id = p_event_id for update;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized to close event' using errcode = '42501';
  end if;
  if v_event.status = 'completed' then
    return jsonb_build_object('event_id', p_event_id, 'status', 'completed', 'already_closed', true);
  end if;

  -- no-shows: los que dijeron going/invited y nunca hicieron check-in
  update public.event_participants
     set status = 'no_show'
   where event_id = p_event_id and status in ('going', 'invited', 'maybe') and checked_in_at is null;
  get diagnostics v_no_shows = row_count;

  update public.calendar_events set status = 'completed' where id = p_event_id;

  -- F.EVENT.6: recurrence handling for all supported frequencies.
  if v_event.recurrence_rule is not null then
    v_rule := lower(btrim(v_event.recurrence_rule));
    v_interval := case
      when v_rule in ('daily',   'freq=daily')   then interval '1 day'
      when v_rule in ('weekly',  'freq=weekly')  then interval '7 days'
      when v_rule in ('monthly', 'freq=monthly') then interval '1 month'
      when v_rule in ('yearly',  'freq=yearly')  then interval '1 year'
      else null
    end;
    v_rotate_host := v_rule in ('weekly', 'freq=weekly');

    if v_interval is not null then
      v_next_start := v_event.starts_at + v_interval;

      if v_rotate_host then
        select am.member_actor_id into v_next_host
          from public.actor_memberships am
         where am.context_actor_id = v_event.context_actor_id and am.membership_status = 'active'
         order by (am.member_actor_id = v_event.host_actor_id) desc, am.joined_at, am.member_actor_id
         offset 1 limit 1;
        v_next_host := coalesce(v_next_host, v_event.host_actor_id);
      else
        v_next_host := v_event.host_actor_id;
      end if;

      insert into public.calendar_events
        (context_actor_id, title, description, event_type, starts_at, ends_at, timezone,
         location_text, recurrence_rule, host_actor_id, metadata, created_by_actor_id, is_virtual)
      values
        (v_event.context_actor_id, v_event.title, v_event.description, v_event.event_type,
         v_next_start, v_next_start + coalesce(v_event.ends_at - v_event.starts_at, interval '2 hours'),
         v_event.timezone, v_event.location_text, v_event.recurrence_rule, v_next_host,
         v_event.metadata || jsonb_build_object('previous_event_id', p_event_id), v_event.created_by_actor_id,
         v_event.is_virtual)
      returning id into v_next_id;

      insert into public.event_participants (event_id, participant_actor_id, status)
      select v_next_id, am.member_actor_id, 'invited'
        from public.actor_memberships am
       where am.context_actor_id = v_event.context_actor_id and am.membership_status = 'active'
      on conflict do nothing;
    end if;
  end if;

  perform public._emit_activity(v_event.context_actor_id, v_caller, 'event.closed', 'calendar_event', p_event_id,
    jsonb_build_object('no_shows', v_no_shows, 'next_event_id', v_next_id, 'next_host_actor_id', v_next_host));

  return jsonb_build_object(
    'event_id', p_event_id, 'status', 'completed', 'no_shows', v_no_shows,
    'next_event_id', v_next_id, 'next_host_actor_id', v_next_host);
end; $function$;

-- GRANTs (memory pattern: REVOKE FROM anon + GRANT EXECUTE TO authenticated, service_role).
revoke all on function public.close_event(uuid) from public, anon;
grant execute on function public.close_event(uuid) to authenticated, service_role;
