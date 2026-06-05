CREATE OR REPLACE FUNCTION public._smoke_f2x_0_intent_first_actions()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  v_ctx uuid;
  v_event uuid;
  v_summary jsonb;
  v_aa jsonb; v_a jsonb;
  v_detail jsonb;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José F2X', '+5210000170');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David F2X', '+5210000171');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Familia F2X', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_aa := public.context_available_actions(v_ctx::uuid, a_jose);
  if jsonb_typeof(v_aa) <> 'array' then
    raise exception 'F2X.0 FAIL 1: context_available_actions no devuelve array';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_aa) e where e->>'action_key' = 'create_resource') then
    raise exception 'F2X.0 FAIL 1: falta create_resource';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_aa) e where e->>'action_key' = 'create_event') then
    raise exception 'F2X.0 FAIL 1: falta create_event';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_aa) e where e->>'action_key' = 'invite_member') then
    raise exception 'F2X.0 FAIL 1: falta invite_member';
  end if;

  v_a := (select e from jsonb_array_elements(v_aa) e where e->>'action_key' = 'create_resource' limit 1);
  if not (v_a ? 'action_key' and v_a ? 'label' and v_a ? 'section'
          and v_a ? 'enabled' and v_a ? 'reason'
          and v_a ? 'required_rights' and v_a ? 'required_capabilities') then
    raise exception 'F2X.0 FAIL 2: action object sin la forma canónica de 7 campos';
  end if;

  if not ((v_a->>'enabled')::boolean) then
    raise exception 'F2X.0 FAIL 3: founder no tiene enabled=true en create_resource';
  end if;
  v_a := (select e from jsonb_array_elements(public.context_available_actions(v_ctx::uuid, a_david)) e
          where e->>'action_key' = 'create_resource' limit 1);
  if v_a is null then
    raise exception 'F2X.0 FAIL 3: la acción create_resource desaparece para david';
  end if;

  v_summary := public.context_summary(v_ctx::uuid);
  if jsonb_typeof(v_summary->'my_permissions') <> 'array' then
    raise exception 'F2X.0 FAIL 4: context_summary perdió my_permissions[]';
  end if;
  if jsonb_typeof(v_summary->'available_actions') <> 'array' then
    raise exception 'F2X.0 FAIL 4: context_summary no embebe available_actions[]';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_summary->'available_actions') e
                 where e->>'action_key' = 'create_resource') then
    raise exception 'F2X.0 FAIL 4: available_actions[] embebido no contiene create_resource';
  end if;

  v_event := (public.create_calendar_event(v_ctx::uuid, 'Cena viernes', 'dinner',
              now() + interval '2 days', now() + interval '2 days 3 hours', null, null, null))->>'event_id';

  v_aa := public.event_available_actions(v_event::uuid, a_jose);
  if not exists (select 1 from jsonb_array_elements(v_aa) e where e->>'action_key' = 'close_event') then
    raise exception 'F2X.0 FAIL 5: evento scheduled no expone close_event';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_aa) e where e->>'action_key' = 'record_expense') then
    raise exception 'F2X.0 FAIL 5: evento no expone record_expense';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_aa) e where e->>'action_key' = 'attach_document') then
    raise exception 'F2X.0 FAIL 5: evento no expone attach_document';
  end if;

  v_detail := public.event_detail(v_event::uuid);
  if v_detail->'event' is null then raise exception 'F2X.0 FAIL 6: event_detail falta event'; end if;
  if jsonb_typeof(v_detail->'participants') <> 'array' then
    raise exception 'F2X.0 FAIL 6: event_detail falta participants[]';
  end if;
  if jsonb_typeof(v_detail->'available_actions') <> 'array' then
    raise exception 'F2X.0 FAIL 6: event_detail falta available_actions[]';
  end if;
  if jsonb_typeof(v_detail->'why_visible') <> 'array' then
    raise exception 'F2X.0 FAIL 6: event_detail falta why_visible[]';
  end if;
  if jsonb_typeof(v_detail->'capabilities') <> 'array' then
    raise exception 'F2X.0 FAIL 6: event_detail falta capabilities[]';
  end if;

  if public.context_available_actions(v_ctx::uuid) is distinct from
     public.context_available_actions(v_ctx::uuid, a_jose) then
    raise exception 'F2X.0 FAIL 7: context_available_actions 1-arg no delega';
  end if;
  if public.event_available_actions(v_event::uuid) is distinct from
     public.event_available_actions(v_event::uuid, a_jose) then
    raise exception 'F2X.0 FAIL 7: event_available_actions 1-arg no delega';
  end if;

  declare
    v_personal uuid;
  begin
    v_personal := a_jose;
    if exists (select 1 from jsonb_array_elements(public.context_available_actions(v_personal, a_jose)) e
               where e->>'action_key' = 'create_child_context') then
      raise exception 'F2X.0 FAIL 8: contexto personal expone create_child_context';
    end if;
  end;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david], array[u_jose, u_david]);

  raise notice 'F.2X.0 INTENT-FIRST AVAILABLE ACTIONS: PASS';
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_f_event_7_update_calendar_event()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
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

  v_result := public.update_calendar_event(v_event::uuid);
  if not (v_result->>'no_op')::boolean then
    raise exception 'F.EVENT.7 FAIL 2: esperaba no_op=true';
  end if;

  v_result := public.update_calendar_event(v_event::uuid, null, null, null, null, 'Casa Cohen');
  if (v_result->'event'->>'location_text') <> 'Casa Cohen' then
    raise exception 'F.EVENT.7 FAIL 3: location_text no se actualizó';
  end if;

  v_result := public.update_calendar_event(v_event::uuid, null, null, null, null, null, true);
  if (v_result->'event'->>'is_virtual')::boolean is not true then
    raise exception 'F.EVENT.7 FAIL 4: is_virtual no se actualizó';
  end if;

  begin
    perform public.update_calendar_event(v_event::uuid, null, null, v_starts, v_starts - interval '1 hour');
    raise exception 'F.EVENT.7 FAIL 5: aceptó ends_at < starts_at';
  exception
    when sqlstate '22023' then null;
  end;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  begin
    perform public.update_calendar_event(v_event::uuid, 'hackeado');
    raise exception 'F.EVENT.7 FAIL 6: david pudo editar sin permisos';
  exception
    when sqlstate '42501' then null;
  end;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_aa := public.event_available_actions(v_event::uuid, a_jose);
  if not exists (select 1 from jsonb_array_elements(v_aa) e
                 where e->>'action_key' = 'edit_event' and (e->>'enabled')::boolean) then
    raise exception 'F.EVENT.7 FAIL 7: host no tiene edit_event enabled';
  end if;

  v_aa := public.event_available_actions(v_event::uuid, a_david);
  if not exists (select 1 from jsonb_array_elements(v_aa) e
                 where e->>'action_key' = 'edit_event' and not (e->>'enabled')::boolean) then
    raise exception 'F.EVENT.7 FAIL 8: edit_event para david debería aparecer disabled (intent-first)';
  end if;

  perform public.close_event(v_event::uuid);
  v_aa := public.event_available_actions(v_event::uuid, a_jose);
  if exists (select 1 from jsonb_array_elements(v_aa) e where e->>'action_key' = 'edit_event') then
    raise exception 'F.EVENT.7 FAIL 9: edit_event aparece en evento completed';
  end if;

  begin
    perform public.update_calendar_event(v_event::uuid, 'tarde');
    raise exception 'F.EVENT.7 FAIL 10: aceptó editar evento completed';
  exception
    when sqlstate '22023' then null;
  end;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david], array[u_jose, u_david]);

  raise notice 'F.EVENT.7 update_calendar_event: PASS (10/10)';
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_mvp2_contract()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_linda uuid := gen_random_uuid();
  v_jose uuid; v_linda uuid; v_ctx uuid;
  v_result jsonb; v_code text; v_event uuid; v_next uuid;
  v_batch uuid; v_summary jsonb;
  v_total_closed integer := 0;
  r record;
begin
  -- ═══ 1-2. Identity + contexto ═══
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'Jose Contract', '+520000000022', null);
  v_linda := public._create_person_actor_for_auth_user(v_auth_linda, 'Linda Contract', '+520000000023', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_ctx := (public.create_context('_contract Cena de los Jueves', 'collective', 'friend_group'))->>'context_actor_id';

  -- ═══ 3. Linda se une ═══
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- ═══ 4. Regla de multa ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  perform public.create_rule(v_ctx::uuid, '_contract Multa por tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": ">", "field": "minutes_late", "value": 15}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);

  -- ═══ 5. Cena recurrente ═══
  v_event := (public.create_calendar_event(v_ctx::uuid, '_contract Cena Jueves', 'dinner',
    p_location_text := 'Por definir', p_starts_at := now() - interval '30 minutes',
    p_recurrence_rule := 'weekly', p_host_actor_id := v_jose))->>'event_id';

  -- ═══ 6. Linda check-in tarde → multa ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  v_result := public.check_in_participant(v_event::uuid);
  if (v_result->'rules'->>'rules_matched')::integer < 1 then
    raise exception 'contract: multa automática por tarde no se generó';
  end if;

  -- ═══ 7. Gasto con split ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_result := public.record_expense(v_ctx::uuid, 600, 'MXN', '_contract Cena sushi', p_event_id := v_event::uuid);
  if (v_result->>'share_per_person')::numeric <> 300 then
    raise exception 'contract: split de gasto incorrecto';
  end if;

  -- ═══ 8. Cierre + recurrencia + host rotation ═══
  v_result := public.close_event(v_event::uuid);
  v_next := (v_result->>'next_event_id')::uuid;
  if v_next is null or (v_result->>'next_host_actor_id')::uuid is distinct from v_linda then
    raise exception 'contract: recurrencia/rotación de host falló';
  end if;

  -- ═══ 9. Settlement ═══
  v_result := public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  if v_batch is null then raise exception 'contract: settlement batch no generado'; end if;
  if (select sum((i->>'amount')::numeric) from jsonb_array_elements(v_result->'items') i
      where (i->>'from')::uuid = v_linda) <> 400 then
    raise exception 'contract: neteo de Linda incorrecto (esperaba 400)';
  end if;

  -- ═══ 10. Linda paga TODOS sus items (R.2-3: el batch cierra al completarse) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  for r in select id from public.settlement_items
            where settlement_batch_id = v_batch and from_actor_id = v_linda loop
    v_result := public.mark_settlement_paid(r.id);
    v_total_closed := v_total_closed + coalesce((v_result->>'obligations_closed')::integer, 0);
  end loop;
  if v_total_closed < 2 then
    raise exception 'contract: obligations no cerradas al finalizar batch (cerradas: %)', v_total_closed;
  end if;
  if exists (select 1 from public.obligations where context_actor_id = v_ctx::uuid and status = 'open') then
    raise exception 'contract: quedaron obligations abiertas';
  end if;

  -- ═══ 11. context_summary refleja todo ═══
  v_summary := public.context_summary(v_ctx::uuid);
  if jsonb_array_length(v_summary->'members') <> 2 then
    raise exception 'contract: summary.members incorrecto';
  end if;
  if jsonb_array_length(v_summary->'upcoming_events') < 1 then
    raise exception 'contract: summary.upcoming_events no muestra la siguiente cena';
  end if;
  if jsonb_array_length(v_summary->'active_rules') <> 1 then
    raise exception 'contract: summary.active_rules incorrecto';
  end if;
  if (v_summary->>'open_obligations')::integer <> 0 then
    raise exception 'contract: summary.open_obligations debió ser 0';
  end if;

  -- ═══ 12. context_candidates ═══
  v_result := public.context_candidates();
  if not exists (select 1 from jsonb_array_elements(v_result->'contexts') c
                 where (c->>'context_actor_id')::uuid = v_ctx::uuid) then
    raise exception 'contract: context_candidates no muestra el contexto';
  end if;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[v_jose, v_linda], array[v_auth_jose, v_auth_linda]);

  raise notice '_smoke_mvp2_contract passed (cena semanal end-to-end con semántica de batch R.2-3)';
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_mvp2_m5_calendar()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_ctx uuid;
  v_result jsonb; v_event uuid; v_code text; v_next uuid;
  v_caught boolean;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M5A', '+520000000009', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M5B', '+520000000010', null);

  -- Setup: contexto con A (admin) y B (member)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_context('_smoke_m5 Cena', 'collective', 'friend_group');
  v_ctx := (v_result->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Caso 1: crear evento recurrente (cena semanal) → todos invitados
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_calendar_event(
    v_ctx, '_smoke_m5 Cena Jueves', 'dinner',
    p_location_text := 'Por definir', p_starts_at := now() - interval '30 minutes',  -- ya empezó (para probar late check-in)
    p_recurrence_rule := 'weekly',
    p_host_actor_id := v_a);
  v_event := (v_result->>'event_id')::uuid;
  if (v_result->>'participants')::integer < 2 then
    raise exception 'mvp2_m5 Caso1: no se invitó a todos los miembros';
  end if;

  -- Caso 2: B hace RSVP going
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.rsvp_event(v_event, 'going');
  if v_result->>'status' <> 'going' then raise exception 'mvp2_m5 Caso2: rsvp falló'; end if;

  -- Caso 3: B hace check-in tarde (evento empezó hace 30 min) → status late + minutes_late
  v_result := public.check_in_participant(v_event);
  if v_result->>'status' <> 'late' then
    raise exception 'mvp2_m5 Caso3: check-in tarde no marcó late (%)' , v_result->>'status';
  end if;
  if (v_result->>'minutes_late')::numeric < 15 then
    raise exception 'mvp2_m5 Caso3: minutes_late incorrecto';
  end if;

  -- Caso 4: no-member NO puede hacer RSVP
  perform set_config('request.jwt.claims', null, true);
  declare
    v_auth_c uuid := gen_random_uuid(); v_c uuid;
  begin
    v_c := public._create_person_actor_for_auth_user(v_auth_c, 'Smoke M5C', '+520000000011', null);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
    v_caught := false;
    begin
      perform public.rsvp_event(v_event, 'going');
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m5 Caso4: no-member pudo RSVP'; end if;
    perform set_config('request.jwt.claims', null, true);
    delete from public.person_profiles where actor_id = v_c;
    delete from public.actors where id = v_c;
    delete from auth.users where id = v_auth_c;
  end;

  -- Caso 5: close_event → no_show para A (nunca hizo check-in), siguiente instancia creada con host rotado
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.close_event(v_event);
  v_next := (v_result->>'next_event_id')::uuid;
  if v_next is null then raise exception 'mvp2_m5 Caso5: recurrencia no generó siguiente evento'; end if;
  if (v_result->>'no_shows')::integer < 1 then
    raise exception 'mvp2_m5 Caso5: no marcó no_shows';
  end if;
  -- host rotó a B (siguiente miembro activo)
  if (v_result->>'next_host_actor_id')::uuid is distinct from v_b then
    raise exception 'mvp2_m5 Caso5: host no rotó (esperaba B, fue %)', v_result->>'next_host_actor_id';
  end if;
  -- siguiente evento +7 días con todos invitados
  if not exists (
    select 1 from public.calendar_events e
    where e.id = v_next and e.starts_at > now() + interval '6 days'
  ) then
    raise exception 'mvp2_m5 Caso5: siguiente instancia mal fechada';
  end if;

  -- Caso 6: close idempotente
  v_result := public.close_event(v_event);
  if not (v_result->>'already_closed')::boolean then
    raise exception 'mvp2_m5 Caso6: close no es idempotente';
  end if;

  -- Caso 7: cancel_participation same-day
  -- R.2D-2: el evento empieza en now() → la cancelación (también now()) es
  -- same-day por construcción, en cualquier timezone y a cualquier hora UTC.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  declare
    v_today_event uuid;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    v_today_event := (public.create_calendar_event(v_ctx, '_smoke_m5 Hoy', 'dinner',
      p_location_text := 'Por definir', p_starts_at := now()))->>'event_id';
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
    v_result := public.cancel_participation(v_today_event::uuid);
    if not (v_result->>'same_day_cancellation')::boolean then
      raise exception 'mvp2_m5 Caso7: same-day cancellation no detectada';
    end if;
  end;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.event_participants where event_id in (select id from public.calendar_events where context_actor_id = v_ctx);
  delete from public.calendar_events where context_actor_id = v_ctx;
  delete from public.context_invites where context_actor_id = v_ctx;
  delete from public.role_assignments where context_actor_id = v_ctx;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx;
  delete from public.roles where context_actor_id = v_ctx;
  delete from public.actor_memberships where context_actor_id = v_ctx;
  delete from public.actors where id = v_ctx;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_m5_calendar passed (7 casos)';
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_mvp2_m8_rules()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_ctx uuid;
  v_result jsonb; v_event uuid; v_code text;
  v_fine numeric;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M8A', '+520000000017', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M8B', '+520000000018', null);

  -- Setup: contexto con regla "tarde > 15 min → multa $100" y "cancelar same-day → multa $300"
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_m8 Cena', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.create_rule(
    v_ctx::uuid, '_smoke_m8 Multa por tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": ">", "field": "minutes_late", "value": 15}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);
  perform public.create_rule(
    v_ctx::uuid, '_smoke_m8 Multa por cancelar same-day',
    p_trigger_event_type := 'event.participation_cancelled',
    p_condition_tree := '{"op": "=", "field": "same_day", "value": true}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 300, "currency": "MXN"}]'::jsonb);

  -- Caso 1: member NO puede crear reglas
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  declare v_caught boolean := false;
  begin
    begin
      perform public.create_rule(v_ctx::uuid, '_smoke_m8 hack', p_trigger_event_type := 'x');
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m8 Caso1: member creó regla sin autoridad'; end if;
  end;

  -- Caso 2: evento que ya empezó hace 30 min + check-in tarde → multa $100 automática
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_event := (public.create_calendar_event(v_ctx::uuid, '_smoke_m8 Cena', 'dinner',
    p_location_text := 'Por definir', p_starts_at := now() - interval '30 minutes'))->>'event_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.check_in_participant(v_event::uuid);
  if (v_result->'rules'->>'rules_matched')::integer < 1 then
    raise exception 'mvp2_m8 Caso2: regla de tarde no matcheó';
  end if;

  select amount into v_fine from public.obligations
   where debtor_actor_id = v_b and creditor_actor_id = v_ctx::uuid
     and obligation_type = 'fine' and source_event_id = v_event::uuid
     and source_rule_id is not null;
  if v_fine is distinct from 100 then
    raise exception 'mvp2_m8 Caso2: multa incorrecta (% en vez de 100)', v_fine;
  end if;

  -- Caso 3: check-in a tiempo NO genera multa
  declare
    v_event2 uuid; v_obligations_before integer; v_obligations_after integer;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    v_event2 := (public.create_calendar_event(v_ctx::uuid, '_smoke_m8 Cena 2', 'dinner',
      p_location_text := 'Por definir', p_starts_at := now() + interval '5 minutes'))->>'event_id';
    select count(*) into v_obligations_before from public.obligations where debtor_actor_id = v_a;
    v_result := public.check_in_participant(v_event2::uuid);
    select count(*) into v_obligations_after from public.obligations where debtor_actor_id = v_a;
    if v_obligations_after <> v_obligations_before then
      raise exception 'mvp2_m8 Caso3: multa generada sin llegar tarde';
    end if;
  end;

  -- Caso 4: cancelar same-day → multa $300
  -- R.2D-2: el evento empieza en now() → la cancelación es same-day por
  -- construcción, en cualquier timezone y a cualquier hora UTC.
  declare v_event3 uuid;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    v_event3 := (public.create_calendar_event(v_ctx::uuid, '_smoke_m8 Cena Hoy', 'dinner',
      p_location_text := 'Por definir', p_starts_at := now()))->>'event_id';
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
    v_result := public.cancel_participation(v_event3::uuid);
    if (v_result->'rules'->>'rules_matched')::integer < 1 then
      raise exception 'mvp2_m8 Caso4: regla de cancelación no matcheó';
    end if;
    if not exists (
      select 1 from public.obligations
      where debtor_actor_id = v_b and amount = 300 and source_event_id = v_event3::uuid
    ) then
      raise exception 'mvp2_m8 Caso4: multa de cancelación no creada';
    end if;
  end;

  -- Caso 5: rule_evaluations registradas (matched y not_matched)
  if not exists (select 1 from public.rule_evaluations where context_actor_id = v_ctx::uuid and outcome = 'matched') then
    raise exception 'mvp2_m8 Caso5: evaluaciones matched no registradas';
  end if;
  if not exists (select 1 from public.rule_evaluations where context_actor_id = v_ctx::uuid and outcome = 'not_matched') then
    raise exception 'mvp2_m8 Caso5: evaluaciones not_matched no registradas';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.rule_evaluations where context_actor_id = v_ctx::uuid;
  delete from public.obligations where context_actor_id = v_ctx::uuid;
  delete from public.rules where context_actor_id = v_ctx::uuid;
  delete from public.event_participants where event_id in (select id from public.calendar_events where context_actor_id = v_ctx::uuid);
  delete from public.calendar_events where context_actor_id = v_ctx::uuid;
  delete from public.context_invites where context_actor_id = v_ctx::uuid;
  delete from public.role_assignments where context_actor_id = v_ctx::uuid;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx::uuid;
  delete from public.roles where context_actor_id = v_ctx::uuid;
  delete from public.actor_memberships where context_actor_id = v_ctx::uuid;
  delete from public.actors where id = v_ctx::uuid;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_m8_rules passed (5 casos)';
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_r2_cena_semanal()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  a_jose uuid; a_david uuid; a_isaac uuid; a_moises uuid; a_daniel uuid;
  u_jose uuid; u_david uuid; u_isaac uuid; u_moises uuid; u_daniel uuid;
  v_ctx uuid; v_event uuid; v_result jsonb; v_batch uuid;
  r record;
