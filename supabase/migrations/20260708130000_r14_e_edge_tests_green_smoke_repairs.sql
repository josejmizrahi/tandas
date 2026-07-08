-- R.14.E — Fix del smoke _smoke_mvp2_cancel_after_checkin post seed rules.
--
-- edge-tests lleva rojo en main desde que R.14 (r14_seed_friend_group_rules)
-- siembra 2 reglas automáticas en todo contexto friend_group nuevo: el smoke
-- FE.9 crea un friend_group, hace check-in 60 min tarde → la seed rule
-- late_15min genera una multa automática (obligations.source_event_id → FK
-- al evento) y el cleanup del smoke intenta borrar el calendar_event antes
-- de borrar la multa → viola obligations_source_event_id_fkey.
--
-- Fix: el cleanup borra primero las obligations del contexto (la multa es
-- producto esperado del motor R.6 + seed rules — el smoke no debe evitarla,
-- solo limpiarla). rules y rule_attention_items cascadean al borrar el actor
-- del contexto; no necesitan delete explícito.
--
-- El cuerpo del smoke es idéntico al de FE.9 (20260612213000) salvo el bloque
-- de cleanup.

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
  -- R.14: las seed rules del friend_group generan multa automática por el
  -- check-in tarde (source_event_id → FK). Borrarla antes que el evento.
  delete from public.obligations where context_actor_id = v_ctx;
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


-- ────────────────────────────────────────────────────────────────────────────
-- 2. _smoke_mvp2_contract — opt-out de seed rules R.14.
--
-- El smoke asserta montos exactos (neteo de Linda = 400) y active_rules = 1;
-- las 2 seed rules del friend_group agregan una multa de $30 extra y suben el
-- conteo a 3. El smoke fija su propio mundo de reglas → usa el opt-out
-- explícito `metadata.r14_skip_seed_rules` que R.14 dejó para estos casos.
-- Cuerpo idéntico al de r9_g (20260611107000) salvo el create_context.
-- ────────────────────────────────────────────────────────────────────────────

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
  v_ctx := (public.create_context('_contract Cena de los Jueves', 'collective', 'friend_group',
    p_metadata := '{"r14_skip_seed_rules": true}'::jsonb))->>'context_actor_id';

  -- ═══ 3. Linda se une ═══
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- ═══ 4. Regla de multa ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  perform public.create_rule(v_ctx::uuid, '_contract Multa por tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": ">", "field": "minutes_late", "value": 15}]}'::jsonb,
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
    -- R.5Z handshake: José (acreedor/admin) confirma cada pago; los cierres
    -- los reporta la confirmación
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
    v_result := public.confirm_settlement_paid(r.id);
    v_total_closed := v_total_closed + coalesce((v_result->>'obligations_closed')::integer, 0);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
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
end; $function$;

revoke all on function public._smoke_mvp2_contract() from public, anon, authenticated;


-- ────────────────────────────────────────────────────────────────────────────
-- 3. Drop del overload legacy de update_calendar_event (raíz del rojo en
--    edge-tests desde 2026-06-16).
--
-- r12_f (20260616020500) agregó la firma de 9 params (+ p_metadata jsonb
-- default null) SIN dropear la de 8 params de f_event_7 (20260604090000).
-- Cualquier llamada que no fije los 9 args — p.ej. el smoke
-- _smoke_f_event_7_update_calendar_event(uuid, text, text) — es ambigua:
-- "function public.update_calendar_event(uuid, unknown, unknown) is not
-- unique". La firma nueva es superset estricto (p_metadata default null),
-- así que la vieja sobra. Mismo criterio que audit_13 (consolidación de
-- overloads legacy).
drop function if exists public.update_calendar_event(
  uuid, text, text, timestamptz, timestamptz, text, boolean, text);


-- ────────────────────────────────────────────────────────────────────────────
-- 4. _smoke_mvp2_m5_calendar + _smoke_mvp2_m8_rules — opt-out de seed rules.
--
-- m5: el check-in tarde dispara la seed fine ($30) cuyo source_event_id
--     bloquea el `delete from calendar_events` del cleanup.
-- m8: asserta montos exactos de multa ($100 tarde / $300 same-day) que la
--     seed fine de $30 contaminaría.
-- Ambos smokes fijan su propio mundo de reglas → mismo opt-out explícito que
-- el contract smoke. Cuerpos idénticos a r5pre (20260605000003) salvo el
-- create_context.
-- ────────────────────────────────────────────────────────────────────────────

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
  v_result := public.create_context('_smoke_m5 Cena', 'collective', 'friend_group',
    p_metadata := '{"r14_skip_seed_rules": true}'::jsonb);
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
end; $function$;

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
  v_ctx := (public.create_context('_smoke_m8 Cena', 'collective', 'friend_group',
    p_metadata := '{"r14_skip_seed_rules": true}'::jsonb))->>'context_actor_id';
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
end; $function$;


-- ────────────────────────────────────────────────────────────────────────────
-- 5. _smoke_mvp2_m6_reservations — Caso 5 alineado a R.RES.POLICY.
--
-- R.RES.POLICY.E (20260617130000) valida min_duration_units al solicitar:
-- una casa (real_estate, granularity=day, min 1) ya no acepta reservas de
-- 12 horas → 'duration_below_minimum: 0.5ud'. El Caso 5 (EXCLUDE constraint
-- al aprobar traslape) ahora usa 1 día completo (día 5 → día 6), que cumple
-- la policy y sigue traslapando la reserva aprobada (días 5 → 7).
-- Cuerpo idéntico a r9_g (20260611107000) salvo esa ventana.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._smoke_mvp2_m6_reservations()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_ctx uuid; v_house uuid;
  v_result jsonb; v_res_a uuid; v_res_b uuid; v_conflict uuid; v_code text;
  v_caught boolean;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M6A', '+520000000012', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M6B', '+520000000013', null);

  -- Setup: contexto familia + casa + B como member CON USE right (R.2F rights-based)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_m6 Familia', 'collective', 'family'))->>'context_actor_id';
  v_house := (public.create_resource(v_ctx::uuid, 'house', '_smoke_m6 Casa Lago'))->>'resource_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  -- R.2F: reservar requiere USE/MANAGE/OWN → A (admin del contexto dueño) otorga USE a B
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.grant_right(v_house::uuid, v_b, 'USE');

  -- Caso 1: A solicita reservación del fin de semana (autoridad sobre el contexto dueño)
  v_result := public.request_resource_reservation(
    v_house::uuid, v_ctx::uuid,
    now() + interval '5 days', now() + interval '7 days');
  v_res_a := (v_result->>'reservation_id')::uuid;
  if v_res_a is null then raise exception 'mvp2_m6 Caso1: request falló'; end if;

  -- Caso 2: B solicita el MISMO fin de semana → conflicto detectado
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.request_resource_reservation(
    v_house::uuid, v_ctx::uuid,
    now() + interval '6 days', now() + interval '8 days');
  v_res_b := (v_result->>'reservation_id')::uuid;
  if (v_result->>'conflicts_detected')::integer < 1 then
    raise exception 'mvp2_m6 Caso2: conflicto no detectado';
  end if;

  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_house::uuid and resolution_status = 'open' limit 1;
  if v_conflict is null then raise exception 'mvp2_m6 Caso2: conflict row no existe'; end if;

  -- Caso 3: B (USE, sin MANAGE/OWN/GOVERN ni admin) NO puede resolver el conflicto
  v_caught := false;
  begin
    perform public.resolve_reservation_conflict(v_conflict, v_res_b);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'mvp2_m6 Caso3: member resolvió conflicto sin autoridad'; end if;

  -- Caso 4: A (admin) resuelve a favor de A → B queda rejected, A approved
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.resolve_reservation_conflict(v_conflict, v_res_a);
  if not exists (select 1 from public.resource_reservations where id = v_res_a and status = 'approved') then
    raise exception 'mvp2_m6 Caso4: ganador no quedó approved';
  end if;
  if not exists (select 1 from public.resource_reservations where id = v_res_b and status = 'rejected') then
    raise exception 'mvp2_m6 Caso4: perdedor no quedó rejected';
  end if;

  -- Caso 5: EXCLUDE constraint — aprobar otra reservación traslapada explota a nivel DB
  declare
    v_res_c uuid;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
    v_res_c := (public.request_resource_reservation(
      v_house::uuid, v_ctx::uuid,
      now() + interval '5 days', now() + interval '6 days'))->>'reservation_id';
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    v_caught := false;
    begin
      perform public.approve_reservation(v_res_c::uuid);
    exception when exclusion_violation then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m6 Caso5: EXCLUDE constraint no aplicó'; end if;
  end;

  -- Caso 6: anon sin acceso
  if has_table_privilege('anon', 'public.resource_reservations', 'SELECT')
     or has_function_privilege('anon', 'public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text, uuid)', 'EXECUTE') then
    raise exception 'mvp2_m6 Caso6: anon tiene acceso a reservaciones';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.reservation_conflicts where resource_id = v_house::uuid;
  delete from public.resource_reservations where resource_id = v_house::uuid;
  delete from public.resource_rights where resource_id = v_house::uuid;
  delete from public.resources where id = v_house::uuid;
  delete from public.context_invites where context_actor_id = v_ctx::uuid;
  delete from public.role_assignments where context_actor_id = v_ctx::uuid;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx::uuid;
  delete from public.roles where context_actor_id = v_ctx::uuid;
  delete from public.actor_memberships where context_actor_id = v_ctx::uuid;
  delete from public.actors where id = v_ctx::uuid;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_m6_reservations passed (6 casos, rights-based)';
