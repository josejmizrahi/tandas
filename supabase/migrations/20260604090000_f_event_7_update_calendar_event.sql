-- F.EVENT.7 — update_calendar_event RPC + edit_event action emission.
-- Founder doctrine 2026-06-04: "editar Event (title/start/end/location/virtual/recurrence)".
--
-- Reglas:
-- - Permiso: host del evento OR events.manage.
-- - Sólo eventos no terminales (scheduled/in_progress).
-- - NULL en cualquier parámetro = "no cambiar" (COALESCE).
-- - Re-valida F.EVENT.5 location_required en el estado final.
-- - Emite activity event.updated con diff_keys.
-- - event_available_actions añade edit_event (host o events.manage, no terminal).

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. update_calendar_event(...)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.update_calendar_event(
  p_event_id uuid,
  p_title text default null,
  p_description text default null,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,
  p_location_text text default null,
  p_is_virtual boolean default null,
  p_recurrence_rule text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_event public.calendar_events%rowtype;
  v_is_host boolean;
  v_can_manage boolean;
  v_new_title text;
  v_new_description text;
  v_new_starts_at timestamptz;
  v_new_ends_at timestamptz;
  v_new_location text;
  v_new_is_virtual boolean;
  v_new_recurrence text;
  v_diff_keys text[] := array[]::text[];
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_event from public.calendar_events where id = p_event_id for update;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;

  v_is_host    := v_event.host_actor_id = v_caller;
  v_can_manage := public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage');
  if not (v_is_host or v_can_manage) then
    raise exception 'not authorized to edit event' using errcode = '42501';
  end if;

  if v_event.status not in ('scheduled', 'in_progress') then
    raise exception 'cannot edit event in terminal status %', v_event.status using errcode = '22023';
  end if;

  -- Compute new state. NULL en input = "no cambiar".
  v_new_title       := coalesce(nullif(btrim(p_title), ''), v_event.title);
  v_new_description := coalesce(p_description, v_event.description);
  v_new_starts_at   := coalesce(p_starts_at, v_event.starts_at);
  v_new_ends_at     := coalesce(p_ends_at, v_event.ends_at);
  v_new_location    := coalesce(nullif(btrim(p_location_text), ''), v_event.location_text);
  v_new_is_virtual  := coalesce(p_is_virtual, v_event.is_virtual);
  v_new_recurrence  := coalesce(nullif(btrim(p_recurrence_rule), ''), v_event.recurrence_rule);

  -- F.EVENT.5 — location required unless virtual (revalidación en estado final).
  if not v_new_is_virtual and (v_new_location is null or length(btrim(v_new_location)) = 0) then
    raise exception 'location_required: events must have a location unless marked as virtual'
      using errcode = '22023';
  end if;

  -- ends_at, si llega, no puede ser anterior a starts_at.
  if v_new_ends_at is not null and v_new_ends_at < v_new_starts_at then
    raise exception 'ends_at must be on or after starts_at' using errcode = '22023';
  end if;

  -- Diff keys (para activity payload).
  if v_new_title       is distinct from v_event.title           then v_diff_keys := array_append(v_diff_keys, 'title'); end if;
  if v_new_description is distinct from v_event.description     then v_diff_keys := array_append(v_diff_keys, 'description'); end if;
  if v_new_starts_at   is distinct from v_event.starts_at       then v_diff_keys := array_append(v_diff_keys, 'starts_at'); end if;
  if v_new_ends_at     is distinct from v_event.ends_at         then v_diff_keys := array_append(v_diff_keys, 'ends_at'); end if;
  if v_new_location    is distinct from v_event.location_text   then v_diff_keys := array_append(v_diff_keys, 'location_text'); end if;
  if v_new_is_virtual  is distinct from v_event.is_virtual      then v_diff_keys := array_append(v_diff_keys, 'is_virtual'); end if;
  if v_new_recurrence  is distinct from v_event.recurrence_rule then v_diff_keys := array_append(v_diff_keys, 'recurrence_rule'); end if;

  if array_length(v_diff_keys, 1) is null then
    -- No-op: nada cambió.
    return jsonb_build_object(
      'event_id', p_event_id,
      'event', to_jsonb(v_event),
      'diff_keys', '[]'::jsonb,
      'no_op', true
    );
  end if;

  update public.calendar_events
     set title           = v_new_title,
         description     = v_new_description,
         starts_at       = v_new_starts_at,
         ends_at         = v_new_ends_at,
         location_text   = v_new_location,
         is_virtual      = v_new_is_virtual,
         recurrence_rule = v_new_recurrence
   where id = p_event_id;

  perform public._emit_activity(
    v_event.context_actor_id, v_caller,
    'event.updated', 'calendar_event', p_event_id,
    jsonb_build_object('diff_keys', to_jsonb(v_diff_keys))
  );

  return jsonb_build_object(
    'event_id', p_event_id,
    'event', (select to_jsonb(e) from public.calendar_events e where e.id = p_event_id),
    'diff_keys', to_jsonb(v_diff_keys),
    'no_op', false
  );
end; $$;

revoke all on function public.update_calendar_event(
  uuid, text, text, timestamptz, timestamptz, text, boolean, text
) from public, anon;
grant execute on function public.update_calendar_event(
  uuid, text, text, timestamptz, timestamptz, text, boolean, text
) to authenticated, service_role;

comment on function public.update_calendar_event(
  uuid, text, text, timestamptz, timestamptz, text, boolean, text
) is
  'F.EVENT.7: edit event canónico. Host o events.manage. Sólo no-terminales. Revalida F.EVENT.5 location.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. event_available_actions — añadir edit_event
-- ─────────────────────────────────────────────────────────────────────────────
-- Se reescribe la firma 2-arg conservando el resto del comportamiento F.2X.0.
create or replace function public.event_available_actions(p_event_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_e public.calendar_events%rowtype;
  v_participant public.event_participants%rowtype;
  v_is_host boolean;
  v_can_manage_events boolean;
  v_can_record_money boolean;
  v_can_create_decision boolean;
  v_is_active boolean;
  v_is_terminal boolean;
  v_actions jsonb := '[]'::jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_e from public.calendar_events where id = p_event_id;
  if v_e.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if not public.is_context_member(v_e.context_actor_id) then
    raise exception 'not a member of event context' using errcode = '42501';
  end if;

  v_is_active   := v_e.status in ('scheduled', 'in_progress');
  v_is_terminal := v_e.status in ('completed', 'cancelled');
  v_is_host     := v_e.host_actor_id = p_actor_id;
  v_can_manage_events   := public.has_actor_authority(v_e.context_actor_id, p_actor_id, 'events.manage');
  v_can_record_money    := public.has_actor_authority(v_e.context_actor_id, p_actor_id, 'money.record');
  v_can_create_decision := public.has_actor_authority(v_e.context_actor_id, p_actor_id, 'decisions.create');

  select * into v_participant from public.event_participants
   where event_id = p_event_id and participant_actor_id = p_actor_id;

  -- rsvp_event
  if v_is_active and (v_participant.id is null or v_participant.status in ('invited', 'going', 'maybe', 'declined')) then
    v_actions := v_actions || public._aa('rsvp_event', 'Responder asistencia', 'participation',
      true,
      case when v_participant.id is null then 'Puedes responder asistencia'
           else 'Puedes cambiar tu respuesta' end);
  end if;

  -- check_in_participant
  if v_is_active and v_participant.id is not null
     and v_participant.checked_in_at is null
     and v_participant.status not in ('cancelled', 'declined') then
    v_actions := v_actions || public._aa('check_in_participant', 'Marcar mi llegada', 'participation',
      true, 'Puedes registrar tu propia llegada al evento');
  end if;

  -- cancel_participation
  if v_is_active and v_participant.id is not null
     and v_participant.status in ('invited', 'going', 'maybe') then
    v_actions := v_actions || public._aa('cancel_participation', 'Cancelar mi asistencia', 'participation',
      true, 'Puedes cancelar tu participación');
  end if;

  -- close_event
  if v_is_active then
    v_actions := v_actions || public._aa('close_event', 'Cerrar evento', 'participation',
      v_is_host or v_can_manage_events,
      case when v_is_host then 'Eres el anfitrión del evento'
           when v_can_manage_events then 'Tienes permiso para administrar eventos'
           else 'Solo el anfitrión o un administrador pueden cerrar el evento' end);
  end if;

  -- F.EVENT.7 — edit_event: host o events.manage, sólo en no-terminales.
  if v_is_active then
    v_actions := v_actions || public._aa('edit_event', 'Editar evento', 'participation',
      v_is_host or v_can_manage_events,
      case when v_is_host then 'Eres el anfitrión del evento'
           when v_can_manage_events then 'Tienes permiso para administrar eventos'
           else 'Solo el anfitrión o un administrador pueden editar el evento' end);
  end if;

  -- record_expense
  if v_e.status <> 'cancelled' then
    v_actions := v_actions || public._aa('record_expense', 'Registrar gasto', 'money',
      v_can_record_money,
      case when v_can_record_money then 'Puedes registrar un gasto asociado al evento'
           else 'Requiere permiso money.record' end);
  end if;

  -- create_decision
  if not v_is_terminal then
    v_actions := v_actions || public._aa('create_decision', 'Abrir decisión', 'decisions',
      v_can_create_decision,
      case when v_can_create_decision then 'Puedes abrir una decisión vinculada al evento'
           else 'Requiere permiso decisions.create' end);
  end if;

  -- attach_document
  v_actions := v_actions || public._aa('attach_document', 'Adjuntar documento', 'documents',
    true, 'Puedes adjuntar un documento al evento');

  return v_actions;
end; $$;

revoke all on function public.event_available_actions(uuid, uuid) from public, anon;
grant execute on function public.event_available_actions(uuid, uuid) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Smoke F.EVENT.7
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_f_event_7_update_calendar_event()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  v_ctx uuid;
  v_event uuid;
  v_result jsonb;
  v_aa jsonb;
  v_starts timestamptz := now() + interval '2 days';
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José F.EVENT.7', '+5210000180');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David F.EVENT.7', '+5210000181');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Cena F.EVENT.7', 'collective', 'friend_group'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_event := (public.create_calendar_event(
    v_ctx::uuid, 'Cena viernes', 'dinner', v_starts, v_starts + interval '3 hours',
    null, null, 'Casa Mizrahi'))->>'event_id';

  -- ═══ 1. Host edita título + descripción ═══
  v_result := public.update_calendar_event(v_event::uuid, 'Cena viernes (corregido)', 'BYOB');
  if (v_result->>'no_op')::boolean then
    raise exception 'F.EVENT.7 FAIL 1: no_op cuando había cambios';
  end if;
  if not (v_result->'diff_keys' @> '"title"'::jsonb) then
    raise exception 'F.EVENT.7 FAIL 1: diff_keys no contiene title';
  end if;
  if (v_result->'event'->>'title') <> 'Cena viernes (corregido)' then
    raise exception 'F.EVENT.7 FAIL 1: título no actualizó';
  end if;

  -- ═══ 2. Llamada sin cambios → no_op = true ═══
  v_result := public.update_calendar_event(v_event::uuid);
  if not (v_result->>'no_op')::boolean then
    raise exception 'F.EVENT.7 FAIL 2: esperaba no_op=true';
  end if;

  -- ═══ 3. Cambiar ubicación a una nueva válida ═══
  v_result := public.update_calendar_event(v_event::uuid, null, null, null, null, 'Casa Cohen');
  if (v_result->'event'->>'location_text') <> 'Casa Cohen' then
    raise exception 'F.EVENT.7 FAIL 3: location_text no se actualizó';
  end if;

  -- ═══ 4. is_virtual=true mantiene location previa pero marca virtual ═══
  v_result := public.update_calendar_event(v_event::uuid, null, null, null, null, null, true);
  if (v_result->'event'->>'is_virtual')::boolean is not true then
    raise exception 'F.EVENT.7 FAIL 4: is_virtual no se actualizó';
  end if;

  -- ═══ 5. ends_at < starts_at → 22023 ═══
  begin
    perform public.update_calendar_event(v_event::uuid, null, null, v_starts, v_starts - interval '1 hour');
    raise exception 'F.EVENT.7 FAIL 5: aceptó ends_at < starts_at';
  exception
    when sqlstate '22023' then null;
  end;

  -- ═══ 6. David (no host, no admin) no puede editar ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  begin
    perform public.update_calendar_event(v_event::uuid, 'hackeado');
    raise exception 'F.EVENT.7 FAIL 6: david pudo editar sin permisos';
  exception
    when sqlstate '42501' then null;
  end;

  -- ═══ 7. event_available_actions expone edit_event al host ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_aa := public.event_available_actions(v_event::uuid, a_jose);
  if not exists (select 1 from jsonb_array_elements(v_aa) e
                 where e->>'action_key' = 'edit_event' and (e->>'enabled')::boolean) then
    raise exception 'F.EVENT.7 FAIL 7: host no tiene edit_event enabled';
  end if;

  -- ═══ 8. edit_event aparece para david pero disabled ═══
  v_aa := public.event_available_actions(v_event::uuid, a_david);
  if not exists (select 1 from jsonb_array_elements(v_aa) e
                 where e->>'action_key' = 'edit_event' and not (e->>'enabled')::boolean) then
    raise exception 'F.EVENT.7 FAIL 8: edit_event para david debería aparecer disabled (intent-first)';
  end if;

  -- ═══ 9. Tras cerrar el evento, edit_event desaparece ═══
  perform public.close_event(v_event::uuid);
  v_aa := public.event_available_actions(v_event::uuid, a_jose);
  if exists (select 1 from jsonb_array_elements(v_aa) e where e->>'action_key' = 'edit_event') then
    raise exception 'F.EVENT.7 FAIL 9: edit_event aparece en evento completed';
  end if;

  -- ═══ 10. Editar un evento completed → 22023 ═══
  begin
    perform public.update_calendar_event(v_event::uuid, 'tarde');
    raise exception 'F.EVENT.7 FAIL 10: aceptó editar evento completed';
  exception
    when sqlstate '22023' then null;
  end;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david], array[u_jose, u_david]);

  raise notice 'F.EVENT.7 update_calendar_event: PASS (10/10)';
end; $$;

revoke all on function public._smoke_f_event_7_update_calendar_event() from public, anon, authenticated;

create or replace function public._smoke_mvp2_f_event_7_update_calendar_event()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_f_event_7_update_calendar_event(); end; $$;
revoke all on function public._smoke_mvp2_f_event_7_update_calendar_event() from public, anon, authenticated;

comment on function public._smoke_mvp2_f_event_7_update_calendar_event() is
  'Wrapper CI del smoke F.EVENT.7 — update_calendar_event + edit_event action.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Verificación inline del DoD
-- ─────────────────────────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'update_calendar_event') then
    raise exception 'F.EVENT.7 DoD: falta update_calendar_event';
  end if;
  raise notice 'F.EVENT.7 DoD: update_calendar_event + edit_event action emission';
end $$;