begin
  -- Personas
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José', '+5210000001');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David', '+5210000002');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac', '+5210000003');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés', '+5210000004');
  select auth_id, actor_id into u_daniel, a_daniel from public._r2_make_person('Daniel', '+5210000005');

  -- ═══ R.2B: contexto + invitaciones directas + aceptación → members_count = 5 ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform public.invite_member(v_ctx::uuid, a_isaac);
  perform public.invite_member(v_ctx::uuid, a_moises);
  perform public.invite_member(v_ctx::uuid, a_daniel);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.context_summary(v_ctx::uuid);
  if (v_result->>'members_count')::integer <> 5 then
    raise exception 'CENA FAIL: members_count = % (esperaba 5)', v_result->>'members_count';
  end if;

  -- ═══ R.2E: regla de multa por tardanza ═══
  perform public.create_rule(v_ctx::uuid, 'Llegar >15 min tarde → multa $100',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": ">", "field": "minutes_late", "value": 15}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);

  -- ═══ R.2D: evento cena 20:00 (simulado: empezó hace 21 min) + RSVP + check-ins ═══
  v_event := (public.create_calendar_event(v_ctx::uuid, 'Cena miércoles', 'dinner',
    p_location_text := 'Por definir', p_starts_at := now() - interval '21 minutes', p_host_actor_id := a_jose))->>'event_id';

  -- RSVP going: José, David, Isaac
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');

  -- Check-ins: José 20:05 (+5, a tiempo)... como el evento "empezó" hace 21 min,
  -- el check-in de David AHORA = +21 min (tarde), José/Isaac simulan sus tiempos via metadata.
  -- David hace check-in real (21 min tarde) → multa automática
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.check_in_participant(v_event::uuid);
  if v_result->>'status' <> 'late' then
    raise exception 'CENA FAIL: David debió quedar late (quedó %)', v_result->>'status';
  end if;
  if (v_result->'rules'->>'rules_matched')::integer < 1 then
    raise exception 'CENA FAIL: regla de tardanza no aplicó a David';
  end if;

  -- ═══ R.2E verificación: obligation fine $100 para David ═══
  if not exists (
    select 1 from public.obligations
    where context_actor_id = v_ctx::uuid and debtor_actor_id = a_david
      and obligation_type = 'fine' and amount = 100 and status = 'open'
  ) then
    raise exception 'CENA FAIL: multa de $100 a David no existe';
  end if;

  -- ═══ R.2H: David paga $1300 (pizza 600 + cerveza 400 + botanas 300), 4 participantes ═══
  -- → 3 obligations de $325 c/u (José, Isaac, Daniel deben a David)
  v_result := public.record_expense(v_ctx::uuid, 1300, 'MXN', 'Pizza + Cerveza + Botanas',
    p_split_with := array[a_david, a_jose, a_isaac, a_daniel]);
  if (v_result->>'share_per_person')::numeric <> 325 then
    raise exception 'CENA FAIL: share = % (esperaba 325)', v_result->>'share_per_person';
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and obligation_type = 'expense_share'
        and creditor_actor_id = a_david and amount = 325 and status = 'open') <> 3 then
    raise exception 'CENA FAIL: no hay 3 obligations de $325';
  end if;

  -- ═══ R.2I: settlement optimizado ═══
  -- Abiertas: José→David 325, Isaac→David 325, Daniel→David 325, David→Grupo 100 (multa)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  if v_batch is null then raise exception 'CENA FAIL: settlement batch no generado'; end if;
  -- neto: David +975-100=+875, Grupo +100, José -325, Isaac -325, Daniel -325 → suma 0
  -- el batch debe cubrir exactamente el neto total de deudores: 975
  if (select sum(amount) from public.settlement_items where settlement_batch_id = v_batch) <> 975 then
    raise exception 'CENA FAIL: total settlement = % (esperaba 975)',
      (select sum(amount) from public.settlement_items where settlement_batch_id = v_batch);
  end if;

  -- ═══ R.2I: pagos marcados → obligations cerradas ═══
  for r in select id, from_actor_id from public.settlement_items where settlement_batch_id = v_batch loop
    -- el deudor de cada item lo paga
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', (select pp.auth_user_id from public.person_profiles pp where pp.actor_id = r.from_actor_id)::text)::text, true);
    perform public.mark_settlement_paid(r.id);
  end loop;

  if exists (select 1 from public.obligations
             where context_actor_id = v_ctx::uuid and status = 'open'
               and obligation_type = 'expense_share') then
    raise exception 'CENA FAIL: quedaron expense_shares abiertas post-settlement';
  end if;

  -- ═══ R.2J: actividad auditada ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.context_summary(v_ctx::uuid);
  if jsonb_array_length(v_result->'recent_activity') < 10 then
    raise exception 'CENA FAIL: actividad incompleta (%)', jsonb_array_length(v_result->'recent_activity');
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_jose, a_david, a_isaac, a_moises, a_daniel],
    array[u_jose, u_david, u_isaac, u_moises, u_daniel]);

  raise notice 'R.2 CENA SEMANAL: PASS';
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_r2_viaje()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  a_jose uuid; a_david uuid; a_isaac uuid;
  u_jose uuid; u_david uuid; u_isaac uuid;
  v_ctx uuid; v_result jsonb; v_batch uuid;
  r record;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José', '+5210000010');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David', '+5210000011');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac', '+5210000012');

  -- Contexto viaje (subtype trip)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Viaje Vegas 2026', 'collective', 'trip'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform public.invite_member(v_ctx::uuid, a_isaac);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);

  -- Recurso del viaje: hotel booking + evento
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.create_resource(v_ctx::uuid, 'trip_booking', 'Hotel Bellagio 3 noches');
  perform public.create_calendar_event(v_ctx::uuid, 'Viaje a Vegas', 'trip',
    p_location_text := 'Por definir', p_starts_at := now() + interval '30 days', p_ends_at := now() + interval '33 days');

  -- Gastos: José paga hotel $3000 (split 3), David paga cena $900 (split 3)
  v_result := public.record_expense(v_ctx::uuid, 3000, 'USD', 'Hotel');
  if (v_result->>'share_per_person')::numeric <> 1000 then
    raise exception 'VIAJE FAIL: split hotel incorrecto';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.record_expense(v_ctx::uuid, 900, 'USD', 'Cena');

  -- Settlement: neto José +1700, David -400, Isaac -1300 → 2 transferencias
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.generate_settlement_batch(v_ctx::uuid, 'USD');
  v_batch := (v_result->>'batch_id')::uuid;
  if jsonb_array_length(v_result->'items') <> 2 then
    raise exception 'VIAJE FAIL: settlement no optimizado (% items, esperaba 2)',
      jsonb_array_length(v_result->'items');
  end if;
  -- José debe recibir exactamente 1700
  if (select sum((i->>'amount')::numeric) from jsonb_array_elements(v_result->'items') i
      where (i->>'to')::uuid = a_jose) <> 1700 then
    raise exception 'VIAJE FAIL: neteo de José incorrecto';
  end if;

  -- Pagar todo
  for r in select id, from_actor_id from public.settlement_items where settlement_batch_id = v_batch loop
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', (select pp.auth_user_id from public.person_profiles pp where pp.actor_id = r.from_actor_id)::text)::text, true);
    perform public.mark_settlement_paid(r.id);
  end loop;

  if exists (select 1 from public.obligations where context_actor_id = v_ctx::uuid and status = 'open') then
    raise exception 'VIAJE FAIL: obligations abiertas post-settlement';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_jose, a_david, a_isaac], array[u_jose, u_david, u_isaac]);

  raise notice 'R.2 VIAJE: PASS';
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_r2d_events_dod()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  u_moises uuid; a_moises uuid;
  u_daniel uuid; a_daniel uuid;
  u_out uuid; a_out uuid;
  v_ctx uuid; v_event uuid; v_code text;
  v_result jsonb;
  v_starts timestamptz; v_ends timestamptz;
  v_t1800 timestamptz; v_t2012 timestamptz;
  v_pid_a uuid; v_pid_b uuid;
  v_caught boolean;
  v_fn text;
  r record;