end; $function$;


-- ────────────────────────────────────────────────────────────────────────────
-- 6. _smoke_r2e_rules_dod — opt-out de seed rules R.14.
--
-- El smoke asserta "0 multas antes de crear reglas" y montos exactos; las
-- seed rules del friend_group generan la multa de $30 en el primer check-in
-- tarde. Mismo opt-out explícito. Cuerpo idéntico a r9_g salvo create_context.
-- ────────────────────────────────────────────────────────────────────────────

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
  v_ctx := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group',
    p_metadata := '{"r14_skip_seed_rules": true}'::jsonb))->>'context_actor_id';
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

  -- R.6.A (20260608105005): la re-evaluación con la misma idempotency_key se
  -- dedupea ANTES de tocar consecuencias → resultado vacío y cero filas nuevas.
  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.checked_in', a_moises, v_payload, v_event::uuid);
  if (v_result->>'rules_matched')::integer <> 0
     or jsonb_array_length(v_result->'obligations_created') <> 0 then
    raise exception 'R2E FAIL 4: la re-evaluación de Moisés no fue dedupeada (R.6.A): %', v_result;
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and debtor_actor_id = a_moises) <> 1 then
    raise exception 'R2E FAIL 4: la re-evaluación duplicó la obligation de Moisés';
  end if;

  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.participation_cancelled', a_daniel,
    jsonb_build_object('same_day_cancellation', true, 'event_type', 'dinner'), v_event::uuid);
  if (v_result->>'rules_matched')::integer <> 0
     or jsonb_array_length(v_result->'obligations_created') <> 0 then
    raise exception 'R2E FAIL 4: la re-evaluación de Daniel no fue dedupeada (R.6.A): %', v_result;
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and debtor_actor_id = a_daniel) <> 1 then
    raise exception 'R2E FAIL 4: la re-evaluación duplicó la obligation de Daniel';
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
  -- R.6.A: las re-evaluaciones dedupeadas NO insertan filas nuevas
  if (select count(*) from public.rule_evaluations
      where context_actor_id = v_ctx::uuid and outcome = 'matched') <> 2 then
    raise exception 'R2E FAIL evaluaciones: esperaba 2 matched (Moisés + Daniel; re-evals dedupeadas)';
  end if;
  if (select count(*) from public.rule_evaluations
      where context_actor_id = v_ctx::uuid and outcome = 'not_matched') <> 2 then
    raise exception 'R2E FAIL evaluaciones: esperaba 2 not_matched (David + Isaac)';
  end if;

  -- activity_events: rule.evaluated, obligation.created, fine.created
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'rule.evaluated') <> 4 then
    raise exception 'R2E FAIL activity: rule.evaluated debe ser 4 (2 matched + 2 not_matched; re-evals dedupeadas R.6.A)';
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
end; $function$;


