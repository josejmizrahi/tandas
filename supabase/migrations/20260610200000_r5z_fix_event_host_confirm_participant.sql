-- R.5Z.fix.EVENT.HOST_CONFIRM (2026-06-10 founder smoke Campo Marte) —
-- Host o events.manage puede marcar a un participant como "going" en su
-- nombre. Caso real: founder compró boletos por adelantado, los marca
-- como confirmados y el split aplica aunque el participant todavía no
-- haya respondido. Se emite attention al participant para que confirme o
-- cambie respuesta.

create or replace function public.host_confirm_participant(
  p_event_id uuid,
  p_actor_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_ev public.calendar_events%rowtype;
  v_caller_name text;
  v_event_title text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ev from public.calendar_events where id = p_event_id;
  if v_ev.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if v_ev.status in ('completed','cancelled') then
    raise exception 'cannot confirm participants of a terminal event' using errcode = '22023';
  end if;
  if v_ev.host_actor_id <> v_caller
     and not public.has_actor_authority(v_ev.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized (solo host o events.manage)' using errcode = '42501';
  end if;

  update public.event_participants
  set status = 'going',
      rsvp_at = coalesce(rsvp_at, now()),
      metadata = coalesce(metadata, '{}'::jsonb)
                 || jsonb_build_object(
                      'host_confirmed', true,
                      'host_confirmed_by', v_caller,
                      'host_confirmed_at', now()
                    )
  where event_id = p_event_id and participant_actor_id = p_actor_id;

  if not found then
    raise exception 'participant not in event' using errcode = 'P0002';
  end if;

  select display_name into v_caller_name from public.actors where id = v_caller;
  v_event_title := v_ev.title;

  insert into public.rule_attention_items
    (context_actor_id, subject_actor_id,
     kind, title, reason, priority,
     cta_action_key, cta_scope_kind, cta_scope_id,
     source_rule_id, source_event_id, idempotency_key, metadata)
  values
    (v_ev.context_actor_id, p_actor_id,
     'event_confirmation_by_host',
     format('%s te confirmó al evento %s', coalesce(v_caller_name, 'Alguien'), v_event_title),
     'Si no vas, cambia tu respuesta para no entrar en el split del gasto.',
     'normal',
     'rsvp_event',
     'event',
     p_event_id,
     null,
     null,
     'host_confirm:' || p_event_id::text || ':' || p_actor_id::text || ':' || extract(epoch from now())::text,
     jsonb_build_object('host_confirmed_by', v_caller, 'event_title', v_event_title))
  on conflict (idempotency_key) do nothing;

  return jsonb_build_object(
    'changed', true,
    'event_id', p_event_id,
    'actor_id', p_actor_id,
    'status', 'going'
  );
end;
$function$;

grant execute on function public.host_confirm_participant(uuid, uuid) to authenticated;