begin
  -- ═══ Setup: Cena Semanal Amigos — José founder, 4 members via invite code ═══
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2D', '+5210000040');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2D', '+5210000041');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2D', '+5210000042');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés R2D', '+5210000043');
  select auth_id, actor_id into u_daniel, a_daniel from public._r2_make_person('Daniel R2D', '+5210000044');
  select auth_id, actor_id into u_out, a_out from public._r2_make_person('Outsider R2D', '+5210000045');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Tiempos exactos: "20:00" = now() - 21 min → el check-in natural de Moisés
  -- (now()) cae exactamente en "20:21". now() está congelado en la transacción.
  v_starts := now() - interval '21 minutes';          -- 20:00
  v_ends   := v_starts + interval '3 hours';          -- 23:00
  v_t1800  := v_starts - interval '2 hours';          -- 18:00
  v_t2012  := v_starts + interval '12 minutes';       -- 20:12

  -- ═══ 1. José crea el evento (cena mié 20:00–23:00, tz MX, host = David) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.create_calendar_event(v_ctx::uuid, 'Cena miércoles', 'dinner',
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_ends,
    p_timezone := 'America/Mexico_City',
    p_host_actor_id := a_david,
    p_client_id := 'r2d-cena-miercoles');
  v_event := (v_result->>'event_id')::uuid;

  -- calendar_events tiene 1 cena con atributos correctos
  if (select count(*) from public.calendar_events where context_actor_id = v_ctx::uuid) <> 1 then
    raise exception 'R2D FAIL 1: debe existir exactamente 1 evento';
  end if;
  if not exists (
    select 1 from public.calendar_events
    where id = v_event and event_type = 'dinner' and timezone = 'America/Mexico_City'
      and host_actor_id = a_david and starts_at = v_starts and ends_at = v_ends
  ) then
    raise exception 'R2D FAIL 1: atributos del evento incorrectos';
  end if;

  -- event_participants tiene 5 filas, todas 'invited'
  if (select count(*) from public.event_participants where event_id = v_event) <> 5 then
    raise exception 'R2D FAIL 1: esperaba 5 participantes';
  end if;
  if (select count(*) from public.event_participants where event_id = v_event and status = 'invited') <> 5 then
    raise exception 'R2D FAIL 1: todos los participantes iniciales deben ser invited';
  end if;

  -- Idempotencia: create con mismo client_id devuelve el mismo event_id
  if (public.create_calendar_event(v_ctx::uuid, 'Cena miércoles', 'dinner',
        p_location_text := 'Por definir', p_starts_at := v_starts, p_client_id := 'r2d-cena-miercoles')->>'event_id')::uuid
     is distinct from v_event then
    raise exception 'R2D FAIL idempotencia: client_id repetido devolvió otro event_id';
  end if;
  if (select count(*) from public.calendar_events where context_actor_id = v_ctx::uuid) <> 1 then
    raise exception 'R2D FAIL idempotencia: client_id repetido duplicó el evento';
  end if;

  -- ═══ 2. David, Isaac, Moisés y Daniel hacen RSVP = going ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.rsvp_event(v_event, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.rsvp_event(v_event, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.rsvp_event(v_event, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.rsvp_event(v_event, 'going');

  -- ═══ 3. José hace RSVP = maybe (y repetido actualiza la misma fila) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_pid_a := (public.rsvp_event(v_event, 'maybe')->>'participant_id')::uuid;
  v_pid_b := (public.rsvp_event(v_event, 'maybe')->>'participant_id')::uuid;
  if v_pid_a is distinct from v_pid_b then
    raise exception 'R2D FAIL 3: RSVP repetido creó otra fila';
  end if;
  if (select count(*) from public.event_participants where event_id = v_event) <> 5 then
    raise exception 'R2D FAIL 3: RSVP repetido duplicó participantes';
  end if;

  -- ═══ 4. David (host) hace check-in a las 20:00 ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.check_in_participant(v_event, p_checked_in_at := v_starts);
  if v_result->>'status' <> 'attended' then
    raise exception 'R2D FAIL 4: David debió quedar attended (quedó %)', v_result->>'status';
  end if;

  -- ═══ 5. Isaac check-in a las 20:12 (lo registra el host) ═══
  v_result := public.check_in_participant(v_event, a_isaac, v_t2012);
  if v_result->>'status' <> 'attended' then
    raise exception 'R2D FAIL 5: Isaac debió quedar attended (12 min < 15)';
  end if;

  -- Permiso: Isaac (miembro, no host/admin) NO puede check-in de otros
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin
    perform public.check_in_participant(v_event, a_moises);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2D FAIL permisos: miembro sin autoridad pudo check-in a otro'; end if;

  -- Permiso: Moisés NO puede self check-in con hora explícita (corrección = host/admin)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  v_caught := false;
  begin
    perform public.check_in_participant(v_event, p_checked_in_at := v_starts);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2D FAIL permisos: corrección de hora sin autoridad permitida'; end if;

  -- ═══ 6. Moisés hace check-in natural (= "20:21") → late ═══
  v_result := public.check_in_participant(v_event);
  if v_result->>'status' <> 'late' then
    raise exception 'R2D FAIL 6: Moisés debió quedar late (quedó %, % min)',
      v_result->>'status', v_result->>'minutes_late';
  end if;
  if (v_result->>'minutes_late')::numeric not between 20 and 22 then
    raise exception 'R2D FAIL 6: minutes_late de Moisés = % (esperaba ~21)', v_result->>'minutes_late';
  end if;

  -- Idempotencia: check-in repetido (Isaac) no duplica ni cambia checked_in_at
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_result := public.check_in_participant(v_event);
  if not coalesce((v_result->>'already_checked_in')::boolean, false) then
    raise exception 'R2D FAIL idempotencia: check-in repetido no fue no-op';
  end if;
  if (select checked_in_at from public.event_participants
      where event_id = v_event and participant_actor_id = a_isaac) is distinct from v_t2012 then
    raise exception 'R2D FAIL idempotencia: check-in repetido cambió checked_in_at de Isaac';
  end if;

  -- ═══ 7. Daniel cancela participación a las 18:00 ═══
  -- (el host registra la cancelación que Daniel avisó a las 18:00)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.cancel_participation(v_event, a_daniel, v_t1800);
  if v_result->>'status' <> 'cancelled' then
    raise exception 'R2D FAIL 7: cancelación de Daniel falló';
  end if;

  -- Idempotencia: cancel repetido (Daniel mismo) es no-op seguro
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_result := public.cancel_participation(v_event);
  if not coalesce((v_result->>'already_cancelled')::boolean, false) then
    raise exception 'R2D FAIL idempotencia: cancel repetido no fue no-op';
  end if;
  if (select cancelled_at from public.event_participants
      where event_id = v_event and participant_actor_id = a_daniel) is distinct from v_t1800 then
    raise exception 'R2D FAIL idempotencia: cancel repetido cambió cancelled_at';
  end if;

  -- ═══ 8. Resultado esperado completo (José nunca hizo check-in) ═══
  -- David: attended @ 20:00
  select * into r from public.event_participants where event_id = v_event and participant_actor_id = a_david;
  if r.status <> 'attended' or r.checked_in_at is distinct from v_starts then
    raise exception 'R2D FAIL 8: David esperaba attended@20:00 (% @ %)', r.status, r.checked_in_at;
  end if;
  -- Isaac: attended @ 20:12
  select * into r from public.event_participants where event_id = v_event and participant_actor_id = a_isaac;
  if r.status <> 'attended' or r.checked_in_at is distinct from v_t2012 then
    raise exception 'R2D FAIL 8: Isaac esperaba attended@20:12 (% @ %)', r.status, r.checked_in_at;
  end if;
  -- Moisés: late @ 20:21 (= now())
  select * into r from public.event_participants where event_id = v_event and participant_actor_id = a_moises;
  if r.status <> 'late' or r.checked_in_at is distinct from now() then
    raise exception 'R2D FAIL 8: Moisés esperaba late@20:21 (% @ %)', r.status, r.checked_in_at;
  end if;
  -- Daniel: cancelled @ 18:00, sin check-in
  select * into r from public.event_participants where event_id = v_event and participant_actor_id = a_daniel;
  if r.status <> 'cancelled' or r.cancelled_at is distinct from v_t1800 or r.checked_in_at is not null then
    raise exception 'R2D FAIL 8: Daniel esperaba cancelled@18:00 (% @ %)', r.status, r.cancelled_at;
  end if;
  -- José: maybe, checked_in_at NULL
  select * into r from public.event_participants where event_id = v_event and participant_actor_id = a_jose;
  if r.status <> 'maybe' or r.checked_in_at is not null then
    raise exception 'R2D FAIL 8: José esperaba maybe sin check-in (% @ %)', r.status, r.checked_in_at;
  end if;

  -- context_summary refleja el evento (upcoming/current)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.context_summary(v_ctx::uuid);
  if not exists (
    select 1 from jsonb_array_elements(v_result->'upcoming_events') e
    where (e->>'event_id')::uuid = v_event
  ) then
    raise exception 'R2D FAIL 8: context_summary no refleja el evento';
  end if;

  -- ═══ activity_events registra los 4 tipos ═══
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'event.created') <> 1 then
    raise exception 'R2D FAIL activity: event.created debe ser exactamente 1';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'event.rsvp_updated') <> 6 then
    raise exception 'R2D FAIL activity: event.rsvp_updated debe ser 6 (4 going + 2 maybe), hay %',
      (select count(*) from public.activity_events
       where context_actor_id = v_ctx::uuid and event_type = 'event.rsvp_updated');
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'event.checked_in') <> 3 then
    raise exception 'R2D FAIL activity: event.checked_in debe ser 3 (no-ops no emiten)';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'event.participation_cancelled') <> 1 then
    raise exception 'R2D FAIL activity: event.participation_cancelled debe ser 1 (no-ops no emiten)';
  end if;

  -- ═══ Permisos: no-miembro no puede ver ni modificar ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin perform public.rsvp_event(v_event, 'going');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2D FAIL permisos: no-miembro pudo RSVP'; end if;
  v_caught := false;
  begin perform public.check_in_participant(v_event);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2D FAIL permisos: no-miembro pudo check-in'; end if;
  v_caught := false;
  begin perform public.cancel_participation(v_event);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2D FAIL permisos: no-miembro pudo cancelar participación'; end if;
  v_caught := false;
  begin perform public.context_summary(v_ctx::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2D FAIL permisos: no-miembro pudo ver el contexto del evento'; end if;

  -- ═══ Permisos: miembro removido no puede RSVP ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.remove_member(v_ctx::uuid, a_daniel, 'prueba R2D');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_caught := false;
  begin perform public.rsvp_event(v_event, 'going');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2D FAIL permisos: miembro removido pudo RSVP'; end if;

  -- ═══ Permisos: anon bloqueado en todos los RPCs de eventos ═══
  foreach v_fn in array array[
    'public.create_calendar_event(uuid, text, text, timestamptz, timestamptz, text, text, text, text, uuid, boolean, jsonb, text)',
    'public.rsvp_event(uuid, text)',
    'public.check_in_participant(uuid, uuid, timestamptz)',
    'public.cancel_participation(uuid, uuid, timestamptz)',
    'public.close_event(uuid)'
  ] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'R2D FAIL permisos: anon puede ejecutar %', v_fn;
    end if;
  end loop;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_jose, a_david, a_isaac, a_moises, a_daniel, a_out],
    array[u_jose, u_david, u_isaac, u_moises, u_daniel, u_out]);

  raise notice 'R.2D EVENTS DoD: PASS (cena 20:00-23:00, RSVPs, check-ins exactos, cancelación, idempotencia, permisos)';
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_r2e_rules_dod()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  u_moises uuid; a_moises uuid;
  u_daniel uuid; a_daniel uuid;
  v_ctx uuid; v_event uuid; v_code text;
  v_rule1 uuid; v_rule2 uuid;
  v_result jsonb; v_payload jsonb;
  v_starts timestamptz;
  v_oblig_moises uuid; v_oblig_daniel uuid;
  v_caught boolean;
  v_fn text;