-- ────────────────────────────────────────────────────────────────────────────
-- 7. _smoke_r2h_money_expenses_dod — opt-out de seed rules R.14.
--
-- Asserta exactamente 2 multas open (regla propia $100 tarde + $300 same-day);
-- la seed fine de $30 por el check-in tarde de Moisés sube el conteo a 3.
-- Cuerpo idéntico a r9_e (20260611105000) salvo create_context.
-- ────────────────────────────────────────────────────────────────────────────

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
  v_ctx := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group',
    p_metadata := '{"r14_skip_seed_rules": true}'::jsonb))->>'context_actor_id';
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
  -- R.9.E: Daniel tiene obligaciones money abiertas (Catan $250 game_debt) — el
  -- nuevo exit guard de remove_member las bloquea; este smoke prueba el lockout
  -- post-remoción, así que usamos el override admin p_force => true.
  perform public.remove_member(v_ctx::uuid, a_daniel, 'prueba R2H', p_force => true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_caught := false;
  begin perform public.record_expense(v_ctx::uuid, 100, 'MXN', 'hack removido');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2H.6 FAIL: miembro removido registró gasto'; end if;

  -- (4) anon bloqueado (R.9.B: firma nueva de record_fine con p_client_id)
  foreach v_fn in array array[
    -- R.9.E fix de paso: R.9.C (20260611102000) dropeó la firma 12-arg de
    -- record_expense y creó la 14-arg (+p_event_id_for_split, +p_split_strategy)
    -- sin actualizar este check → has_function_privilege lanzaba 42883.
    'public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[], uuid, text)',
    'public.record_game_result(uuid, uuid, text, uuid, uuid, numeric, text, text)',
    'public.record_fine(uuid, uuid, numeric, text, text, text)',
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
end; $function$;


-- ────────────────────────────────────────────────────────────────────────────
-- 8. _r2j_make_world — opt-out de seed rules R.14.
--
-- Los 7 smokes de R.2J comparten este mundo y assertan conteos exactos de
-- activity events y obligations; las seed rules del friend_group agregan
-- rule.evaluated + obligation.created extra. Mismo opt-out explícito.
-- Cuerpo idéntico a r2j_2 (20260602103000) salvo create_context.
-- ────────────────────────────────────────────────────────────────────────────

create or replace function public._r2j_make_world()
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid; u_david uuid; a_david uuid; u_isaac uuid; a_isaac uuid;
  u_moises uuid; a_moises uuid; u_daniel uuid; a_daniel uuid; u_abuelo uuid; a_abuelo uuid;
  u_out uuid; a_out uuid;
  v_cena uuid; v_viaje uuid; v_familia uuid; v_negocio uuid;
  v_code text; v_starts timestamptz;
  v_event uuid; v_batch uuid; v_casa uuid; v_terreno uuid;
  v_res_david uuid; v_res_isaac uuid; v_res_extra uuid; v_conflict uuid;
  v_decision uuid; v_right_moises uuid;
  v_item record;
begin
  -- ═══ Personas ═══
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2J', '+5210000100');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2J', '+5210000101');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2J', '+5210000102');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés R2J', '+5210000103');
  select auth_id, actor_id into u_daniel, a_daniel from public._r2_make_person('Daniel R2J', '+5210000104');
  select auth_id, actor_id into u_abuelo, a_abuelo from public._r2_make_person('Abuelo R2J', '+5210000105');
  select auth_id, actor_id into u_out, a_out from public._r2_make_person('Outsider R2J', '+5210000106');

  -- ═══ Contextos + memberships ═══
  -- Cena Semanal Amigos: José (founder) + David, Isaac, Moisés, Daniel (+ outsider temporal)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_cena := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group',
    p_metadata := '{"r14_skip_seed_rules": true}'::jsonb))->>'context_actor_id';
  v_code := (public.create_invite(v_cena::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.join_by_invite_code(v_code);
  -- el outsider entra y luego es removido → membership.removed sin afectar a los 5 core
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Viaje Japón: José (founder) + David, Isaac
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_viaje := (public.create_context('Viaje Japón', 'collective', 'trip'))->>'context_actor_id';
  v_code := (public.create_invite(v_viaje::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Familia Mizrahi: Abuelo (founder) + José, David, Isaac, Moisés, Daniel
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_familia := (public.create_context('Familia Mizrahi', 'collective', 'family'))->>'context_actor_id';
  v_code := (public.create_invite(v_familia::uuid))->>'code';
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

  -- Negocio Valle: José (founder) + David
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_negocio := (public.create_context('Negocio Valle', 'collective', 'company'))->>'context_actor_id';
  v_code := (public.create_invite(v_negocio::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- ═══ CENA: reglas → evento → RSVPs → check-ins → multas → gasto → juego → doc → settlement → remove ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.create_rule(v_cena::uuid, 'Multa por llegar tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": ">", "field": "minutes_late", "value": 15}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine", "amount": 100, "currency": "MXN", "reason": "late_arrival"}]'::jsonb);
  perform public.create_rule(v_cena::uuid, 'Multa por cancelar mismo día',
    p_trigger_event_type := 'event.participation_cancelled',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": "=", "field": "same_day_cancellation", "value": true}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine", "amount": 300, "currency": "MXN", "reason": "same_day_cancellation"}]'::jsonb);

  v_starts := now() - interval '21 minutes';
  v_event := (public.create_calendar_event(v_cena::uuid, 'Cena miércoles', 'dinner',
    p_starts_at := v_starts, p_ends_at := v_starts + interval '3 hours',
    p_timezone := 'America/Mexico_City', p_host_actor_id := a_david))->>'event_id';

  -- RSVPs ×5
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');

  -- Check-ins (David host: él, José, Isaac) + cancelación de Daniel + Moisés tarde
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.check_in_participant(v_event::uuid, p_checked_in_at := v_starts);
  perform public.check_in_participant(v_event::uuid, a_jose, v_starts + interval '5 minutes');
  perform public.check_in_participant(v_event::uuid, a_isaac, v_starts + interval '12 minutes');
  perform public.cancel_participation(v_event::uuid, a_daniel, v_starts);  -- multa $300
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.check_in_participant(v_event::uuid);                       -- late → multa $100

  -- Gasto + juego + documento
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.record_expense(v_cena::uuid, 1300, 'MXN', 'Pizza, cerveza y botanas',
    p_split_with := array[a_david, a_jose, a_isaac, a_moises],
    p_event_id := v_event::uuid, p_client_id := 'r2j-cena-expense-001',
    p_excluded_actor_ids := array[a_daniel]);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.record_game_result(v_cena::uuid, v_event::uuid, 'Catan', a_moises, a_daniel, 250, 'MXN', 'r2j-catan-001');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.register_document('Recibo de la cena', p_context_actor_id := v_cena::uuid);

  -- Settlement completo
  v_batch := (public.generate_settlement_batch(v_cena::uuid, 'MXN'))->>'batch_id';
  for v_item in select id from public.settlement_items
                 where settlement_batch_id = v_batch::uuid and status = 'pending' loop
    perform public.mark_settlement_paid(v_item.id);
  end loop;

  -- Remoción (outsider) → membership.removed
  perform public.remove_member(v_cena::uuid, a_out, 'salida del grupo');

  -- ═══ FAMILIA: recursos + rights + reservaciones con conflicto + cancelación ═══
  -- (los recursos se crean EN el contexto Familia → la activity queda en la Familia)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_casa := (public.create_resource(v_familia::uuid, 'house', 'Casa Valle'))->>'resource_id';
  v_terreno := (public.create_resource(v_familia::uuid, 'property', 'Terreno Valle'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, a_david, 'USE');
  perform public.grant_right(v_casa::uuid, a_isaac, 'USE');
  -- right otorgado y revocado → right.revoked
  v_right_moises := (public.grant_right(v_casa::uuid, a_moises, 'USE'))->>'right_id';
  perform public.revoke_right(v_right_moises::uuid);

  -- Conflicto David vs Isaac → resolución a favor de Isaac → Isaac confirma
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_res_david := (public.request_resource_reservation(v_casa::uuid, v_familia::uuid,
    '2026-07-10 16:00-06'::timestamptz, '2026-07-12 18:00-06'::timestamptz))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_res_isaac := (public.request_resource_reservation(v_casa::uuid, v_familia::uuid,
    '2026-07-10 16:00-06'::timestamptz, '2026-07-12 18:00-06'::timestamptz))->>'reservation_id';
  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_casa::uuid and resolution_status = 'open' limit 1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  perform public.resolve_reservation_conflict(v_conflict, v_res_isaac::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.confirm_reservation(v_res_isaac::uuid);
  -- reservación cancelada → reservation.cancelled
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_res_extra := (public.request_resource_reservation(v_casa::uuid, v_familia::uuid,
    '2026-07-17 16:00-06'::timestamptz, '2026-07-19 18:00-06'::timestamptz))->>'reservation_id';
  perform public.cancel_reservation(v_res_extra::uuid);

  -- ═══ NEGOCIO: decisión votada y ejecutada + gasto ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_decision := (public.create_decision(v_negocio::uuid, 'resource_purchase', '¿Compramos el terreno contiguo?',
    p_payload := jsonb_build_object('options', jsonb_build_array('Comprar', 'Esperar'))))->>'decision_id';
  perform public.vote_decision(v_decision::uuid, 'approve', 'Comprar');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.vote_decision(v_decision::uuid, 'approve', 'Comprar');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.close_decision(v_decision::uuid);
  perform public.execute_decision(v_decision::uuid);
  perform public.record_expense(v_negocio::uuid, 5000, 'MXN', 'Anticipo terreno',
    p_split_with := array[a_jose, a_david], p_client_id := 'r2j-negocio-anticipo-001');

  -- ═══ VIAJE: gasto hotel ═══
  perform public.record_expense(v_viaje::uuid, 9000, 'MXN', 'Hotel Tokio',
    p_client_id := 'r2j-viaje-hotel-001');

  perform set_config('request.jwt.claims', null, true);

  return jsonb_build_object(
    'cena', v_cena, 'viaje', v_viaje, 'familia', v_familia, 'negocio', v_negocio,
    'jose', a_jose, 'david', a_david, 'isaac', a_isaac, 'moises', a_moises,
    'daniel', a_daniel, 'abuelo', a_abuelo, 'outsider', a_out,
    'u_jose', u_jose, 'u_david', u_david, 'u_isaac', u_isaac, 'u_moises', u_moises,
    'u_daniel', u_daniel, 'u_abuelo', u_abuelo, 'u_outsider', u_out,
    'cena_event', v_event, 'cena_batch', v_batch,
    'casa', v_casa, 'terreno', v_terreno,
    'conflict', v_conflict, 'res_david', v_res_david, 'res_isaac', v_res_isaac,
    'decision', v_decision);
end; $$;


-- ────────────────────────────────────────────────────────────────────────────
-- 9. _smoke_r2k_full_reality_auth_simulation — opt-out de seed rules R.14.
--
-- Asserta el set exacto de multas de sus propias reglas; la seed fine de $30
-- lo contamina. Cuerpo idéntico a r5pre (20260605000003) salvo create_context.
-- ────────────────────────────────────────────────────────────────────────────

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
  c_cena := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group',
    p_metadata := '{"r14_skip_seed_rules": true}'::jsonb))->>'context_actor_id';
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
end; $function$;


-- ────────────────────────────────────────────────────────────────────────────
-- 10. _smoke_r2s_reservation_outcomes — ventana alineada a R.RES.POLICY.
--
-- Igual que m6: una casa (granularity=day, min 1) ya no acepta 12 horas.
-- La reserva en conflicto de Isaac ahora pide 1 día completo (día 10 → 11),
-- que cumple la policy y sigue traslapando la de David (días 10 → 12).
-- Cuerpo idéntico a r2s_7 (20260603170600) salvo esa ventana.
-- ────────────────────────────────────────────────────────────────────────────

create or replace function public._smoke_r2s_reservation_outcomes()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  v_ctx uuid; v_casa uuid;
  v_r1 uuid; v_r2 uuid; v_conflict uuid;
  v_decision uuid;
  v_status_loser text; v_status_winner text;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2S-resv', '+5210000111');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2S-resv', '+5210000112');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2S-resv', '+5210000113');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Familia R2S resv', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform public.invite_member(v_ctx::uuid, a_isaac);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_casa := (public.create_resource(v_ctx::uuid, 'house', 'Casa Valle R2S-resv'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, v_ctx::uuid, 'MANAGE');
  perform public.grant_right(v_casa::uuid, a_david, 'USE');
  perform public.grant_right(v_casa::uuid, a_isaac, 'USE');

  -- ═══ OUTCOME 1: waitlisted ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_r1 := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
            now() + interval '10 days', now() + interval '12 days', a_david))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_r2 := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
            now() + interval '10 days', now() + interval '11 days', a_isaac))->>'reservation_id';
  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_casa::uuid and resolution_status = 'open'
     and (reservation_a_id = v_r2 or reservation_b_id = v_r2) limit 1;
  if v_conflict is null then raise exception 'R2S.7 FAIL 1: no se detectó el conflicto'; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.resolve_reservation_conflict(v_conflict, 'waitlisted', v_r1);
  select status into v_status_winner from public.resource_reservations where id = v_r1;
  select status into v_status_loser  from public.resource_reservations where id = v_r2;
  if v_status_winner <> 'approved' or v_status_loser <> 'waitlisted' then
    raise exception 'R2S.7 FAIL 1: waitlisted mal aplicado (winner=% loser=%)', v_status_winner, v_status_loser;
  end if;

  -- ═══ OUTCOME 2: split_dates ═══
  perform public.cancel_reservation(v_r1::uuid);
  perform public.cancel_reservation(v_r2::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_r1 := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
            now() + interval '20 days', now() + interval '24 days', a_david))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_r2 := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
            now() + interval '21 days', now() + interval '25 days', a_isaac))->>'reservation_id';
  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_casa::uuid and resolution_status = 'open'
     and (reservation_a_id = v_r2 or reservation_b_id = v_r2) limit 1;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.resolve_reservation_conflict(v_conflict, 'split_dates');
  if (select count(*) from public.resource_reservations where id in (v_r1, v_r2) and status = 'approved') <> 2 then
    raise exception 'R2S.7 FAIL 2: split_dates no dejó ambas approved';
  end if;
  -- y no se traslapan (el EXCLUDE habría fallado, pero verificamos el corte)
  if (select max(ends_at) from public.resource_reservations where id = v_r1)
     > (select min(starts_at) from public.resource_reservations where id = v_r2)
     and (select max(ends_at) from public.resource_reservations where id = v_r2)
     > (select min(starts_at) from public.resource_reservations where id = v_r1) then
    -- al menos uno debe haber cedido su rango; comprobamos que el corte ocurrió
    null;
  end if;

  -- ═══ OUTCOME 3: requires_decision → la decision option resuelve el conflicto ═══
  perform public.cancel_reservation(v_r1::uuid);
  perform public.cancel_reservation(v_r2::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_r1 := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
            now() + interval '30 days', now() + interval '34 days', a_david))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_r2 := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
            now() + interval '31 days', now() + interval '35 days', a_isaac))->>'reservation_id';
  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_casa::uuid and resolution_status = 'open'
     and (reservation_a_id = v_r2 or reservation_b_id = v_r2) limit 1;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_decision := (public.resolve_reservation_conflict(v_conflict, 'requires_decision'))->>'decision_id';
  if v_decision is null then raise exception 'R2S.7 FAIL 3: requires_decision no abrió decisión'; end if;
  -- el conflicto sigue abierto hasta ejecutar
  if (select resolution_status from public.reservation_conflicts where id = v_conflict) <> 'open' then
    raise exception 'R2S.7 FAIL 3: el conflicto no debería resolverse antes de la decisión';
  end if;

  -- todos votan por la reservación de David (option res_a o res_b según el mapeo)
  declare
    v_winner_opt text;
  begin
    select case when (payload->'option_reservations'->>'res_a')::uuid = v_r1 then 'res_a' else 'res_b' end
      into v_winner_opt from public.decisions where id = v_decision::uuid;

    perform public.vote_decision(v_decision::uuid, 'approve', v_winner_opt);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
    perform public.vote_decision(v_decision::uuid, 'approve', v_winner_opt);
    -- con 2/3 votos para la misma opción ya hay mayoría absoluta → approved
  end;

  -- ejecutar la decisión resuelve el conflicto (winning option → reservación)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.execute_decision(v_decision::uuid);
  if (select resolution_status from public.reservation_conflicts where id = v_conflict) <> 'resolved' then
    raise exception 'R2S.7 FAIL 3: ejecutar la decisión no resolvió el conflicto';
  end if;
  if (select status from public.resource_reservations where id = v_r1) <> 'approved' then
    raise exception 'R2S.7 FAIL 3: la reservación ganadora por decisión no quedó approved';
  end if;
  if (select status from public.resource_reservations where id = v_r2) <> 'rejected' then
    raise exception 'R2S.7 FAIL 3: la reservación perdedora por decisión no quedó rejected';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david, a_isaac], array[u_jose, u_david, u_isaac]);

  raise notice 'R.2S.7 RESERVATION OUTCOMES: PASS (waitlisted, split_dates, requires_decision vía decision option)';
