-- ────────────────────────────────────────────────────────────────────────────
-- FE.9 — cancel_participation no puede pisar un check-in (bug encontrado en
-- el Palco Mundial 2026: 3 participantes con check-in quedaron 'cancelled' y
-- desaparecieron del split de gastos del evento Inauguración; backfill de
-- datos aplicado directo en prod con metadata.backfill + activity
-- custom.participant_status_backfill). Doctrina acto > estado: llegar al
-- evento es un acto registrado; la cancelación posterior se rechaza con
-- 22023 y mensaje claro.
-- ────────────────────────────────────────────────────────────────────────────

create or replace function public.cancel_participation(
  p_event_id uuid,
  p_participant_actor_id uuid default null,
  p_cancelled_at timestamptz default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_target uuid := coalesce(p_participant_actor_id, public.current_actor_id());
  v_event public.calendar_events%rowtype;
  v_existing public.event_participants%rowtype;
  v_is_manager boolean;
  v_effective_at timestamptz;
  v_tz text;
  v_pid uuid;
  v_same_day boolean;
  v_rules jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_event from public.calendar_events where id = p_event_id;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;

  v_is_manager := (v_event.host_actor_id is not null and v_event.host_actor_id = v_caller)
    or public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage');

  if (v_target <> v_caller or p_cancelled_at is not null) and not v_is_manager then
    raise exception 'not authorized to cancel for others or backdate' using errcode = '42501';
  end if;
  if v_target = v_caller
     and not public.is_context_member(v_event.context_actor_id)
     and not exists (select 1 from public.event_participants
                     where event_id = p_event_id and participant_actor_id = v_caller) then
    raise exception 'not a member of event context' using errcode = '42501';
  end if;

  select * into v_existing from public.event_participants
   where event_id = p_event_id and participant_actor_id = v_target;
  -- FE.9 (bug Palco Mundial): el check-in es un acto registrado — cancelar
  -- después de llegar pisaba attended/late a cancelled y sacaba al
  -- participante del split de gastos. Acto > estado: no se cancela lo vivido.
  if v_existing.id is not null and v_existing.checked_in_at is not null then
    raise exception 'cannot cancel participation after check-in'
      using errcode = '22023',
      hint = 'el participante ya hizo check-in; su asistencia es un hecho registrado';
  end if;
  if v_existing.id is not null and v_existing.status = 'cancelled' then
    return jsonb_build_object(
      'participant_id', v_existing.id,
      'status', 'cancelled',
      'cancelled_at', v_existing.cancelled_at,
      'already_cancelled', true);
  end if;

  v_effective_at := coalesce(p_cancelled_at, now());

  -- R.2D-2: "mismo día" se evalúa en el timezone del evento, no en UTC
  v_tz := coalesce(v_event.timezone, 'UTC');
  v_same_day := v_event.starts_at is not null
    and (v_event.starts_at at time zone v_tz)::date = (v_effective_at at time zone v_tz)::date;

  insert into public.event_participants (event_id, participant_actor_id, status, cancelled_at)
  values (p_event_id, v_target, 'cancelled', v_effective_at)
  on conflict (event_id, participant_actor_id)
  do update set status = 'cancelled', cancelled_at = excluded.cancelled_at
  returning id into v_pid;

  update public.event_participants
     set metadata = metadata || jsonb_build_object('same_day_cancellation', v_same_day)
   where id = v_pid;

  perform public._emit_activity(v_event.context_actor_id, v_target, 'event.participation_cancelled', 'event_participant', v_pid,
    jsonb_build_object('event_id', p_event_id, 'same_day', v_same_day));

  -- R.2E: payload con event_type + same_day_cancellation (nombre de campo del spec);
  -- same_day se mantiene por compat con reglas anteriores
  v_rules := public.evaluate_rules_for_event(
    v_event.context_actor_id, 'event.participation_cancelled', v_target,
    jsonb_build_object('same_day', v_same_day, 'same_day_cancellation', v_same_day,
                       'event_type', v_event.event_type),
    p_event_id);

  return jsonb_build_object('participant_id', v_pid, 'status', 'cancelled',
    'cancelled_at', v_effective_at,
    'same_day_cancellation', v_same_day, 'rules', v_rules);
end; $$;

-- Smoke
create or replace function public._smoke_mvp2_cancel_after_checkin()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_a uuid;
  v_ctx uuid;
  v_event uuid;
  v_result jsonb;
  v_caught boolean := false;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke CkCancel A', '+520000000960', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_context('_smoke_ckcancel Palco', 'collective', 'friend_group');
  v_ctx := (v_result->>'context_actor_id')::uuid;
  v_result := public.create_calendar_event(v_ctx, '_smoke_ckcancel Partido', 'meeting', now() - interval '1 hour');
  v_event := (v_result->>'event_id')::uuid;

  perform public.rsvp_event(v_event, 'going');
  perform public.check_in_participant(v_event);

  begin
    perform public.cancel_participation(v_event);
  exception when sqlstate '22023' then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'ckcancel smoke: permitió cancelar después del check-in';
  end if;
  if not exists (
    select 1 from public.event_participants
    where event_id = v_event and participant_actor_id = v_a
      and status in ('attended', 'late') and checked_in_at is not null
  ) then
    raise exception 'ckcancel smoke: el status post check-in no sobrevivió';
  end if;

  -- Cleanup (activity append-only — residuo aceptado).
  perform set_config('request.jwt.claims', null, true);
  delete from public.event_participants where event_id = v_event;
  delete from public.calendar_events where id = v_event;
  delete from public.context_invites where context_actor_id = v_ctx;
  delete from public.role_assignments where context_actor_id = v_ctx;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = v_ctx;
  delete from public.roles where context_actor_id = v_ctx;
  delete from public.actor_memberships where context_actor_id = v_ctx;
  delete from public.actor_relationships
    where subject_actor_id in (v_a, v_ctx) or object_actor_id in (v_a, v_ctx);
  delete from public.actors where id = v_ctx;
  delete from public.person_profiles where actor_id = v_a;
  delete from public.actors where id = v_a;
  delete from auth.users where id = v_auth_a;

  raise notice '_smoke_mvp2_cancel_after_checkin passed';
end; $$;

revoke all on function public._smoke_mvp2_cancel_after_checkin() from public, anon, authenticated;