begin
  -- ═══ Setup: Cena Semanal Amigos + estado heredado de R.2D ═══
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2E', '+5210000050');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2E', '+5210000051');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2E', '+5210000052');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés R2E', '+5210000053');
  select auth_id, actor_id into u_daniel, a_daniel from public._r2_make_person('Daniel R2E', '+5210000054');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Evento: cena 20:00-23:00 MX, host David ("20:00" = now() - 21 min)
  v_starts := now() - interval '21 minutes';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_event := (public.create_calendar_event(v_ctx::uuid, 'Cena miércoles', 'dinner',
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_starts + interval '3 hours',
    p_timezone := 'America/Mexico_City', p_host_actor_id := a_david))->>'event_id';

  -- Estado R.2D heredado (SIN reglas todavía → los check-ins no generan multas):
  -- José RSVP maybe; David attended@20:00; Isaac attended@20:12 (host lo registra);
  -- Moisés late@20:21 (natural); Daniel cancelled@18:00 (host lo registra)
  perform public.rsvp_event(v_event::uuid, 'maybe');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.check_in_participant(v_event::uuid, p_checked_in_at := v_starts);
  perform public.check_in_participant(v_event::uuid, a_isaac, v_starts + interval '12 minutes');
  -- R.2M-2: la cancelación nunca cruza la medianoche CDMX del día del evento
  -- (antes: v_starts - 2 horas a secas → flake entre 00:21 y 02:21 CDMX)
  perform public.cancel_participation(v_event::uuid, a_daniel,
    greatest(v_starts - interval '2 hours',
             date_trunc('day', v_starts at time zone 'America/Mexico_City') at time zone 'America/Mexico_City'));
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.check_in_participant(v_event::uuid);

  -- Sanity del estado heredado
  if (select count(*) from public.obligations where context_actor_id = v_ctx::uuid) <> 0 then
    raise exception 'R2E FAIL setup: hay multas antes de crear reglas';
  end if;
  if (select status from public.event_participants where event_id = v_event::uuid and participant_actor_id = a_moises) <> 'late' then
    raise exception 'R2E FAIL setup: Moisés no quedó late';
  end if;

  -- ═══ 1. Crear ambas reglas (José, founder/admin) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_rule1 := (public.create_rule(v_ctx::uuid, 'Multa por llegar tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": ">", "field": "minutes_late", "value": 15}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine",
      "amount": 100, "currency": "MXN", "reason": "late_arrival"}]'::jsonb))->>'rule_id';

  v_rule2 := (public.create_rule(v_ctx::uuid, 'Multa por cancelar mismo día',
    p_trigger_event_type := 'event.participation_cancelled',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": "=", "field": "same_day_cancellation", "value": true}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine",
      "amount": 300, "currency": "MXN", "reason": "same_day_cancellation"}]'::jsonb))->>'rule_id';

  if v_rule1 is null or v_rule2 is null then
    raise exception 'R2E FAIL 1: las reglas no se crearon';
  end if;

  -- Permiso: miembro normal (Isaac) NO puede crear reglas
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin
    perform public.create_rule(v_ctx::uuid, 'R2E hack', p_trigger_event_type := 'x');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2E FAIL permisos: miembro normal creó una regla'; end if;

  -- ═══ 2. Evaluar el check-in de Moisés (José, admin) ═══
  -- El payload se reconstruye desde el estado guardado del participante
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  select jsonb_build_object(
    'minutes_late', (ep.metadata->>'minutes_late')::numeric,
    'status', ep.status,
    'event_type', ce.event_type)
  into v_payload
  from public.event_participants ep
  join public.calendar_events ce on ce.id = ep.event_id
  where ep.event_id = v_event::uuid and ep.participant_actor_id = a_moises;

  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.checked_in', a_moises, v_payload, v_event::uuid);
  if (v_result->>'rules_matched')::integer <> 1 then
    raise exception 'R2E FAIL 2: regla de tardanza no matcheó para Moisés (matched=%)', v_result->>'rules_matched';
  end if;
  v_oblig_moises := (v_result->'obligations_created'->0->>'obligation_id')::uuid;

  -- ═══ 3. Evaluar la cancelación de Daniel (José, admin) ═══
  select jsonb_build_object(
    'same_day_cancellation', (ep.metadata->>'same_day_cancellation')::boolean,
    'event_type', ce.event_type)
  into v_payload
  from public.event_participants ep
  join public.calendar_events ce on ce.id = ep.event_id
  where ep.event_id = v_event::uuid and ep.participant_actor_id = a_daniel;

  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.participation_cancelled', a_daniel, v_payload, v_event::uuid);
  if (v_result->>'rules_matched')::integer <> 1 then
    raise exception 'R2E FAIL 3: regla de cancelación no matcheó para Daniel';
  end if;
  v_oblig_daniel := (v_result->'obligations_created'->0->>'obligation_id')::uuid;

  -- ═══ Evaluar David e Isaac → not_matched, sin multas ═══
  -- David: lo evalúa José (admin)
  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.checked_in', a_david,
    jsonb_build_object('minutes_late', 0, 'status', 'attended', 'event_type', 'dinner'), v_event::uuid);
  if (v_result->>'rules_matched')::integer <> 0 then
    raise exception 'R2E FAIL: David recibió multa sin llegar tarde';
  end if;
  -- Isaac: lo evalúa David (HOST, no admin) → el gate de host permite ejecución directa
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.checked_in', a_isaac,
    jsonb_build_object('minutes_late', 12, 'status', 'attended', 'event_type', 'dinner'), v_event::uuid);
  if (v_result->>'rules_matched')::integer <> 0 then
    raise exception 'R2E FAIL: Isaac recibió multa sin llegar tarde';
  end if;

  -- ═══ 4. Re-ejecutar ambas evaluaciones → idempotencia ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  select jsonb_build_object(
    'minutes_late', (ep.metadata->>'minutes_late')::numeric,
    'status', ep.status, 'event_type', 'dinner')
  into v_payload
  from public.event_participants ep
  where ep.event_id = v_event::uuid and ep.participant_actor_id = a_moises;

  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.checked_in', a_moises, v_payload, v_event::uuid);
  if (v_result->'obligations_created'->0->>'obligation_id')::uuid is distinct from v_oblig_moises then
    raise exception 'R2E FAIL 4: re-evaluación no devolvió la misma obligation de Moisés';
  end if;
  if not (v_result->'obligations_created'->0->>'already_existed')::boolean then
    raise exception 'R2E FAIL 4: re-evaluación no marcó already_existed';
  end if;

  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.participation_cancelled', a_daniel,
    jsonb_build_object('same_day_cancellation', true, 'event_type', 'dinner'), v_event::uuid);
  if (v_result->'obligations_created'->0->>'obligation_id')::uuid is distinct from v_oblig_daniel then
    raise exception 'R2E FAIL 4: re-evaluación no devolvió la misma obligation de Daniel';
  end if;

  -- ═══ Resultado esperado ═══
  -- Moisés: exactamente 1 fine $100 MXN
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and debtor_actor_id = a_moises) <> 1 then
    raise exception 'R2E FAIL resultado: Moisés debe tener exactamente 1 multa';
  end if;
  if not exists (
    select 1 from public.obligations
    where id = v_oblig_moises and debtor_actor_id = a_moises and creditor_actor_id = v_ctx::uuid
      and obligation_type = 'fine' and amount = 100 and currency = 'MXN' and status = 'open'
      and source_rule_id = v_rule1::uuid and source_event_id = v_event::uuid
      and metadata->>'reason' = 'late_arrival'
      and (metadata->>'participant_actor_id')::uuid = a_moises
      and metadata->>'triggering_event_type' = 'event.checked_in'
      and metadata->>'rule_evaluation_id' is not null
  ) then
    raise exception 'R2E FAIL resultado: multa de Moisés incorrecta (monto/rule/event/metadata)';
  end if;

  -- Daniel: exactamente 1 fine $300 MXN
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and debtor_actor_id = a_daniel) <> 1 then
    raise exception 'R2E FAIL resultado: Daniel debe tener exactamente 1 multa';
  end if;
  if not exists (
    select 1 from public.obligations
    where id = v_oblig_daniel and debtor_actor_id = a_daniel and creditor_actor_id = v_ctx::uuid
      and obligation_type = 'fine' and amount = 300 and currency = 'MXN' and status = 'open'
      and source_rule_id = v_rule2::uuid and source_event_id = v_event::uuid
      and metadata->>'reason' = 'same_day_cancellation'
      and (metadata->>'participant_actor_id')::uuid = a_daniel
      and metadata->>'triggering_event_type' = 'event.participation_cancelled'
      and metadata->>'rule_evaluation_id' is not null
  ) then
    raise exception 'R2E FAIL resultado: multa de Daniel incorrecta (monto/rule/event/metadata)';
  end if;

  -- David, Isaac, José: cero multas; total contexto = 2
  if exists (select 1 from public.obligations
             where context_actor_id = v_ctx::uuid
               and debtor_actor_id in (a_david, a_isaac, a_jose)) then
    raise exception 'R2E FAIL resultado: David/Isaac/José tienen multas que no deberían';
  end if;
  if (select count(*) from public.obligations where context_actor_id = v_ctx::uuid) <> 2 then
    raise exception 'R2E FAIL resultado: deben existir exactamente 2 multas en el contexto';
  end if;

  -- rule_evaluation_id apunta a una evaluación matched de la regla correcta
  if not exists (
    select 1 from public.obligations o
    join public.rule_evaluations re on re.id = (o.metadata->>'rule_evaluation_id')::uuid
    where o.id = v_oblig_moises and re.rule_id = v_rule1::uuid and re.outcome = 'matched'
  ) or not exists (
    select 1 from public.obligations o
    join public.rule_evaluations re on re.id = (o.metadata->>'rule_evaluation_id')::uuid
    where o.id = v_oblig_daniel and re.rule_id = v_rule2::uuid and re.outcome = 'matched'
  ) then
    raise exception 'R2E FAIL resultado: rule_evaluation_id no apunta a la evaluación matched correcta';
  end if;

  -- rule_evaluations: matched (Moisés ×2, Daniel ×2) y not_matched (David, Isaac)
  if (select count(*) from public.rule_evaluations
      where context_actor_id = v_ctx::uuid and outcome = 'matched') <> 4 then
    raise exception 'R2E FAIL evaluaciones: esperaba 4 matched (Moisés ×2 + Daniel ×2)';
  end if;
  if (select count(*) from public.rule_evaluations
      where context_actor_id = v_ctx::uuid and outcome = 'not_matched') <> 2 then
    raise exception 'R2E FAIL evaluaciones: esperaba 2 not_matched (David + Isaac)';
  end if;

  -- activity_events: rule.evaluated, obligation.created, fine.created
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'rule.evaluated') <> 6 then
    raise exception 'R2E FAIL activity: rule.evaluated debe ser 6 (4 matched + 2 not_matched)';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'obligation.created') <> 2 then
    raise exception 'R2E FAIL activity: obligation.created debe ser 2 (idempotencia no re-emite)';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'fine.created') <> 2 then
    raise exception 'R2E FAIL activity: fine.created debe ser 2';
  end if;

  -- ═══ Permisos: miembro normal NO puede evaluar reglas sobre otros ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin
    perform public.evaluate_rules_for_event(v_ctx::uuid, 'event.checked_in', a_moises,
      '{"minutes_late": 999, "event_type": "dinner"}'::jsonb, v_event::uuid);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'R2E FAIL permisos: miembro normal pudo evaluar reglas sobre otro actor';
  end if;

  -- anon bloqueado
  foreach v_fn in array array[
    'public.create_rule(uuid, text, text, jsonb, jsonb, text, text, int)',
    'public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid)'
  ] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'R2E FAIL permisos: anon puede ejecutar %', v_fn;
    end if;
  end loop;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_jose, a_david, a_isaac, a_moises, a_daniel],
    array[u_jose, u_david, u_isaac, u_moises, u_daniel]);

  raise notice 'R.2E RULES DoD: PASS (2 reglas, multas Moisés $100 + Daniel $300, idempotencia, permisos)';
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_r2h_money_expenses_dod()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  u_moises uuid; a_moises uuid;
  u_daniel uuid; a_daniel uuid;
  u_out uuid; a_out uuid;
  v_ctx uuid; v_ctx2 uuid; v_event uuid; v_event2 uuid; v_code text;
  v_starts timestamptz;
  v_result jsonb;
  v_txn_dinner uuid; v_txn_dessert uuid; v_txn_game uuid;
  v_caught boolean;
  v_fn text;