end; $$;


-- ────────────────────────────────────────────────────────────────────────────
-- 11. _smoke_r2s_rule_targeting — ventanas alineadas a R.RES.POLICY.
--
-- Las 2 reservas de prueba eran de 2 horas sobre casas (granularity=day,
-- min 1 día). Ahora piden 1 día completo; el smoke prueba targeting de reglas
-- sobre reservation.created — la duración es irrelevante para el assert.
-- Cuerpo idéntico a r2s_6 (20260603170500) salvo esas ventanas.
-- ────────────────────────────────────────────────────────────────────────────

create or replace function public._smoke_r2s_rule_targeting()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  v_ctx uuid; v_casa uuid; v_otra uuid;
  v_resv uuid; v_resv2 uuid;
  v_fines_before integer; v_fines_after integer;
  v_money_obs_before integer; v_money_obs_after integer;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2S-rule', '+5210000101');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2S-rule', '+5210000102');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Familia R2S rule', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_casa := (public.create_resource(v_ctx::uuid, 'house', 'Casa Valle R2S-rule'))->>'resource_id';
  v_otra := (public.create_resource(v_ctx::uuid, 'house', 'Casa Otra R2S-rule'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, a_david, 'USE');
  perform public.grant_right(v_otra::uuid, a_david, 'USE');

  -- ═══ REGLA RESERVATION: cancelar Casa Valle con <48h → multa 200 ═══
  -- target_scope=resource, target_filter acota a Casa Valle (no a Casa Otra)
  perform public.create_rule(
    v_ctx::uuid, 'Cancelación tardía Casa Valle',
    'reservation.cancelled',
    '{"op": "<", "field": "hours_before", "value": 48}'::jsonb,
    '[{"type": "fine", "amount": 200, "currency": "MXN", "reason": "Cancelación tardía"}]'::jsonb,
    'resource',
    jsonb_build_object('resource_id', v_casa::text));

  -- ═══ REGLA MONEY: gasto > 5000 → obligación de revisión ═══
  perform public.create_rule(
    v_ctx::uuid, 'Gasto grande requiere revisión',
    'money.expense_recorded',
    '{"op": ">", "field": "amount", "value": 5000}'::jsonb,
    '[{"type": "create_obligation", "obligation_type": "other", "amount": 0, "reason": "Gasto grande revisión"}]'::jsonb,
    'money_transaction',
    '{}'::jsonb);

  -- ─── Reservation: David reserva Casa Valle mañana y la cancela (≈24h antes) ───
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_resv := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
                now() + interval '24 hours', now() + interval '48 hours'))->>'reservation_id';

  select count(*) into v_fines_before from public.obligations
   where context_actor_id = v_ctx::uuid and obligation_type = 'fine';
  perform public.cancel_reservation(v_resv::uuid);
  select count(*) into v_fines_after from public.obligations
   where context_actor_id = v_ctx::uuid and obligation_type = 'fine';

  if v_fines_after <> v_fines_before + 1 then
    raise exception 'R2S.5 FAIL 1: la regla de reservación no creó la multa (antes=% después=%)',
      v_fines_before, v_fines_after;
  end if;

  -- ─── La misma cancelación en Casa Otra NO dispara (target_filter por recurso) ───
  v_resv2 := (public.request_resource_reservation(v_otra::uuid, v_ctx::uuid,
                now() + interval '24 hours', now() + interval '48 hours'))->>'reservation_id';
  select count(*) into v_fines_before from public.obligations
   where context_actor_id = v_ctx::uuid and obligation_type = 'fine';
  perform public.cancel_reservation(v_resv2::uuid);
  select count(*) into v_fines_after from public.obligations
   where context_actor_id = v_ctx::uuid and obligation_type = 'fine';
  if v_fines_after <> v_fines_before then
    raise exception 'R2S.5 FAIL 2: el target_filter no acotó la regla a Casa Valle';
  end if;

  -- ─── Money: José registra un gasto grande → regla money dispara ───
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  select count(*) into v_money_obs_before from public.obligations
   where context_actor_id = v_ctx::uuid and metadata->>'reason' = 'Gasto grande revisión';
  perform public.record_expense(v_ctx::uuid, 9000, 'MXN', 'Reparación techo',
    p_split_with := array[a_jose]);  -- solo el pagador, sin deudas
  select count(*) into v_money_obs_after from public.obligations
   where context_actor_id = v_ctx::uuid and metadata->>'reason' = 'Gasto grande revisión';
  if v_money_obs_after <> v_money_obs_before + 1 then
    raise exception 'R2S.5 FAIL 3: la regla del dominio money no disparó (antes=% después=%)',
      v_money_obs_before, v_money_obs_after;
  end if;

  -- ─── Un gasto chico NO dispara la regla money ───
  select count(*) into v_money_obs_before from public.obligations
   where context_actor_id = v_ctx::uuid and metadata->>'reason' = 'Gasto grande revisión';
  perform public.record_expense(v_ctx::uuid, 100, 'MXN', 'Café', p_split_with := array[a_jose]);
  select count(*) into v_money_obs_after from public.obligations
   where context_actor_id = v_ctx::uuid and metadata->>'reason' = 'Gasto grande revisión';
  if v_money_obs_after <> v_money_obs_before then
    raise exception 'R2S.5 FAIL 4: la condición de monto no filtró el gasto chico';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david], array[u_jose, u_david]);

  raise notice 'R.2S.5 RULE TARGETING: PASS (regla reservation con filtro por recurso + regla money por monto — misma infraestructura)';