begin
  -- ═══ Setup: Cena Semanal Amigos + estado heredado R.2D/R.2E ═══
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2H', '+5210000080');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2H', '+5210000081');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2H', '+5210000082');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés R2H', '+5210000083');
  select auth_id, actor_id into u_daniel, a_daniel from public._r2_make_person('Daniel R2H', '+5210000084');
  select auth_id, actor_id into u_out, a_out from public._r2_make_person('Outsider R2H', '+5210000085');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Reglas de R.2E (las multas se generan solas con los check-ins/cancelación)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.create_rule(v_ctx::uuid, 'Multa por llegar tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": ">", "field": "minutes_late", "value": 15}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine",
      "amount": 100, "currency": "MXN", "reason": "late_arrival"}]'::jsonb);
  perform public.create_rule(v_ctx::uuid, 'Multa por cancelar mismo día',
    p_trigger_event_type := 'event.participation_cancelled',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": "=", "field": "same_day_cancellation", "value": true}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine",
      "amount": 300, "currency": "MXN", "reason": "same_day_cancellation"}]'::jsonb);

  -- Evento + estado R.2D: David/José/Isaac attended, Moisés late, Daniel cancelled
  v_starts := now() - interval '21 minutes';
  v_event := (public.create_calendar_event(v_ctx::uuid, 'Cena miércoles', 'dinner',
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_starts + interval '3 hours',
    p_timezone := 'America/Mexico_City', p_host_actor_id := a_david))->>'event_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.check_in_participant(v_event::uuid, p_checked_in_at := v_starts);            -- David attended
  perform public.check_in_participant(v_event::uuid, a_jose, v_starts + interval '5 minutes');  -- José attended
  perform public.check_in_participant(v_event::uuid, a_isaac, v_starts + interval '12 minutes'); -- Isaac attended
  -- Daniel cancela a la hora de inicio: same-day garantizado en cualquier timezone/hora (multa $300)
  perform public.cancel_participation(v_event::uuid, a_daniel, v_starts);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.check_in_participant(v_event::uuid);                                          -- Moisés late (multa $100)

  -- Sanity: las 2 multas existen por reglas
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and obligation_type = 'fine' and status = 'open') <> 2 then
    raise exception 'R2H FAIL setup: las multas de R.2E no se generaron';
  end if;

  -- ═══ R.2H.1 — record_expense equal split ═══
  -- David paga $1,300; participan David/José/Isaac/Moisés; Daniel excluido
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.record_expense(v_ctx::uuid, 1300, 'MXN', 'Pizza, cerveza y botanas',
    p_split_with := array[a_david, a_jose, a_isaac, a_moises],
    p_event_id := v_event::uuid,
    p_client_id := 'r2h-dinner-expense-001',
    p_excluded_actor_ids := array[a_daniel]);
  v_txn_dinner := (v_result->>'transaction_id')::uuid;

  -- money_transaction correcta
  if not exists (
    select 1 from public.money_transactions
    where id = v_txn_dinner and transaction_type = 'expense' and amount = 1300 and currency = 'MXN'
      and context_actor_id = v_ctx::uuid and from_actor_id = a_david and event_id = v_event::uuid
  ) then
    raise exception 'R2H.1 FAIL: money_transaction incorrecta';
  end if;

  -- splits: David payer 1300 + David beneficiary 325 + 3 debtors 325 + Daniel excluded 0
  if not exists (select 1 from public.money_splits where transaction_id = v_txn_dinner
                 and actor_id = a_david and split_role = 'payer' and amount = 1300) then
    raise exception 'R2H.1 FAIL: split payer de David incorrecto';
  end if;
  if not exists (select 1 from public.money_splits where transaction_id = v_txn_dinner
                 and actor_id = a_david and split_role = 'beneficiary' and amount = 325) then
    raise exception 'R2H.1 FAIL: self-share de David incorrecto';
  end if;
  if (select count(*) from public.money_splits where transaction_id = v_txn_dinner
      and split_role = 'debtor' and amount = 325
      and actor_id in (a_jose, a_isaac, a_moises)) <> 3 then
    raise exception 'R2H.1 FAIL: splits debtor incorrectos';
  end if;
  if not exists (select 1 from public.money_splits where transaction_id = v_txn_dinner
                 and actor_id = a_daniel and split_role = 'excluded' and amount = 0) then
    raise exception 'R2H.1 FAIL: split excluded de Daniel incorrecto';
  end if;

  -- obligations: José/Isaac/Moisés → David $325; NO David→David; NO Daniel→David
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and creditor_actor_id = a_david
        and obligation_type = 'expense_share' and amount = 325 and status = 'open'
        and debtor_actor_id in (a_jose, a_isaac, a_moises)) <> 3 then
    raise exception 'R2H.1 FAIL: obligations de expense_share incorrectas';
  end if;
  if exists (select 1 from public.obligations
             where context_actor_id = v_ctx::uuid and debtor_actor_id = a_david and creditor_actor_id = a_david) then
    raise exception 'R2H.1 FAIL: existe obligation David → David';
  end if;
  if exists (select 1 from public.obligations
             where context_actor_id = v_ctx::uuid and debtor_actor_id = a_daniel and creditor_actor_id = a_david) then
    raise exception 'R2H.1 FAIL: Daniel (excluido) tiene obligation hacia David';
  end if;

  -- ═══ R.2H.2 — Idempotencia ═══
  v_result := public.record_expense(v_ctx::uuid, 1300, 'MXN', 'Pizza, cerveza y botanas',
    p_split_with := array[a_david, a_jose, a_isaac, a_moises],
    p_event_id := v_event::uuid,
    p_client_id := 'r2h-dinner-expense-001',
    p_excluded_actor_ids := array[a_daniel]);
  if (v_result->>'transaction_id')::uuid is distinct from v_txn_dinner
     or not coalesce((v_result->>'idempotent_replay')::boolean, false) then
    raise exception 'R2H.2 FAIL: client_id repetido no devolvió la misma transaction';
  end if;
  if (select count(*) from public.money_transactions where context_actor_id = v_ctx::uuid and transaction_type = 'expense') <> 1 then
    raise exception 'R2H.2 FAIL: la transaction se duplicó';
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and obligation_type = 'expense_share') <> 3 then
    raise exception 'R2H.2 FAIL: las obligations se duplicaron';
  end if;
  if (select count(*) from public.money_splits where transaction_id = v_txn_dinner) <> 6 then
    raise exception 'R2H.2 FAIL: los splits se duplicaron';
  end if;

  -- ═══ R.2H.3 — Custom split ═══
  -- José paga postre $500: José $100 (self), David $200, Isaac $200
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.record_expense(v_ctx::uuid, 500, 'MXN', 'Postre',
    p_split_method := 'custom',
    p_splits := jsonb_build_array(
      jsonb_build_object('actor_id', a_jose, 'amount', 100),
      jsonb_build_object('actor_id', a_david, 'amount', 200),
      jsonb_build_object('actor_id', a_isaac, 'amount', 200)),
    p_client_id := 'r2h-dessert-custom-001');
  v_txn_dessert := (v_result->>'transaction_id')::uuid;

  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and creditor_actor_id = a_jose
        and obligation_type = 'expense_share' and amount = 200 and status = 'open'
        and debtor_actor_id in (a_david, a_isaac)) <> 2 then
    raise exception 'R2H.3 FAIL: obligations del custom split incorrectas';
  end if;
  if exists (select 1 from public.obligations
             where debtor_actor_id = a_jose and creditor_actor_id = a_jose) then
    raise exception 'R2H.3 FAIL: existe obligation José → José';
  end if;
  -- suma de splits del postre (excluyendo payer row) = 500
  if (select sum(amount) from public.money_splits
      where transaction_id = v_txn_dessert and split_role in ('beneficiary', 'debtor')) <> 500 then
    raise exception 'R2H.3 FAIL: los splits del postre no suman 500';
  end if;

  -- R.2H.3b — Custom split inválido (suma 400 ≠ 500) debe fallar
  v_caught := false;
  begin
    perform public.record_expense(v_ctx::uuid, 500, 'MXN', 'Postre mal sumado',
      p_split_method := 'custom',
      p_splits := jsonb_build_array(
        jsonb_build_object('actor_id', a_jose, 'amount', 100),
        jsonb_build_object('actor_id', a_david, 'amount', 100),
        jsonb_build_object('actor_id', a_isaac, 'amount', 200)));
  exception when others then v_caught := true;
  end;
  if not v_caught then raise exception 'R2H.3b FAIL: custom split con suma incorrecta no falló'; end if;

  -- ═══ R.2H.4 — Game result (Catan: Moisés le gana $250 a Daniel) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  v_result := public.record_game_result(v_ctx::uuid, v_event::uuid, 'Catan',
    a_moises, a_daniel, 250, 'MXN', 'r2h-catan-001');
  v_txn_game := (v_result->>'transaction_id')::uuid;

  if not exists (
    select 1 from public.money_transactions
    where id = v_txn_game and transaction_type = 'game_result' and amount = 250 and currency = 'MXN'
  ) then
    raise exception 'R2H.4 FAIL: transaction game_result incorrecta';
  end if;
  if not exists (
    select 1 from public.obligations
    where context_actor_id = v_ctx::uuid and debtor_actor_id = a_daniel and creditor_actor_id = a_moises
      and obligation_type = 'game_debt' and amount = 250 and status = 'open'
      and source_event_id = v_event::uuid and metadata->>'game_name' = 'Catan'
  ) then
    raise exception 'R2H.4 FAIL: obligation game_debt incorrecta';
  end if;

  -- Idempotencia del game result
  v_result := public.record_game_result(v_ctx::uuid, v_event::uuid, 'Catan',
    a_moises, a_daniel, 250, 'MXN', 'r2h-catan-001');
  if not coalesce((v_result->>'idempotent_replay')::boolean, false) then
    raise exception 'R2H.4 FAIL: game result repetido no fue replay';
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and obligation_type = 'game_debt') <> 1 then
    raise exception 'R2H.4 FAIL: game_debt duplicada';
  end if;

  -- ═══ R.2H.5 — Coexistencia con multas: exactamente 8 obligations abiertas ═══
  if (select count(*) from public.obligations where context_actor_id = v_ctx::uuid and status = 'open') <> 8 then
    raise exception 'R2H.5 FAIL: esperaba 8 obligations abiertas, hay %',
      (select count(*) from public.obligations where context_actor_id = v_ctx::uuid and status = 'open');
  end if;
  -- multas: Moisés $100 (late_arrival) + Daniel $300 (same_day_cancellation)
  if not exists (select 1 from public.obligations where context_actor_id = v_ctx::uuid and status = 'open'
                 and debtor_actor_id = a_moises and creditor_actor_id = v_ctx::uuid
                 and obligation_type = 'fine' and amount = 100 and metadata->>'reason' = 'late_arrival'
                 and source_rule_id is not null) then
    raise exception 'R2H.5 FAIL: multa de Moisés incorrecta';
  end if;
  if not exists (select 1 from public.obligations where context_actor_id = v_ctx::uuid and status = 'open'
                 and debtor_actor_id = a_daniel and creditor_actor_id = v_ctx::uuid
                 and obligation_type = 'fine' and amount = 300 and metadata->>'reason' = 'same_day_cancellation') then
    raise exception 'R2H.5 FAIL: multa de Daniel incorrecta';
  end if;
  -- cena: 3 × $325 a David / postre: 2 × $200 a José / juego: Daniel → Moisés $250
  if (select count(*) from public.obligations where context_actor_id = v_ctx::uuid and status = 'open'
      and obligation_type = 'expense_share' and creditor_actor_id = a_david and amount = 325) <> 3
     or (select count(*) from public.obligations where context_actor_id = v_ctx::uuid and status = 'open'
         and obligation_type = 'expense_share' and creditor_actor_id = a_jose and amount = 200) <> 2
     or (select count(*) from public.obligations where context_actor_id = v_ctx::uuid and status = 'open'
         and obligation_type = 'game_debt' and creditor_actor_id = a_moises and amount = 250) <> 1 then
    raise exception 'R2H.5 FAIL: composición de obligations incorrecta';
  end if;
  -- ninguna obligation fuera del contexto (no leaks)
  if exists (select 1 from public.obligations
             where debtor_actor_id in (a_jose, a_david, a_isaac, a_moises, a_daniel)
               and context_actor_id is distinct from v_ctx::uuid) then
    raise exception 'R2H.5 FAIL: hay obligations fuera del contexto (leak)';
  end if;

  -- ═══ R.2H.10 — Activity events ═══
  if (select count(*) from public.activity_events where context_actor_id = v_ctx::uuid
      and event_type = 'expense.recorded') <> 2 then
    raise exception 'R2H FAIL activity: expense.recorded debe ser 2 (cena + postre)';
  end if;
  if (select count(*) from public.activity_events where context_actor_id = v_ctx::uuid
      and event_type = 'split.generated') <> 2 then
    raise exception 'R2H FAIL activity: split.generated debe ser 2';
  end if;
  if (select count(*) from public.activity_events where context_actor_id = v_ctx::uuid
      and event_type = 'game_result.recorded') <> 1 then
    raise exception 'R2H FAIL activity: game_result.recorded debe ser 1';
  end if;
  -- obligation.created: 2 multas (rules) + 3 cena + 2 postre + 1 juego = 8
  if (select count(*) from public.activity_events where context_actor_id = v_ctx::uuid
      and event_type = 'obligation.created') <> 8 then
    raise exception 'R2H FAIL activity: obligation.created debe ser 8, hay %',
      (select count(*) from public.activity_events where context_actor_id = v_ctx::uuid
       and event_type = 'obligation.created');
  end if;

  -- ═══ R.2H.7 — Validaciones duras (todas deben fallar sin crear datos) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  -- amount <= 0
  v_caught := false;
  begin perform public.record_expense(v_ctx::uuid, 0, 'MXN', 'inválido');
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2H.7 FAIL: amount 0 no falló'; end if;
  -- currency null
  v_caught := false;
  begin perform public.record_expense(v_ctx::uuid, 100, null, 'inválido');
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2H.7 FAIL: currency null no falló'; end if;
  -- paid_by no es actor válido (José es admin → pasa el gate de permiso, falla la validación)
  v_caught := false;
  begin perform public.record_expense(v_ctx::uuid, 100, 'MXN', 'inválido', p_paid_by_actor_id := gen_random_uuid());
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2H.7 FAIL: paid_by inválido no falló'; end if;
  -- participant list vacía
  v_caught := false;
  begin perform public.record_expense(v_ctx::uuid, 100, 'MXN', 'inválido', p_split_with := array[]::uuid[]);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2H.7 FAIL: lista vacía no falló'; end if;
  -- duplicate participant
  v_caught := false;
  begin perform public.record_expense(v_ctx::uuid, 100, 'MXN', 'inválido', p_split_with := array[a_david, a_david]);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2H.7 FAIL: participante duplicado no falló'; end if;
  -- excluded también participante
  v_caught := false;
  begin perform public.record_expense(v_ctx::uuid, 100, 'MXN', 'inválido',
    p_split_with := array[a_david, a_isaac], p_excluded_actor_ids := array[a_david]);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2H.7 FAIL: excluded-como-participante no falló'; end if;
  -- participante no-miembro del contexto
  v_caught := false;
  begin perform public.record_expense(v_ctx::uuid, 100, 'MXN', 'inválido', p_split_with := array[a_david, a_out]);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2H.7 FAIL: participante no-miembro no falló'; end if;
  -- evento de otro contexto
  v_ctx2 := (public.create_context('R2H Otro Contexto', 'collective', 'friend_group'))->>'context_actor_id';
  v_event2 := (public.create_calendar_event(v_ctx2::uuid, 'Evento ajeno', 'dinner',
    p_location_text := 'Por definir', p_starts_at := now() + interval '1 day'))->>'event_id';
  v_caught := false;
  begin perform public.record_expense(v_ctx::uuid, 100, 'MXN', 'inválido', p_event_id := v_event2::uuid);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2H.7 FAIL: evento de otro contexto no falló'; end if;

  -- game result: winner = loser
  v_caught := false;
  begin perform public.record_game_result(v_ctx::uuid, v_event::uuid, 'Catan', a_moises, a_moises, 100);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2H.7 FAIL: winner=loser no falló'; end if;
  -- game result: amount <= 0
  v_caught := false;
  begin perform public.record_game_result(v_ctx::uuid, v_event::uuid, 'Catan', a_moises, a_daniel, 0);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2H.7 FAIL: game amount 0 no falló'; end if;
  -- game result: winner no-miembro
  v_caught := false;
  begin perform public.record_game_result(v_ctx::uuid, v_event::uuid, 'Catan', a_out, a_daniel, 100);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2H.7 FAIL: winner no-miembro no falló'; end if;
  -- game result: evento de otro contexto
  v_caught := false;
  begin perform public.record_game_result(v_ctx::uuid, v_event2::uuid, 'Catan', a_moises, a_daniel, 100);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2H.7 FAIL: game con evento ajeno no falló'; end if;

  -- ═══ R.2H.6 — Permisos ═══
  -- (2) no-miembro no puede registrar gasto
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin perform public.record_expense(v_ctx::uuid, 100, 'MXN', 'hack');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2H.6 FAIL: no-miembro registró gasto'; end if;

  -- (5) un miembro NO puede registrar gasto pagado por otro (sin money.record_for_others)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin perform public.record_expense(v_ctx::uuid, 100, 'MXN', 'por otro', p_paid_by_actor_id := a_david);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2H.6 FAIL: member registró gasto pagado por otro sin permiso'; end if;

  -- (6) admin (José, con money.record_for_others) SÍ puede registrar gasto pagado por David
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.record_expense(v_ctx::uuid, 100, 'MXN', 'Propina registrada por José, pagada por David',
    p_split_with := array[a_david, a_jose], p_paid_by_actor_id := a_david);
  if not exists (
    select 1 from public.money_transactions
    where id = (v_result->>'transaction_id')::uuid and from_actor_id = a_david and created_by_actor_id = a_jose
  ) then
    raise exception 'R2H.6 FAIL: admin no pudo registrar gasto pagado por otro';
  end if;

  -- (3) miembro removido no puede registrar gasto
  perform public.remove_member(v_ctx::uuid, a_daniel, 'prueba R2H');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_caught := false;
  begin perform public.record_expense(v_ctx::uuid, 100, 'MXN', 'hack removido');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2H.6 FAIL: miembro removido registró gasto'; end if;

  -- (4) anon bloqueado
  foreach v_fn in array array[
    'public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[])',
    'public.record_game_result(uuid, uuid, text, uuid, uuid, numeric, text, text)',
    'public.record_fine(uuid, uuid, numeric, text, text)',
    'public.generate_settlement_batch(uuid, text)',
    'public.mark_settlement_paid(uuid)'
  ] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'R2H.6 FAIL: anon puede ejecutar %', v_fn;
    end if;
  end loop;

  -- ═══ Cleanup (ambos contextos) ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx2::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_jose, a_david, a_isaac, a_moises, a_daniel, a_out],
    array[u_jose, u_david, u_isaac, u_moises, u_daniel, u_out]);

  raise notice 'R.2H MONEY/EXPENSES DoD: PASS (equal $1300/4, custom $500, Catan $250, 8 obligations coexistiendo, permisos, validaciones)';
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_r2j_activity_idempotency()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_a uuid; a_a uuid; u_b uuid; a_b uuid; u_c uuid; a_c uuid;
  v_ctx uuid; v_code text; v_event uuid; v_casa uuid;
  v_res_b uuid; v_res_c uuid; v_conflict uuid;
  v_decision uuid; v_batch uuid; v_item uuid;
  v_starts timestamptz;
  c_before jsonb; c_after jsonb;
begin
  select auth_id, actor_id into u_a, a_a from public._r2_make_person('R2J Idem A', '+5210000110');
  select auth_id, actor_id into u_b, a_b from public._r2_make_person('R2J Idem B', '+5210000111');
  select auth_id, actor_id into u_c, a_c from public._r2_make_person('R2J Idem C', '+5210000112');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := (public.create_context('R2J Idempotencia', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  perform public.create_rule(v_ctx::uuid, 'Multa por tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": ">", "field": "minutes_late", "value": 15}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);

  v_starts := now() - interval '30 minutes';
  v_event := (public.create_calendar_event(v_ctx::uuid, 'Cena idem', 'dinner',
    p_location_text := 'Por definir', p_starts_at := v_starts, p_host_actor_id := a_a))->>'event_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.check_in_participant(v_event::uuid);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  perform public.record_expense(v_ctx::uuid, 900, 'MXN', 'Cena idem',
    p_client_id := 'r2j-idem-expense-001');
  v_casa := (public.create_resource(v_ctx::uuid, 'house', 'Casa idem'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, a_b, 'USE');
  perform public.grant_right(v_casa::uuid, a_c, 'USE');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  v_res_b := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
    now() + interval '5 days', now() + interval '7 days'))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  v_res_c := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
    now() + interval '6 days', now() + interval '8 days'))->>'reservation_id';
  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_casa::uuid and resolution_status = 'open' limit 1;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_decision := (public.create_decision(v_ctx::uuid, 'generic', 'Decisión idem',
    p_payload := jsonb_build_object('options', jsonb_build_array('Si', 'No'))))->>'decision_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.vote_decision(v_decision::uuid, 'approve', 'Si');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  perform public.resolve_reservation_conflict(v_conflict, v_res_b::uuid);
  v_batch := (public.generate_settlement_batch(v_ctx::uuid, 'MXN'))->>'batch_id';
  select id into v_item from public.settlement_items
   where settlement_batch_id = v_batch::uuid limit 1;
  perform public.mark_settlement_paid(v_item);

  -- ═══ Snapshot de conteos críticos ═══
  select jsonb_object_agg(event_type, cnt) into c_before from (
    select event_type, count(*) as cnt from public.activity_events
    where context_actor_id = v_ctx::uuid
      and event_type in ('expense.recorded', 'split.generated', 'obligation.created', 'fine.created',
                         'event.checked_in', 'reservation.conflict_detected', 'reservation.conflict_resolved',
                         'settlement.generated', 'settlement.item_created', 'settlement.paid',
                         'decision.created', 'rule.evaluated')
    group by event_type) t;

  -- ═══ Re-ejecutar TODAS las operaciones idempotentes ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  perform public.record_expense(v_ctx::uuid, 900, 'MXN', 'Cena idem',
    p_client_id := 'r2j-idem-expense-001');
  begin
    perform public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  exception when others then null;
  end;
  perform public.mark_settlement_paid(v_item);
  perform public.detect_reservation_conflicts(v_casa::uuid);
  perform public.resolve_reservation_conflict(v_conflict, v_res_b::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.check_in_participant(v_event::uuid);
  perform public.vote_decision(v_decision::uuid, 'approve', 'No');

  -- ═══ Verificación: conteos críticos estables ═══
  select jsonb_object_agg(event_type, cnt) into c_after from (
    select event_type, count(*) as cnt from public.activity_events
    where context_actor_id = v_ctx::uuid
      and event_type in ('expense.recorded', 'split.generated', 'obligation.created', 'fine.created',
                         'event.checked_in', 'reservation.conflict_detected', 'reservation.conflict_resolved',
                         'settlement.generated', 'settlement.item_created', 'settlement.paid',
                         'decision.created', 'rule.evaluated')
    group by event_type) t;

  if c_before is distinct from c_after then
    raise exception 'R2J IDEMPOTENCY FAIL: los re-runs duplicaron activity (antes: %, después: %)', c_before, c_after;
  end if;

  if (select count(*) from public.decision_votes where decision_id = v_decision::uuid) <> 1 then
    raise exception 'R2J IDEMPOTENCY FAIL: el re-voto duplicó decision_votes';
  end if;
  if (select count(*) from public.money_transactions
      where context_actor_id = v_ctx::uuid and client_id = 'r2j-idem-expense-001') <> 1 then
    raise exception 'R2J IDEMPOTENCY FAIL: transaction duplicada por client_id';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_a, a_b, a_c], array[u_a, u_b, u_c]);

  raise notice 'R.2J ACTIVITY IDEMPOTENCY: PASS (7 operaciones re-ejecutadas, cero activity duplicada)';
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_r2k_full_reality_auth_simulation()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_jose uuid := gen_random_uuid(); u_david uuid := gen_random_uuid(); u_isaac uuid := gen_random_uuid();
  u_moises uuid := gen_random_uuid(); u_daniel uuid := gen_random_uuid(); u_abuelo uuid := gen_random_uuid();
  u_linda uuid := gen_random_uuid(); u_banco uuid := gen_random_uuid(); u_out uuid := gen_random_uuid();
  a_jose uuid; a_david uuid; a_isaac uuid; a_moises uuid; a_daniel uuid; a_abuelo uuid;
  a_linda uuid; a_banco uuid; a_out uuid;
  c_cena uuid; c_viaje uuid; c_familia uuid; c_negocio uuid; c_sinai uuid; c_maguen uuid; c_trust uuid;
  r_casa uuid; r_terreno uuid; r_acciones uuid; r_cuenta uuid; r_salon uuid;
  v_code text; v_starts timestamptz; v_event uuid; v_batch uuid;
  v_res_david uuid; v_res_isaac uuid; v_conflict record;
  v_decision uuid; v_result jsonb; v_world jsonb;
  v_caught boolean; v_item record; v_n integer;
  v_type text; v_missing text[] := array[]::text[];
  r record;