end; $$;


-- ────────────────────────────────────────────────────────────────────────────
-- 12. _smoke_r2s_universal_behavior_models — ventana alineada a R.RES.POLICY.
--
-- La reserva del caso 6 (regla de cancelación) era de 2 horas sobre casa
-- (granularity=day, min 1 día). Ahora 1 día completo; el assert es sobre la
-- regla al cancelar, no sobre la duración.
-- Cuerpo idéntico a r2s_8 (20260603170700) salvo esa ventana.
-- ────────────────────────────────────────────────────────────────────────────

create or replace function public._smoke_r2s_universal_behavior_models()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  v_fam uuid; v_quimi uuid;
  v_casa uuid; v_cuenta uuid; v_acciones uuid;
  v_detail jsonb; v_actions jsonb; v_exp jsonb;
  v_decision uuid; v_options jsonb;
  v_vino uuid;
  v_resv1 uuid; v_resv2 uuid; v_conflict uuid; v_disp_decision uuid;
  v_obs_before int; v_obs_after int;
  v_winner_opt text;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2S-master', '+5210000121');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2S-master', '+5210000122');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2S-master', '+5210000123');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_fam   := (public.create_context('Familia Mizrahi R2S', 'collective', 'family'))->>'context_actor_id';
  v_quimi := (public.create_context('Quimibond R2S', 'legal_entity', 'company'))->>'context_actor_id';
  perform public.invite_member(v_fam::uuid, a_david);
  perform public.invite_member(v_fam::uuid, a_isaac);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_fam::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.accept_invitation(v_fam::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_casa     := (public.create_resource(v_fam::uuid, 'house', 'Casa Valle'))->>'resource_id';
  v_cuenta   := (public.create_resource(v_fam::uuid, 'bank_account', 'Cuenta del Viaje'))->>'resource_id';
  v_acciones := (public.create_resource(v_quimi::uuid, 'security', 'Acciones Quimibond'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, v_fam::uuid, 'MANAGE');
  perform public.grant_right(v_casa::uuid, a_david, 'USE');
  perform public.grant_right(v_casa::uuid, a_isaac, 'USE');

  -- ════════ 1. Casa Valle muestra reservation actions ════════
  v_actions := (public.resource_detail(v_casa::uuid))->'available_actions';
  if not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'reserve_resource') then
    raise exception 'R2S CONTRACT 1: Casa Valle no muestra reserve_resource';
  end if;

  -- ════════ 2. Cuenta del Viaje NO muestra reservation actions ════════
  v_actions := (public.resource_detail(v_cuenta::uuid))->'available_actions';
  if exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'reserve_resource') then
    raise exception 'R2S CONTRACT 2: la Cuenta del Viaje muestra reserve_resource';
  end if;

  -- ════════ 3. Acciones Quimibond: NO reservation, SÍ beneficiary + ownership ════════
  v_actions := (public.resource_detail(v_acciones::uuid))->'available_actions';
  if exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'reserve_resource') then
    raise exception 'R2S CONTRACT 3: Acciones Quimibond muestra reserve_resource';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'view_beneficiaries') then
    raise exception 'R2S CONTRACT 3: Acciones Quimibond no muestra view_beneficiaries';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'view_ownership') then
    raise exception 'R2S CONTRACT 3: Acciones Quimibond no muestra view_ownership';
  end if;

  -- ════════ 4. Decision Casa Valle usa options reales ════════
  v_decision := (public.create_decision(
    v_fam::uuid, 'reservation_dispute', '¿Quién se queda con Casa Valle?',
    'Disputa de fechas', null,
    jsonb_build_object('options', jsonb_build_array('David', 'Isaac', 'Dividir fechas')),
    null, 'single_choice'))->>'decision_id';
  v_options := (public.decision_detail(v_decision::uuid))->'options';
  if jsonb_array_length(v_options) < 3 then
    raise exception 'R2S CONTRACT 4: la decisión no tiene las opciones reales (got %)', jsonb_array_length(v_options);
  end if;

  -- ════════ 10a. Available actions cambian por estado: decisión abierta → vote ════════
  v_actions := public.decision_available_actions(v_decision::uuid, a_jose);
  if not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'vote') then
    raise exception 'R2S CONTRACT 10: la decisión abierta no muestra vote';
  end if;

  -- ════════ 5. Obligation "llevar vino" sin amount/currency ════════
  v_vino := (public.create_action_obligation(
    v_fam::uuid, a_david, 'Llevar vino', 'action',
    'David trae el vino a la próxima cena'))->>'obligation_id';
  v_detail := public.obligation_detail(v_vino::uuid);
  if v_detail->>'kind' <> 'action' or v_detail->>'amount' is not null or v_detail->>'currency' is not null then
    raise exception 'R2S CONTRACT 5: la obligación de acción no debería tener amount/currency';
  end if;
  -- y su available_actions incluye mark_completed (no pay, porque no es money)
  v_actions := v_detail->'available_actions';
  if not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'mark_completed') then
    raise exception 'R2S CONTRACT 5: la obligación de acción no muestra mark_completed';
  end if;
  if exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'pay') then
    raise exception 'R2S CONTRACT 5: la obligación de acción no debería mostrar pay';
  end if;

  -- ════════ 6. Rule aplica a reservation y money ════════
  perform public.create_rule(
    v_fam::uuid, 'Cancelación tardía Casa Valle', 'reservation.cancelled',
    '{"op": "<", "field": "hours_before", "value": 48}'::jsonb,
    '[{"type": "fine", "amount": 200, "currency": "MXN", "reason": "Cancelación tardía"}]'::jsonb,
    'resource', jsonb_build_object('resource_id', v_casa::text));
  perform public.create_rule(
    v_fam::uuid, 'Gasto grande revisión', 'money.expense_recorded',
    '{"op": ">", "field": "amount", "value": 5000}'::jsonb,
    '[{"type": "create_obligation", "obligation_type": "other", "amount": 0, "reason": "Gasto grande revisión"}]'::jsonb,
    'money_transaction', '{}'::jsonb);

  -- reservation rule fires
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_resv1 := (public.request_resource_reservation(v_casa::uuid, v_fam::uuid,
                now() + interval '24 hours', now() + interval '48 hours', a_david))->>'reservation_id';
  select count(*) into v_obs_before from public.obligations where context_actor_id = v_fam::uuid and obligation_type = 'fine';
  perform public.cancel_reservation(v_resv1::uuid);
  select count(*) into v_obs_after from public.obligations where context_actor_id = v_fam::uuid and obligation_type = 'fine';
  if v_obs_after <> v_obs_before + 1 then
    raise exception 'R2S CONTRACT 6: la regla de reservación no disparó';
  end if;
  -- money rule fires
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  select count(*) into v_obs_before from public.obligations where context_actor_id = v_fam::uuid and metadata->>'reason' = 'Gasto grande revisión';
  perform public.record_expense(v_fam::uuid, 9000, 'MXN', 'Reparación', p_split_with := array[a_jose]);
  select count(*) into v_obs_after from public.obligations where context_actor_id = v_fam::uuid and metadata->>'reason' = 'Gasto grande revisión';
  if v_obs_after <> v_obs_before + 1 then
    raise exception 'R2S CONTRACT 6: la regla del dominio money no disparó';
  end if;

  -- ════════ 7. Expense percentage split ════════
  v_detail := public.record_expense(v_fam::uuid, 1000, 'MXN', 'Hotel',
    p_split_method := 'percentage',
    p_splits := jsonb_build_array(
      jsonb_build_object('actor_id', a_david, 'percent', 30),
      jsonb_build_object('actor_id', a_isaac, 'percent', 70)));
  if (select sum(amount) from public.money_splits
      where transaction_id = (v_detail->>'transaction_id')::uuid and split_role = 'debtor') <> 1000 then
    raise exception 'R2S CONTRACT 7: percentage split no suma 1000';
  end if;

  -- ════════ 8. Reservation conflict resuelto con decision option ════════
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_resv1 := (public.request_resource_reservation(v_casa::uuid, v_fam::uuid,
                now() + interval '40 days', now() + interval '44 days', a_david))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_resv2 := (public.request_resource_reservation(v_casa::uuid, v_fam::uuid,
                now() + interval '41 days', now() + interval '45 days', a_isaac))->>'reservation_id';
  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_casa::uuid and resolution_status = 'open'
     and (reservation_a_id = v_resv2 or reservation_b_id = v_resv2) limit 1;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_disp_decision := (public.resolve_reservation_conflict(v_conflict, 'requires_decision'))->>'decision_id';
  select case when (payload->'option_reservations'->>'res_a')::uuid = v_resv1 then 'res_a' else 'res_b' end
    into v_winner_opt from public.decisions where id = v_disp_decision::uuid;
  perform public.vote_decision(v_disp_decision::uuid, 'approve', v_winner_opt);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.vote_decision(v_disp_decision::uuid, 'approve', v_winner_opt);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.execute_decision(v_disp_decision::uuid);
  if (select resolution_status from public.reservation_conflicts where id = v_conflict) <> 'resolved' then
    raise exception 'R2S CONTRACT 8: la decision option no resolvió el conflicto';
  end if;

  -- ════════ 9. Activity types catalogados ════════
  if exists (
    select 1 from public.activity_events ae
    where ae.context_actor_id = v_fam::uuid
      and (ae.payload->>'uncatalogued')::boolean is true
  ) then
    raise exception 'R2S CONTRACT 9: hay activity fuera del catálogo';
  end if;

  -- ════════ 10b. Available actions cambian por estado: decisión ejecutada → sin vote ════════
  v_actions := public.decision_available_actions(v_disp_decision::uuid, a_jose);
  if exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'vote') then
    raise exception 'R2S CONTRACT 10: una decisión ejecutada todavía muestra vote';
  end if;

  -- ════════ 11. Explanation engine ════════
  -- visibility
  v_exp := public.why_can_view_resource(a_david, v_casa::uuid);
  if not (v_exp->>'can_view')::boolean then
    raise exception 'R2S CONTRACT 11: why_can_view_resource no explica la visibilidad de David';
  end if;
  -- obligation
  v_exp := public.why_obligation_exists(v_vino::uuid);
  if v_exp is null or not (v_exp ? 'source') then
    raise exception 'R2S CONTRACT 11: why_obligation_exists no explica la obligación';
  end if;
  -- reservation
  v_exp := public.why_reservation_won(v_conflict);
  if v_exp->>'winner_reservation_id' is null then
    raise exception 'R2S CONTRACT 11: why_reservation_won no explica al ganador';
  end if;
  -- decision
  v_exp := public.why_decision_result(v_disp_decision::uuid);
  if not (v_exp ? 'tally') then
    raise exception 'R2S CONTRACT 11: why_decision_result no explica el conteo';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_quimi::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(v_fam::uuid, array[a_jose, a_david, a_isaac], array[u_jose, u_david, u_isaac]);

  raise notice 'R.2S.11 UNIVERSAL BEHAVIOR MODELS CONTRACT: PASS (11/11 puntos)';
end; $$;


-- ────────────────────────────────────────────────────────────────────────────
-- 13. _smoke_mvp2_r9_e_hardening — opt-out de seed rules R.14.
--
-- Asserta el monto exacto de su propia multa ($100); la seed fine de $30
-- contamina la fila que el smoke selecciona. Cuerpo idéntico a r9_e
-- (20260611105000) salvo create_context.
-- ────────────────────────────────────────────────────────────────────────────

create or replace function public._smoke_mvp2_r9_e_hardening()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  u_admin uuid; a_admin uuid;
  u_b uuid; a_b uuid;
  u_c uuid; a_c uuid;
  u_d uuid; a_d uuid;
  u_e uuid; a_e uuid;
  v_ctx uuid; v_code text; v_event uuid;
  v_result jsonb; v_removed jsonb; v_payload jsonb;
  v_fine numeric;
  v_caught boolean;
begin
  -- ═══ Setup: contexto con admin + 4 miembros (mundo estilo m8/r2e) ═══
  select auth_id, actor_id into u_admin, a_admin from public._r2_make_person('Ana R9E', '+5210000961');
  select auth_id, actor_id into u_b, a_b from public._r2_make_person('Beto R9E', '+5210000962');
  select auth_id, actor_id into u_c, a_c from public._r2_make_person('Carla R9E', '+5210000963');
  select auth_id, actor_id into u_d, a_d from public._r2_make_person('Darío R9E', '+5210000964');
  select auth_id, actor_id into u_e, a_e from public._r2_make_person('Elsa R9E', '+5210000965');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  v_ctx := (public.create_context('R9E Hardening', 'collective', 'friend_group',
    p_metadata := '{"r14_skip_seed_rules": true}'::jsonb))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_d::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_e::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Regla: multa $100 por llegar > 15 min tarde + evento que empezó hace 30 min
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  perform public.create_rule(v_ctx::uuid, 'R9E Multa por tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": ">", "field": "minutes_late", "value": 15}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);
  v_event := (public.create_calendar_event(v_ctx::uuid, 'R9E Cena', 'dinner',
    p_location_text := 'Por definir', p_starts_at := now() - interval '30 minutes'))->>'event_id';

  -- ═══ Caso 1a: miembro ACTIVO llega tarde → multa (sanity positivo) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  v_result := public.check_in_participant(v_event::uuid);
  if (v_result->'rules'->>'rules_matched')::integer < 1 then
    raise exception 'r9_e Caso1a: la regla de tarde no matcheó para miembro activo';
  end if;
  select amount into v_fine from public.obligations
   where context_actor_id = v_ctx::uuid and debtor_actor_id = a_c
     and obligation_type = 'fine' and source_rule_id is not null;
  if v_fine is distinct from 100 then
    raise exception 'r9_e Caso1a: multa para miembro activo incorrecta (% en vez de 100)', v_fine;
  end if;

  -- ═══ Caso 1b: miembro REMOVIDO no recibe multa (no phantom fines) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  v_removed := public.remove_member(v_ctx::uuid, a_b, 'r9e remoción limpia');
  if not (v_removed->>'removed')::boolean then
    raise exception 'r9_e Caso1b: remove_member de miembro sin deudas falló';
  end if;

  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.checked_in', a_b,
    jsonb_build_object('minutes_late', 40), v_event::uuid);
  if (v_result->>'rules_matched')::integer < 1 then
    raise exception 'r9_e Caso1b: la regla debió matchear (el skip es por consecuencia, no por match)';
  end if;
  if exists (
    select 1 from public.obligations
     where context_actor_id = v_ctx::uuid and debtor_actor_id = a_b
  ) then
    raise exception 'r9_e Caso1b: phantom fine creada para miembro removido';
  end if;
  if not (v_result->'obligations_created' @>
          '[{"skipped": true, "skip_reason": "subject_not_active_member"}]'::jsonb) then
    raise exception 'r9_e Caso1b: el resultado no registró el skip por membresía: %', v_result;
  end if;
  if not exists (
    select 1 from public.rule_evaluations
     where context_actor_id = v_ctx::uuid
       and consequences_emitted->'obligations' @>
           '[{"skip_reason": "subject_not_active_member"}]'::jsonb
  ) then
    raise exception 'r9_e Caso1b: rule_evaluations no dejó nota del skip';
  end if;

  -- ═══ Caso 2a: remove_member bloqueado con obligación money abierta ═══
  -- record_fine canónico = firma R.9.B con p_client_id (la 5-arg fue dropeada
  -- en 20260611101000); pasamos los 6 args explícitos para fijar el overload.
  perform public.record_fine(v_ctx::uuid, a_d, 250, 'MXN', 'r9e deuda abierta', null);
  v_caught := false;
  begin
    perform public.remove_member(v_ctx::uuid, a_d, 'r9e debe dinero');
  exception when others then
    if sqlerrm not like 'member_has_open_obligations%' then
      raise exception 'r9_e Caso2a: error inesperado: %', sqlerrm;
    end if;
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'r9_e Caso2a: remove_member procedió con obligación abierta';
  end if;
  if not exists (
    select 1 from public.actor_memberships
     where context_actor_id = v_ctx::uuid and member_actor_id = a_d
       and membership_status = 'active'
  ) then
    raise exception 'r9_e Caso2a: la membresía debió quedar intacta tras el bloqueo';
  end if;

  -- ═══ Caso 2b: p_force => true permite la remoción + activity con conteo ═══
  v_removed := public.remove_member(v_ctx::uuid, a_d, 'r9e forzado', p_force => true);
  if not (v_removed->>'removed')::boolean then
    raise exception 'r9_e Caso2b: remove_member forzado falló';
  end if;
  -- _emit_activity (R.2S.4) normaliza 'member.removed' → 'membership.removed'
  select payload into v_payload from public.activity_events
   where context_actor_id = v_ctx::uuid and event_type = 'membership.removed' and subject_id = a_d
   order by created_at desc limit 1;
  if v_payload is null
     or (v_payload->>'forced')::boolean is distinct from true
     or (v_payload->>'open_obligations_count')::integer is distinct from 1 then
    raise exception 'r9_e Caso2b: activity member.removed sin nota del override (%)', v_payload;
  end if;

  -- ═══ Caso 2c: sin obligaciones → remoción normal sin p_force ═══
  v_removed := public.remove_member(v_ctx::uuid, a_e, 'r9e sin deudas');
  if not (v_removed->>'removed')::boolean then
    raise exception 'r9_e Caso2c: remove_member sin deudas falló';
  end if;

  -- (Caso 3 — attention_inbox: sin cambios en esta migración; ver header punto 3.)

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_admin, a_b, a_c, a_d, a_e],
    array[u_admin, u_b, u_c, u_d, u_e]);

  raise notice '_smoke_mvp2_r9_e_hardening passed (1a multa activa, 1b no phantom fine, 2a bloqueo, 2b force, 2c limpio)';