begin
  -- ═══ 1. AUTH: el trigger real de auth.users crea person_profiles + actors ═══
  for r in
    select * from (values
      ('José R2K', u_jose), ('David R2K', u_david), ('Isaac R2K', u_isaac),
      ('Moisés R2K', u_moises), ('Daniel R2K', u_daniel), ('Abuelo R2K', u_abuelo),
      ('Linda R2K', u_linda), ('Banco Fiduciario R2K', u_banco), ('Outsider R2K', u_out)) t(who, uid)
  loop
    insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (r.uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            lower(replace(split_part(r.who, ' ', 1), 'é', 'e')) || '.' || substr(r.uid::text, 1, 8) || '@r2k.test',
            '{"provider": "email", "providers": ["email"]}'::jsonb,
            jsonb_build_object('full_name', r.who), now(), now());
  end loop;

  select actor_id into a_jose from public.person_profiles where auth_user_id = u_jose;
  select actor_id into a_david from public.person_profiles where auth_user_id = u_david;
  select actor_id into a_isaac from public.person_profiles where auth_user_id = u_isaac;
  select actor_id into a_moises from public.person_profiles where auth_user_id = u_moises;
  select actor_id into a_daniel from public.person_profiles where auth_user_id = u_daniel;
  select actor_id into a_abuelo from public.person_profiles where auth_user_id = u_abuelo;
  select actor_id into a_linda from public.person_profiles where auth_user_id = u_linda;
  select actor_id into a_banco from public.person_profiles where auth_user_id = u_banco;
  select actor_id into a_out from public.person_profiles where auth_user_id = u_out;
  if a_jose is null or a_david is null or a_isaac is null or a_moises is null or a_daniel is null
     or a_abuelo is null or a_linda is null or a_banco is null or a_out is null then
    raise exception 'R2K 1 FAIL: el trigger de auth no creó la cadena auth.users → person_profiles → actors';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  if public.current_actor_id() is distinct from a_jose then
    raise exception 'R2K 1 FAIL: current_actor_id() incorrecto para José';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_banco::text)::text, true);
  if public.current_actor_id() is distinct from a_banco then
    raise exception 'R2K 1 FAIL: current_actor_id() incorrecto para Banco';
  end if;

  perform public._assert_anon_has_no_function_access();

  -- ═══ 2. CONTEXTOS (7) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  c_cena := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group'))->>'context_actor_id';
  c_viaje := (public.create_context('Viaje Japón 2028', 'collective', 'trip'))->>'context_actor_id';
  c_negocio := (public.create_context('Negocio Valle', 'legal_entity', 'company'))->>'context_actor_id';
  c_sinai := (public.create_context('Monte Sinaí', 'collective', 'community'))->>'context_actor_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  c_familia := (public.create_context('Familia Mizrahi', 'collective', 'family'))->>'context_actor_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  c_maguen := (public.create_context('Maguén David', 'collective', 'community'))->>'context_actor_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_banco::text)::text, true);
  c_trust := (public.create_context('Trust Familiar', 'legal_entity', 'trust'))->>'context_actor_id';

  if (select count(*) from public.actors where id in (c_cena, c_viaje, c_familia, c_negocio, c_sinai, c_maguen, c_trust)) <> 7 then
    raise exception 'R2K 2 FAIL: no se crearon los 7 contextos';
  end if;
  if (select actor_kind from public.actors where id = c_negocio) <> 'legal_entity'
     or (select actor_subtype from public.actors where id = c_trust) <> 'trust' then
    raise exception 'R2K 2 FAIL: kinds/subtypes de legal entity / trust incorrectos';
  end if;

  -- ═══ 3. MEMBERSHIPS + context_candidates ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_code := (public.create_invite(c_cena::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_code := (public.create_invite(c_viaje::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_code := (public.create_invite(c_familia::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_linda::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_code := (public.create_invite(c_negocio::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_code := (public.create_invite(c_sinai::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_code := (public.create_invite(c_maguen::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_banco::text)::text, true);
  v_code := (public.create_invite(c_trust::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_linda::text)::text, true);
  perform public.join_by_invite_code(v_code);
  insert into public.actor_memberships (context_actor_id, member_actor_id, membership_status, membership_type)
  values (c_trust::uuid, a_jose, 'active', 'observer');

  insert into public.actor_relationships (subject_actor_id, relationship_type, object_actor_id, created_by_actor_id, metadata) values
    (a_banco, 'trustee_of', c_trust::uuid, a_banco, '{}'),
    (a_linda, 'beneficiary_of', c_trust::uuid, a_banco, '{}'),
    (a_jose, 'related_to', c_trust::uuid, a_banco, '{"role": "advisor"}'),
    (a_jose, 'shareholder_of', c_negocio::uuid, a_jose, '{"percent": 50}'),
    (a_david, 'shareholder_of', c_negocio::uuid, a_jose, '{"percent": 50}');

  -- context_candidates por actor
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.context_candidates();
  if (select count(*) from jsonb_array_elements(v_result->'contexts') c
      where (c->>'context_actor_id')::uuid in (c_cena::uuid, c_viaje::uuid, c_familia::uuid, c_negocio::uuid, c_sinai::uuid, c_trust::uuid)) <> 6
     or exists (select 1 from jsonb_array_elements(v_result->'contexts') c
                where (c->>'context_actor_id')::uuid = c_maguen::uuid) then
    raise exception 'R2K 3 FAIL: candidates de José incorrectos';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_result := public.context_candidates();
  if (select count(*) from jsonb_array_elements(v_result->'contexts') c
      where (c->>'context_actor_id')::uuid in (c_cena::uuid, c_viaje::uuid, c_familia::uuid, c_maguen::uuid)) <> 4
     or exists (select 1 from jsonb_array_elements(v_result->'contexts') c
                where (c->>'context_actor_id')::uuid in (c_negocio::uuid, c_sinai::uuid, c_trust::uuid)) then
    raise exception 'R2K 3 FAIL: candidates de Isaac incorrectos';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_result := public.context_candidates();
  if (select count(*) from jsonb_array_elements(v_result->'contexts') c
      where (c->>'context_actor_id')::uuid in (c_cena::uuid, c_familia::uuid, c_sinai::uuid)) <> 3
     or exists (select 1 from jsonb_array_elements(v_result->'contexts') c
                where (c->>'context_actor_id')::uuid in (c_viaje::uuid, c_negocio::uuid, c_maguen::uuid, c_trust::uuid)) then
    raise exception 'R2K 3 FAIL: candidates de Daniel incorrectos';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_result := public.context_candidates();
  if exists (select 1 from jsonb_array_elements(v_result->'contexts') c
             where (c->>'context_actor_id')::uuid in
               (c_cena::uuid, c_viaje::uuid, c_familia::uuid, c_negocio::uuid, c_sinai::uuid, c_maguen::uuid, c_trust::uuid)) then
    raise exception 'R2K 3 FAIL: el outsider ve contextos privados';
  end if;

  -- ═══ 4. RECURSOS ÚNICOS + RIGHTS + visibilidad ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  r_casa := (public.create_resource(a_abuelo, 'house', 'Casa Valle R2K'))->>'resource_id';
  perform public.grant_right(r_casa::uuid, c_familia::uuid, 'GOVERN');
  perform public.grant_right(r_casa::uuid, a_jose, 'USE');
  perform public.grant_right(r_casa::uuid, a_david, 'USE');
  perform public.grant_right(r_casa::uuid, a_isaac, 'USE');
  perform public.grant_right(r_casa::uuid, a_moises, 'VIEW');
  perform public.grant_right(r_casa::uuid, c_trust::uuid, 'BENEFICIARY');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  r_terreno := (public.create_resource(a_jose, 'property', 'Terreno Valle R2K'))->>'resource_id';
  perform public.grant_right(r_terreno::uuid, a_jose, 'OWN', 50);
  perform public.grant_right(r_terreno::uuid, a_david, 'OWN', 50);
  perform public.grant_right(r_terreno::uuid, c_negocio::uuid, 'MANAGE');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_banco::text)::text, true);
  r_acciones := (public.create_resource(c_trust::uuid, 'other', 'Acciones Quimibond R2K'))->>'resource_id';
  perform public.grant_right(r_acciones::uuid, a_linda, 'BENEFICIARY');
  perform public.grant_right(r_acciones::uuid, a_banco, 'MANAGE');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  r_cuenta := (public.create_resource(c_viaje::uuid, 'bank_account', 'Cuenta Viaje Japón R2K'))->>'resource_id';
  perform public.grant_right(r_cuenta::uuid, c_viaje::uuid, 'MANAGE');
  perform public.grant_right(r_cuenta::uuid, a_jose, 'VIEW');
  perform public.grant_right(r_cuenta::uuid, a_david, 'VIEW');
  perform public.grant_right(r_cuenta::uuid, a_isaac, 'VIEW');

  r_salon := (public.create_resource(c_sinai::uuid, 'other', 'Salón Monte Sinaí R2K'))->>'resource_id';
  perform public.grant_right(r_salon::uuid, c_sinai::uuid, 'MANAGE');
  perform public.grant_right(r_salon::uuid, a_jose, 'VIEW');
  perform public.grant_right(r_salon::uuid, a_david, 'VIEW');
  perform public.grant_right(r_salon::uuid, a_daniel, 'VIEW');

  if (select count(*) from public.resources where display_name like '%R2K' and archived_at is null) <> 5 then
    raise exception 'R2K 4 FAIL: los recursos no son únicos (hay % con sufijo R2K)',
      (select count(*) from public.resources where display_name like '%R2K');
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.resource_detail(r_casa::uuid);
  perform public.resource_detail(r_terreno::uuid);
  perform public.resource_detail(r_cuenta::uuid);
  perform public.resource_detail(r_salon::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_linda::text)::text, true);
  perform public.resource_detail(r_acciones::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_banco::text)::text, true);
  perform public.resource_detail(r_acciones::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin perform public.resource_detail(r_terreno::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 4 FAIL: Isaac ve Terreno Valle sin rights'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_caught := false;
  begin perform public.resource_detail(r_cuenta::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 4 FAIL: Daniel ve la Cuenta del Viaje sin rights'; end if;

  -- ═══ 5. CENA FLOW ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.create_rule(c_cena::uuid, 'Multa por llegar tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": ">", "field": "minutes_late", "value": 15}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine", "amount": 100, "currency": "MXN", "reason": "late_arrival"}]'::jsonb);
  perform public.create_rule(c_cena::uuid, 'Multa por cancelar mismo día',
    p_trigger_event_type := 'event.participation_cancelled',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": "=", "field": "same_day_cancellation", "value": true}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine", "amount": 300, "currency": "MXN", "reason": "same_day_cancellation"}]'::jsonb);

  v_starts := now() - interval '21 minutes';
  v_event := (public.create_calendar_event(c_cena::uuid, 'Cena miércoles', 'dinner',
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_starts + interval '3 hours',
    p_timezone := 'America/Mexico_City', p_host_actor_id := a_david,
    p_client_id := 'r2k-cena-001'))->>'event_id';

  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.check_in_participant(v_event::uuid, p_checked_in_at := v_starts);
  perform public.check_in_participant(v_event::uuid, a_jose, v_starts + interval '5 minutes');
  perform public.check_in_participant(v_event::uuid, a_isaac, v_starts + interval '12 minutes');
  perform public.cancel_participation(v_event::uuid, a_daniel, v_starts);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.check_in_participant(v_event::uuid);

  if (select count(*) from public.obligations where context_actor_id = c_cena::uuid and obligation_type = 'fine') <> 2
     or not exists (select 1 from public.obligations where context_actor_id = c_cena::uuid and debtor_actor_id = a_moises and amount = 100 and obligation_type = 'fine')
     or not exists (select 1 from public.obligations where context_actor_id = c_cena::uuid and debtor_actor_id = a_daniel and amount = 300 and obligation_type = 'fine')
     or exists (select 1 from public.obligations where context_actor_id = c_cena::uuid and obligation_type = 'fine'
                and debtor_actor_id in (a_jose, a_david, a_isaac)) then
    raise exception 'R2K 5 FAIL: multas incorrectas';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.evaluate_rules_for_event(c_cena::uuid, 'event.checked_in', a_moises,
    jsonb_build_object('minutes_late', 21, 'status', 'late', 'event_type', 'dinner'), v_event::uuid);
  if (select count(*) from public.obligations where context_actor_id = c_cena::uuid and obligation_type = 'fine') <> 2 then
    raise exception 'R2K 5 FAIL: re-evaluar duplicó multas';
  end if;

  -- ═══ 6. EXPENSE CENA + JUEGO ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.record_expense(c_cena::uuid, 1300, 'MXN', 'Pizza, cerveza y botanas',
    p_split_with := array[a_david, a_jose, a_isaac, a_moises],
    p_event_id := v_event::uuid, p_client_id := 'r2k-cena-expense-001',
    p_excluded_actor_ids := array[a_daniel]);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.record_game_result(c_cena::uuid, v_event::uuid, 'Catan', a_moises, a_daniel, 250, 'MXN', 'r2k-catan-001');

  if (select count(*) from public.obligations where context_actor_id = c_cena::uuid
      and obligation_type = 'expense_share' and creditor_actor_id = a_david and amount = 325) <> 3
     or exists (select 1 from public.obligations where debtor_actor_id = a_david and creditor_actor_id = a_david)
     or exists (select 1 from public.obligations where context_actor_id = c_cena::uuid
                and debtor_actor_id = a_daniel and creditor_actor_id = a_david)
     or not exists (select 1 from public.obligations where context_actor_id = c_cena::uuid
                    and debtor_actor_id = a_daniel and creditor_actor_id = a_moises
                    and obligation_type = 'game_debt' and amount = 250) then
    raise exception 'R2K 6 FAIL: gastos/juego incorrectos';
  end if;

  -- ═══ 7. SETTLEMENT CENA ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.generate_settlement_batch(c_cena::uuid, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  if exists (select 1 from public.settlement_items where settlement_batch_id = v_batch and from_actor_id = to_actor_id)
     or exists (select 1 from public.settlement_items where settlement_batch_id = v_batch and amount <= 0) then
    raise exception 'R2K 7 FAIL: settlement con self-pagos o montos inválidos';
  end if;
  for v_item in select id from public.settlement_items where settlement_batch_id = v_batch and status = 'pending' loop
    perform public.mark_settlement_paid(v_item.id);
    v_result := public.mark_settlement_paid(v_item.id);
    if not coalesce((v_result->>'already_paid')::boolean, false) then
      raise exception 'R2K 7 FAIL: mark_settlement_paid no es idempotente';
    end if;
  end loop;
  if (select count(*) from public.obligations where context_actor_id = c_cena::uuid and status = 'open') <> 0 then
    raise exception 'R2K 7 FAIL: quedaron obligations abiertas en la cena tras el settlement';
  end if;

  -- ═══ 8. CASA VALLE RESERVATIONS ═══
  insert into public.resource_reservations (resource_id, context_actor_id, requested_by_actor_id, reserved_for_actor_id, starts_at, ends_at, status) values
    (r_casa::uuid, c_familia::uuid, a_david, a_david, now() - interval '60 days', now() - interval '58 days', 'completed'),
    (r_casa::uuid, c_familia::uuid, a_david, a_david, now() - interval '30 days', now() - interval '28 days', 'completed');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_res_david := (public.request_resource_reservation(r_casa::uuid, c_familia::uuid,
    '2026-07-10 16:00-06'::timestamptz, '2026-07-12 18:00-06'::timestamptz,
    p_client_id := 'r2k-res-david-001'))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_res_isaac := (public.request_resource_reservation(r_casa::uuid, c_familia::uuid,
    '2026-07-10 16:00-06'::timestamptz, '2026-07-12 18:00-06'::timestamptz))->>'reservation_id';

  select * into v_conflict from public.reservation_conflicts
   where resource_id = r_casa::uuid and resolution_status = 'open' limit 1;
  if v_conflict.recommended_winner_actor_id is distinct from a_isaac then
    raise exception 'R2K 8 FAIL: least_recent_use_wins no recomendó a Isaac';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  perform public.resolve_reservation_conflict(v_conflict.id, v_res_isaac::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.confirm_reservation(v_res_isaac::uuid);
  if (select status from public.resource_reservations where id = v_res_isaac::uuid) <> 'confirmed'
     or (select status from public.resource_reservations where id = v_res_david::uuid) <> 'rejected' then
    raise exception 'R2K 8 FAIL: resolución de conflicto incorrecta';
  end if;
  if exists (
    select 1 from public.resource_reservations a
    join public.resource_reservations b on b.resource_id = a.resource_id and b.id > a.id
     and tstzrange(a.starts_at, a.ends_at) && tstzrange(b.starts_at, b.ends_at)
    where a.resource_id = r_casa::uuid
      and a.status in ('approved', 'confirmed') and b.status in ('approved', 'confirmed')
  ) then
    raise exception 'R2K 8 FAIL: reservaciones traslapadas approved/confirmed';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  v_caught := false;
  begin perform public.request_resource_reservation(r_casa::uuid, c_familia::uuid,
    now() + interval '30 days', now() + interval '32 days');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 8 FAIL: Moisés (VIEW) pudo reservar'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin perform public.request_resource_reservation(r_casa::uuid, c_familia::uuid,
    now() + interval '30 days', now() + interval '32 days');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 8 FAIL: Outsider pudo reservar'; end if;

  -- ═══ 9. VIAJE JAPÓN ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.record_expense(c_viaje::uuid, 30000, 'MXN', 'Hotel Tokio',
    p_split_with := array[a_jose, a_david, a_isaac], p_client_id := 'r2k-hotel-001');

  if (select count(*) from public.obligations where context_actor_id = c_viaje::uuid
      and obligation_type = 'expense_share' and creditor_actor_id = a_jose and amount = 10000) <> 2
     or exists (select 1 from public.obligations where context_actor_id = c_viaje::uuid
                and debtor_actor_id in (a_daniel, a_moises)) then
    raise exception 'R2K 9 FAIL: gasto del viaje incorrecto o contaminado';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  if public.is_context_member(c_viaje::uuid) then
    raise exception 'R2K 9 FAIL: Daniel es miembro del Viaje';
  end if;
  v_caught := false;
  begin perform public.context_summary(c_viaje::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 9 FAIL: Daniel ve el Viaje'; end if;

  -- ═══ 10. NEGOCIO VALLE ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_decision := (public.create_decision(c_negocio::uuid, 'expense_approval',
    '¿Invertimos $100,000 MXN en permisos?',
    p_payload := '{"amount": 100000, "currency": "MXN"}'::jsonb,
    p_client_id := 'r2k-decision-001'))->>'decision_id';
  perform public.vote_decision(v_decision::uuid, 'approve');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.vote_decision(v_decision::uuid, 'approve');
  if v_result->>'status' <> 'approved' then
    raise exception 'R2K 10 FAIL: decisión del negocio no aprobada';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.execute_decision(v_decision::uuid);

  insert into public.obligations (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type, amount, currency, status, source_decision_id, metadata) values
    (c_negocio::uuid, a_jose, c_negocio::uuid, 'contribution', 50000, 'MXN', 'open', v_decision::uuid, '{"reason": "inversión permisos"}'),
    (c_negocio::uuid, a_david, c_negocio::uuid, 'contribution', 50000, 'MXN', 'open', v_decision::uuid, '{"reason": "inversión permisos"}');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin perform public.context_summary(c_negocio::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 10 FAIL: Isaac ve el Negocio'; end if;
  if (select count(*) from public.resources where display_name = 'Terreno Valle R2K') <> 1 then
    raise exception 'R2K 10 FAIL: el Terreno se duplicó';
  end if;

  -- ═══ 11. COMUNIDADES ═══
  insert into public.obligations (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type, amount, currency, status, metadata) values
    (c_sinai::uuid, a_jose, c_sinai::uuid, 'dues', 1800, 'MXN', 'open', '{"reason": "cuota evento"}'),
    (c_sinai::uuid, a_david, c_sinai::uuid, 'dues', 1800, 'MXN', 'open', '{"reason": "cuota evento"}'),
    (c_sinai::uuid, a_daniel, c_sinai::uuid, 'dues', 1800, 'MXN', 'open', '{"reason": "cuota evento"}'),
    (c_maguen::uuid, a_isaac, c_maguen::uuid, 'dues', 500, 'MXN', 'open', '{"reason": "cuota evento"}'),
    (c_maguen::uuid, a_moises, c_maguen::uuid, 'dues', 500, 'MXN', 'open', '{"reason": "cuota evento"}');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_caught := false;
  begin perform public.context_summary(c_maguen::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 11 FAIL: José ve Maguén David'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin perform public.context_summary(c_sinai::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 11 FAIL: Isaac ve Monte Sinaí'; end if;
  if exists (select 1 from public.obligations where context_actor_id = c_sinai::uuid and debtor_actor_id in (a_isaac, a_moises))
     or exists (select 1 from public.obligations where context_actor_id = c_maguen::uuid and debtor_actor_id in (a_jose, a_david, a_daniel)) then
    raise exception 'R2K 11 FAIL: cuotas mezcladas entre comunidades';
  end if;

  -- ═══ 12. TRUST FAMILIAR ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_banco::text)::text, true);
  perform public.resource_detail(r_acciones::uuid);
  perform public.context_summary(c_trust::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_linda::text)::text, true);
  perform public.resource_detail(r_acciones::uuid);
  v_caught := false;
  begin perform public.grant_right(r_acciones::uuid, a_linda, 'SELL');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 12 FAIL: Linda (beneficiary) pudo auto-otorgarse SELL'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.context_summary(c_trust::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin perform public.context_summary(c_trust::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 12 FAIL: Outsider ve el Trust'; end if;
  if (select count(*) from public.resources where display_name = 'Acciones Quimibond R2K') <> 1 then
    raise exception 'R2K 12 FAIL: las Acciones se duplicaron';
  end if;

  -- ═══ 13. PERSON CONTEXT / MY WORLD (José) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_world := public.my_world();

  if (select count(*) from jsonb_array_elements(v_world->'contexts') c
      where (c->>'context_actor_id')::uuid in (c_cena::uuid, c_viaje::uuid, c_familia::uuid, c_negocio::uuid, c_sinai::uuid, c_trust::uuid)) <> 6
     or exists (select 1 from jsonb_array_elements(v_world->'contexts') c
                where (c->>'context_actor_id')::uuid = c_maguen::uuid) then
    raise exception 'R2K 13 FAIL: my_world contextos incorrectos';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_world->'resources') r2
                 where (r2->>'resource_id')::uuid = r_casa::uuid and r2->'reasons' ? 'USE')
     or not exists (select 1 from jsonb_array_elements(v_world->'resources') r2
                    where (r2->>'resource_id')::uuid = r_terreno::uuid and r2->'reasons' ? 'OWN')
     or not exists (select 1 from jsonb_array_elements(v_world->'resources') r2
                    where (r2->>'resource_id')::uuid = r_cuenta::uuid and r2->'reasons' ? 'VIEW')
     or not exists (select 1 from jsonb_array_elements(v_world->'resources') r2
                    where (r2->>'resource_id')::uuid = r_salon::uuid and r2->'reasons' ? 'VIEW') then
    raise exception 'R2K 13 FAIL: my_world recursos/reasons incorrectos';
  end if;
  if (select count(*) from jsonb_array_elements(v_world->'resources') r2)
     <> (select count(distinct r2->>'resource_id') from jsonb_array_elements(v_world->'resources') r2) then
    raise exception 'R2K 13 FAIL: my_world duplica recursos';
  end if;
  if exists (select 1 from jsonb_array_elements(v_world->'resources') r2
             where (r2->>'resource_id')::uuid = r_acciones::uuid) then
    raise exception 'R2K 13 FAIL: my_world filtra recursos del Trust a un observer';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_world->'open_obligations') o
                 where (o->>'context_actor_id')::uuid = c_viaje::uuid and o->>'role' = 'creditor')
     or not exists (select 1 from jsonb_array_elements(v_world->'open_obligations') o
                    where (o->>'context_actor_id')::uuid = c_negocio::uuid and o->>'role' = 'debtor')
     or not exists (select 1 from jsonb_array_elements(v_world->'open_obligations') o
                    where (o->>'context_actor_id')::uuid = c_sinai::uuid and o->>'role' = 'debtor')
     or exists (select 1 from jsonb_array_elements(v_world->'open_obligations') o
                where (o->>'context_actor_id')::uuid in (c_maguen::uuid, c_cena::uuid)) then
    raise exception 'R2K 13 FAIL: my_world obligations incorrectas';
  end if;

  -- ═══ 14. ACTIVITY GLOBAL ═══
  foreach v_type in array array[
    'context.created', 'membership.joined', 'resource.created', 'right.granted',
    'event.created', 'event.rsvp_updated', 'event.checked_in', 'event.participation_cancelled',
    'rule.created', 'rule.evaluated', 'fine.created', 'obligation.created',
    'expense.recorded', 'split.generated',
    'reservation.requested', 'reservation.conflict_detected', 'reservation.conflict_resolved',
    'decision.created', 'decision.vote_cast', 'decision.executed',
    'settlement.generated', 'settlement.paid'
  ] loop
    if not exists (
      select 1 from public.activity_events
      where event_type = v_type
        and (context_actor_id in (c_cena::uuid, c_viaje::uuid, c_familia::uuid, c_negocio::uuid, c_sinai::uuid, c_maguen::uuid, c_trust::uuid)
             or actor_id in (a_jose, a_david, a_isaac, a_moises, a_daniel, a_abuelo, a_linda, a_banco))
    ) then
      v_missing := v_missing || v_type;
    end if;
  end loop;
  if array_length(v_missing, 1) > 0 then
    raise exception 'R2K 14 FAIL: faltan activities: %', v_missing;
  end if;

  if exists (
    select 1 from public.activity_events ae
    where ae.context_actor_id in (c_cena::uuid, c_viaje::uuid, c_familia::uuid, c_negocio::uuid, c_sinai::uuid, c_maguen::uuid, c_trust::uuid)
      and (not exists (select 1 from public.actors a where a.id = ae.context_actor_id)
        or (ae.actor_id is not null and not exists (select 1 from public.actors a where a.id = ae.actor_id)))
  ) then
    raise exception 'R2K 14 FAIL: activity con referencias inexistentes';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  if jsonb_array_length((public.list_activity(c_cena::uuid))->'activity') = 0 then
    raise exception 'R2K 14 FAIL: list_activity vacío para un miembro';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin perform public.list_activity(c_cena::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 14 FAIL: el Outsider listó activity ajena'; end if;

  -- ═══ 15. AUTH / PRIVACY FINAL ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin perform public.rsvp_event(v_event::uuid, 'going');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 15 FAIL: Outsider pudo RSVP'; end if;
  v_caught := false;
  begin perform public.vote_decision(v_decision::uuid, 'approve');
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2K 15 FAIL: Outsider pudo votar'; end if;
  v_caught := false;
  begin perform public.record_expense(c_cena::uuid, 100, 'MXN', 'hack');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 15 FAIL: Outsider registró gasto'; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin perform public.record_expense(c_cena::uuid, 100, 'MXN', 'por otro', p_paid_by_actor_id := a_david);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 15 FAIL: Isaac registró gasto como David'; end if;
  v_caught := false;
  begin perform public.check_in_participant(v_event::uuid, a_moises);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2K 15 FAIL: Isaac hizo check-in por otro'; end if;
  v_caught := false;
  begin perform public.grant_right(r_casa::uuid, a_isaac, 'OWN', 100);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 15 FAIL: Isaac se auto-otorgó OWN'; end if;

  -- ═══ 16. IDEMPOTENCIA GLOBAL ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  if ((public.create_calendar_event(c_cena::uuid, 'Cena miércoles', 'dinner',
        p_location_text := 'Por definir', p_starts_at := v_starts, p_client_id := 'r2k-cena-001'))->>'event_id')::uuid is distinct from v_event::uuid then
    raise exception 'R2K 16 FAIL: create_event no es idempotente';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.record_expense(c_cena::uuid, 1300, 'MXN', 'Pizza, cerveza y botanas',
    p_split_with := array[a_david, a_jose, a_isaac, a_moises],
    p_event_id := v_event::uuid, p_client_id := 'r2k-cena-expense-001',
    p_excluded_actor_ids := array[a_daniel]);
  if not coalesce((v_result->>'idempotent_replay')::boolean, false) then
    raise exception 'R2K 16 FAIL: record_expense no es idempotente';
  end if;
  if ((public.request_resource_reservation(r_casa::uuid, c_familia::uuid,
        '2026-07-10 16:00-06'::timestamptz, '2026-07-12 18:00-06'::timestamptz,
        p_client_id := 'r2k-res-david-001'))->>'reservation_id')::uuid is distinct from v_res_david::uuid then
    raise exception 'R2K 16 FAIL: request_reservation no es idempotente';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  if ((public.create_decision(c_negocio::uuid, 'expense_approval', '¿Invertimos $100,000 MXN en permisos?',
        p_client_id := 'r2k-decision-001'))->>'decision_id')::uuid is distinct from v_decision::uuid then
    raise exception 'R2K 16 FAIL: create_decision no es idempotente';
  end if;
  v_caught := false;
  begin perform public.generate_settlement_batch(c_cena::uuid, 'MXN');
  exception when others then v_caught := true; end;
  if not v_caught then
    if (select count(*) from public.settlement_batches where context_actor_id = c_cena::uuid and currency = 'MXN') > 1 then
      raise exception 'R2K 16 FAIL: generate_settlement_batch duplicó batches';
    end if;
  end if;
  if exists (
    select client_id from public.money_transactions
    where context_actor_id in (c_cena::uuid, c_viaje::uuid, c_negocio::uuid) and client_id is not null
    group by client_id having count(*) > 1
  ) then
    raise exception 'R2K 16 FAIL: transactions duplicadas por client_id';
  end if;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  delete from public.actor_relationships where subject_actor_id in (a_jose, a_david, a_isaac, a_moises, a_daniel, a_abuelo, a_linda, a_banco);
  perform public._r2_cleanup_context(c_trust::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(c_maguen::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(c_sinai::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(c_negocio::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(c_viaje::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(c_familia::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(c_cena::uuid,
    array[a_jose, a_david, a_isaac, a_moises, a_daniel, a_abuelo, a_linda, a_banco, a_out],
    array[u_jose, u_david, u_isaac, u_moises, u_daniel, u_abuelo, u_linda, u_banco, u_out]);

  raise notice 'R.2K FULL REALITY + AUTH SIMULATION: PASS — Backend MVP 2.0 validado end-to-end. Ruul soporta realidad multi-contexto con auth, resources únicos, rights, memberships, events, rules, reservations, decisions, money, settlement y activity sin leaks.';
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_r2t_decision_resolves_conflict()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_jose uuid; a_jose uuid;
  u_papa uuid; a_papa uuid;
  u_abu uuid;  a_abu uuid;
  v_ctx uuid;
  v_palco uuid;
  v_event uuid;
  v_starts timestamptz := now() + interval '50 days';
  v_ends   timestamptz := now() + interval '50 days' + interval '3 hours';
  v_resv1 uuid; v_resv2 uuid;
  v_conflict uuid;
  v_decision uuid;
  v_winner_opt text;
  v_status text;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('R2T José rslv2', '+5210000241');
  select auth_id, actor_id into u_papa, a_papa from public._r2_make_person('R2T Papá rslv2', '+5210000242');
  select auth_id, actor_id into u_abu,  a_abu  from public._r2_make_person('R2T Abuelo rslv2', '+5210000243');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('R2T Mizrahi Resolve2', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx, a_papa);
  perform public.invite_member(v_ctx, a_abu);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abu::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_palco := (public.create_resource(v_ctx, 'house', 'Palco Azteca R2T Resolve2'))->>'resource_id';
  perform public.grant_right(v_palco, v_ctx, 'MANAGE');
  perform public.grant_right(v_palco, a_papa, 'USE');
  perform public.grant_right(v_palco, a_abu, 'USE');

  v_event := (public.create_calendar_event(
    p_context_actor_id := v_ctx,
    p_title := 'México vs Brasil (resolve2)',
    p_event_type := 'community_event',
    p_location_text := 'Por definir', p_starts_at := v_starts,
    p_ends_at := v_ends,
    p_invite_all_members := false))->>'event_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  v_resv1 := (public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_papa,
    p_source_event_id := v_event::uuid))->>'reservation_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abu::text)::text, true);
  v_resv2 := (public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_abu,
    p_source_event_id := v_event::uuid))->>'reservation_id';

  select id into v_conflict from public.reservation_conflicts
    where resource_id = v_palco and resolution_status = 'open'
      and (reservation_a_id = v_resv2::uuid or reservation_b_id = v_resv2::uuid)
    limit 1;
  if v_conflict is null then
    raise exception 'R2T smoke 5: no se produjo conflict para resolver';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_decision := (public.resolve_reservation_conflict(v_conflict, 'requires_decision'))->>'decision_id';

  select case when (payload->'option_reservations'->>'res_a')::uuid = v_resv1::uuid then 'res_a' else 'res_b' end
    into v_winner_opt
    from public.decisions where id = v_decision;

  -- Patrón R.2S contract: 2 votos sólo, después execute_decision (sin votar 3ro
  -- porque tras 2 votos a favor la decision auto-finaliza y la 3ra raise 22023).
  perform public.vote_decision(v_decision, 'approve', v_winner_opt);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  perform public.vote_decision(v_decision, 'approve', v_winner_opt);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.execute_decision(v_decision);

  select resolution_status into v_status
    from public.reservation_conflicts where id = v_conflict;
  if v_status <> 'resolved' then
    raise exception 'R2T smoke 5: conflict no quedó resolved, got %', v_status;
  end if;

  raise notice 'R2T smoke 5 OK: decision % resolvió conflict %', v_decision, v_conflict;
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_r2t_event_with_reservations()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_jose uuid; a_jose uuid;
  u_papa uuid; a_papa uuid;
  u_abu uuid;  a_abu uuid;
  u_pepe uuid; a_pepe uuid;
  v_ctx uuid;
  v_palco uuid;
  v_event uuid;
  v_starts timestamptz := now() + interval '30 days';
  v_ends   timestamptz := now() + interval '30 days' + interval '3 hours';
  v_count int;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('R2T José', '+5210000211');
  select auth_id, actor_id into u_papa, a_papa from public._r2_make_person('R2T Papá', '+5210000212');
  select auth_id, actor_id into u_abu,  a_abu  from public._r2_make_person('R2T Abuelo', '+5210000213');
  select auth_id, actor_id into u_pepe, a_pepe from public._r2_make_person('R2T Pepe', '+5210000214');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('R2T Mizrahi Mundial', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx, a_papa);
  perform public.invite_member(v_ctx, a_abu);
  perform public.invite_member(v_ctx, a_pepe);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abu::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_pepe::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_palco := (public.create_resource(v_ctx, 'house', 'Palco Azteca R2T'))->>'resource_id';
  perform public.grant_right(v_palco, v_ctx, 'MANAGE');
  perform public.grant_right(v_palco, a_papa, 'USE');
  perform public.grant_right(v_palco, a_abu, 'USE');
  perform public.grant_right(v_palco, a_pepe, 'USE');

  v_event := (public.create_calendar_event(
    p_context_actor_id := v_ctx,
    p_title := 'México vs Brasil',
    p_event_type := 'community_event',
    p_location_text := 'Por definir', p_starts_at := v_starts,
    p_ends_at := v_ends,
    p_invite_all_members := true))->>'event_id';

  perform public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_jose,
    p_metadata := jsonb_build_object('seats', 1),
    p_source_event_id := v_event::uuid);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  perform public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_papa,
    p_metadata := jsonb_build_object('seats', 2),
    p_source_event_id := v_event::uuid);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abu::text)::text, true);
  perform public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_abu,
    p_metadata := jsonb_build_object('seats', 2),
    p_source_event_id := v_event::uuid);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_pepe::text)::text, true);
  perform public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_pepe,
    p_metadata := jsonb_build_object('seats', 2),
    p_source_event_id := v_event::uuid);

  select count(*) into v_count
    from public.resource_reservations
    where source_event_id = v_event::uuid;
  if v_count <> 4 then
    raise exception 'R2T smoke 3: esperaba 4 reservations con source_event_id, got %', v_count;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='calendar_events' and column_name='reservation_ids'
  ) then
    raise exception 'R2T smoke 3: calendar_events tiene columna reservation_ids (violación doctrinal)';
  end if;

  raise notice 'R2T smoke 3 OK: event % con 4 reservations vía source_event_id', v_event;
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_r2t_event_without_reservation()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u uuid; a uuid;
  v_ctx uuid;
  v_event uuid;
  v_count int;