end; $$;


-- ────────────────────────────────────────────────────────────────────────────
-- 14. _smoke_mvp2_r9_h_rule_eval_dedup — opt-out de seed rules R.14.
--
-- Asserta exactamente 1 multa tras el check-in tarde (dedup de doble eval);
-- la seed fine de $30 es una segunda multa legítima que rompe el conteo.
-- Cuerpo idéntico a r9_h (20260611110000) salvo create_context.
-- ────────────────────────────────────────────────────────────────────────────

create or replace function public._smoke_mvp2_r9_h_rule_eval_dedup()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  u_admin uuid; a_admin uuid;
  u_m uuid; a_m uuid;
  u_x uuid; a_x uuid;
  v_ctx uuid; v_code text; v_event uuid;
  v_result jsonb;
  v_n integer;
begin
  select auth_id, actor_id into u_admin, a_admin from public._r2_make_person('Ana R9H', '+5210000971');
  select auth_id, actor_id into u_m, a_m from public._r2_make_person('Memo R9H', '+5210000972');
  select auth_id, actor_id into u_x, a_x from public._r2_make_person('Xeno R9H', '+5210000973');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  v_ctx := (public.create_context('R9H Dedup', 'collective', 'friend_group',
    p_metadata := '{"r14_skip_seed_rules": true}'::jsonb))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_m::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Regla SIN condición de event_type (el caso que multaba doble) + evento tarde.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  perform public.create_rule(v_ctx::uuid, 'R9H Multa por tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": ">", "field": "minutes_late", "value": 15}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);
  v_event := (public.create_calendar_event(v_ctx::uuid, 'R9H Cena', 'dinner',
    p_location_text := 'Por definir', p_starts_at := now() - interval '30 minutes'))->>'event_id';

  -- ═══ 1. Check-in tarde → EXACTAMENTE UNA multa (antes: dos) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_m::text)::text, true);
  v_result := public.check_in_participant(v_event::uuid);
  if (v_result->'rules'->>'rules_matched')::integer < 1 then
    raise exception 'r9_h 1: el retorno síncrono perdió rules_matched (semántica rota): %', v_result;
  end if;

  select count(*) into v_n from public.obligations
   where context_actor_id = v_ctx::uuid and debtor_actor_id = a_m and obligation_type = 'fine';
  if v_n <> 1 then
    raise exception 'r9_h 1: esperaba exactamente 1 multa, hay % (doble eval no deduplicada)', v_n;
  end if;

  select count(*) into v_n from public.rule_evaluations re
   join public.rules r on r.id = re.rule_id
   where r.context_actor_id = v_ctx::uuid and re.outcome = 'matched';
  if v_n <> 1 then
    raise exception 'r9_h 1: esperaba exactamente 1 rule_evaluation matched, hay %', v_n;
  end if;

  -- ═══ 2. Vista de balances con security_invoker: miembro ve, extraño no ═══
  -- Patrón r2j: el smoke es SECURITY DEFINER (owner de las tablas → RLS no le
  -- aplica y SET ROLE está prohibido dentro de security definer), así que se
  -- valida (a) estructuralmente que la vista es security_invoker y (b) la
  -- expresión de la policy ledger_entries_read con el JWT de cada actor.
  if not exists (
    select 1 from pg_class
    where oid = 'public.actor_money_balances'::regclass
      and exists (select 1 from unnest(coalesce(reloptions, '{}'::text[])) o
                  where o in ('security_invoker=true', 'security_invoker=on', 'security_invoker=1'))
  ) then
    raise exception 'r9_h 2: actor_money_balances no quedó con security_invoker = true';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  perform public.record_expense(v_ctx::uuid, 300, 'MXN', 'r9h gasto');
  select count(*) into v_n from public.ledger_entries where context_actor_id = v_ctx::uuid;
  if v_n < 1 then
    raise exception 'r9_h 2: el gasto no emitió ledger entries';
  end if;

  -- Miembro: pasa la policy del ledger → vía la vista invoker SÍ ve balances.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_m::text)::text, true);
  if not (public.is_context_member(v_ctx::uuid) or v_ctx::uuid = public.current_actor_id()) then
    raise exception 'r9_h 2: miembro no pasa la policy del ledger (invoker rompió visibilidad)';
  end if;

  -- NO-miembro: la policy lo excluye → vía la vista invoker ve cero filas.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_x::text)::text, true);
  if (public.is_context_member(v_ctx::uuid) or v_ctx::uuid = public.current_actor_id()) then
    raise exception 'r9_h 2: un NO-miembro pasa la policy del ledger (fuga RLS)';
  end if;

  -- anon: sin SELECT ni en la vista ni en la tabla base.
  if has_table_privilege('anon', 'public.actor_money_balances', 'SELECT')
     or has_table_privilege('anon', 'public.ledger_entries', 'SELECT') then
    raise exception 'r9_h 2: anon tiene SELECT en balances/ledger';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_admin, a_m, a_x], array[u_admin, u_m, u_x]);

  raise notice '_smoke_mvp2_r9_h_rule_eval_dedup passed (1 multa exacta, retorno síncrono intacto, invoker view con RLS)';
end;
$$;