begin
  select auth_id, actor_id into u, a from public._r2_make_person('R2T evt-only', '+5210000201');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u::text)::text, true);

  v_ctx := (public.create_context('R2T Familia EvtOnly', 'collective', 'family'))->>'context_actor_id';

  v_event := (public.create_calendar_event(
    p_context_actor_id := v_ctx,
    p_title := 'Comida Miércoles',
    p_event_type := 'dinner',
    p_location_text := 'Por definir', p_starts_at := now() + interval '7 days',
    p_ends_at := now() + interval '7 days' + interval '2 hours',
    p_invite_all_members := false))->>'event_id';

  if v_event is null then
    raise exception 'R2T smoke 1: create_calendar_event no devolvió event_id';
  end if;

  select count(*) into v_count
    from public.resource_reservations
    where source_event_id = v_event::uuid;
  if v_count <> 0 then
    raise exception 'R2T smoke 1: event sin reservation tiene % filas en resource_reservations', v_count;
  end if;

  raise notice 'R2T smoke 1 OK: event % existe sin reservations', v_event;
end; $function$
;

CREATE OR REPLACE FUNCTION public._smoke_r2t_reservation_conflict_world_cup()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_jose uuid; a_jose uuid;
  u_papa uuid; a_papa uuid;
  v_ctx uuid;
  v_palco uuid;
  v_event uuid;
  v_starts timestamptz := now() + interval '40 days';
  v_ends   timestamptz := now() + interval '40 days' + interval '3 hours';
  v_resv1 uuid; v_resv2 uuid;
  v_conflicts int;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('R2T José conflict', '+5210000221');
  select auth_id, actor_id into u_papa, a_papa from public._r2_make_person('R2T Papá conflict', '+5210000222');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('R2T Mizrahi Conflict', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx, a_papa);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_palco := (public.create_resource(v_ctx, 'house', 'Palco Azteca R2T Conflict'))->>'resource_id';
  perform public.grant_right(v_palco, v_ctx, 'MANAGE');
  perform public.grant_right(v_palco, a_papa, 'USE');

  v_event := (public.create_calendar_event(
    p_context_actor_id := v_ctx,
    p_title := 'México vs Brasil (conflict)',
    p_event_type := 'community_event',
    p_location_text := 'Por definir', p_starts_at := v_starts,
    p_ends_at := v_ends,
    p_invite_all_members := false))->>'event_id';

  v_resv1 := (public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_jose,
    p_source_event_id := v_event::uuid))->>'reservation_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  v_resv2 := (public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_papa,
    p_source_event_id := v_event::uuid))->>'reservation_id';

  select count(*) into v_conflicts
    from public.reservation_conflicts
    where resource_id = v_palco
      and resolution_status = 'open'
      and (reservation_a_id = v_resv1::uuid or reservation_b_id = v_resv1::uuid
        or reservation_a_id = v_resv2::uuid or reservation_b_id = v_resv2::uuid);
  if v_conflicts < 1 then
    raise exception 'R2T smoke 4: esperaba >=1 reservation_conflict, got %', v_conflicts;
  end if;

  raise notice 'R2T smoke 4 OK: % conflict(s) detectado(s) por overlap', v_conflicts;
end; $function$
;