-- ============================================================================
-- R.2G — DECISIONS DoD: community_vote resuelve conflictos + caso exacto
-- ============================================================================
-- Caso: el conflicto de R.2F (David vs Isaac, Casa Valle 10-12 julio) se
-- resuelve por votación comunitaria. David gana 3-2 (Abuelo se abstiene) →
-- execute_decision aplica las consecuencias: conflicto resuelto, David
-- approved, Isaac rejected.
--
-- Gaps corregidos (solo RPCs, cero schema — doctrina R.2):
--   1. vote_decision: emite activity 'decision.vote_cast' por cada voto;
--      el cierre (auto-finalize) emite 'decision.closed' con el resultado.
--   2. close_decision: NUEVO — cierra la votación explícitamente (tally +
--      ganador por pluralidad); repetido es no-op seguro.
--   3. execute_decision: CONSECUENCIAS AUTOMÁTICAS para reservation_dispute —
--      si el payload trae reservation_conflict_id + option_reservations, al
--      ejecutar: conflicto → resolved, reservación ganadora → approved,
--      perdedora → rejected, con provenance source_decision_id (FKs de R.2-5).
--      No duplica efectos (solo aplica si el conflicto sigue open).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. vote_decision v3: activity vote_cast + decision.closed en el cierre
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.vote_decision(
  p_decision_id uuid,
  p_vote text,
  p_option text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_vote_id uuid;
  v_members numeric;
  v_approve numeric;
  v_reject numeric;
  v_total_votes numeric;
  v_new_status text;
  v_option_tally jsonb;
  v_winning_option text;
  v_winning_votes numeric;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if p_vote not in ('approve', 'reject', 'abstain') then
    raise exception 'invalid vote: %', p_vote using errcode = '22023';
  end if;

  select * into v_d from public.decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.vote') then
    raise exception 'not authorized to vote in context %', v_d.context_actor_id using errcode = '42501';
  end if;
  if v_d.status <> 'open' then
    raise exception 'decision is %', v_d.status using errcode = '22023';
  end if;
  if v_d.closes_at is not null and v_d.closes_at <= now() then
    raise exception 'voting window closed' using errcode = '22023';
  end if;

  -- si la decisión tiene opciones, el voto debe traer una opción válida
  if v_d.payload ? 'options' and p_option is not null then
    if not (v_d.payload->'options') ? p_option then
      raise exception 'invalid option: % (valid: %)', p_option, v_d.payload->'options' using errcode = '22023';
    end if;
  end if;

  -- un voto por actor; votar dos veces actualiza el existente
  insert into public.decision_votes (decision_id, voter_actor_id, vote, metadata)
  values (p_decision_id, v_caller, p_vote,
          jsonb_strip_nulls(jsonb_build_object('option', p_option)))
  on conflict (decision_id, voter_actor_id)
  do update set vote = excluded.vote, voted_at = now(),
                metadata = excluded.metadata
  returning id into v_vote_id;

  -- R.2G activity: cada voto queda auditado
  perform public._emit_activity(v_d.context_actor_id, v_caller, 'decision.vote_cast', 'decision_vote', v_vote_id,
    jsonb_strip_nulls(jsonb_build_object('decision_id', p_decision_id, 'vote', p_vote, 'option', p_option)),
    p_decision_id := p_decision_id);

  select count(*) into v_members from public.actor_memberships
   where context_actor_id = v_d.context_actor_id and membership_status = 'active';
  v_members := greatest(v_members, 1);

  select coalesce(sum(weight) filter (where vote = 'approve'), 0),
         coalesce(sum(weight) filter (where vote = 'reject'), 0),
         coalesce(sum(weight), 0)
    into v_approve, v_reject, v_total_votes
    from public.decision_votes where decision_id = p_decision_id;

  -- tally por opción (si hay opciones)
  if v_d.payload ? 'options' then
    select coalesce(jsonb_object_agg(opt, votes), '{}'::jsonb) into v_option_tally
    from (
      select dv.metadata->>'option' as opt, sum(dv.weight) as votes
        from public.decision_votes dv
       where dv.decision_id = p_decision_id and dv.metadata->>'option' is not null
       group by dv.metadata->>'option'
    ) t;

    select opt, votes into v_winning_option, v_winning_votes
    from (
      select dv.metadata->>'option' as opt, sum(dv.weight) as votes
        from public.decision_votes dv
       where dv.decision_id = p_decision_id and dv.metadata->>'option' is not null
       group by dv.metadata->>'option'
       order by sum(dv.weight) desc limit 1
    ) w;

    -- gana cuando una opción tiene mayoría absoluta O todos los miembros ya votaron
    if v_winning_votes > v_members / 2.0
       or (v_total_votes >= v_members and v_winning_votes > 0) then
      v_new_status := 'approved';
    end if;
  else
    if v_approve > v_members / 2.0 then
      v_new_status := 'approved';
    elsif v_reject >= v_members / 2.0 and v_reject > 0 and (v_members - v_reject) < v_members / 2.0 then
      v_new_status := 'rejected';
    end if;
  end if;

  if v_new_status is not null then
    update public.decisions
       set status = v_new_status, decided_at = now(),
           result = jsonb_strip_nulls(jsonb_build_object(
             'approve', v_approve, 'reject', v_reject, 'members', v_members,
             'option_tally', v_option_tally, 'winning_option', v_winning_option))
     where id = p_decision_id;

    -- R.2G: el cierre de la votación se audita como decision.closed
    perform public._emit_activity(v_d.context_actor_id, v_caller, 'decision.closed', 'decision', p_decision_id,
      jsonb_strip_nulls(jsonb_build_object('status', v_new_status, 'winning_option', v_winning_option,
                                           'closed_by', 'auto_finalize')),
      p_decision_id := p_decision_id);
  end if;

  return jsonb_build_object(
    'decision_id', p_decision_id, 'my_vote', p_vote, 'my_option', p_option,
    'status', coalesce(v_new_status, 'open'),
    'tally', jsonb_strip_nulls(jsonb_build_object(
      'approve', v_approve, 'reject', v_reject, 'members', v_members,
      'option_tally', v_option_tally)));
end; $$;

revoke all on function public.vote_decision(uuid, text, text) from public, anon;
grant execute on function public.vote_decision(uuid, text, text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. close_decision: NUEVO — cierre explícito de la votación
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.close_decision(p_decision_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_members numeric;
  v_approve numeric;
  v_reject numeric;
  v_option_tally jsonb;
  v_winning_option text;
  v_new_status text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_d from public.decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.execute') then
    raise exception 'not authorized to close decisions' using errcode = '42501';
  end if;

  -- R.2G idempotencia: cerrar una decisión ya cerrada es no-op seguro
  if v_d.status <> 'open' then
    return jsonb_build_object('decision_id', p_decision_id, 'status', v_d.status,
      'winning_option', v_d.result->>'winning_option', 'already_closed', true);
  end if;

  select count(*) into v_members from public.actor_memberships
   where context_actor_id = v_d.context_actor_id and membership_status = 'active';
  v_members := greatest(v_members, 1);

  select coalesce(sum(weight) filter (where vote = 'approve'), 0),
         coalesce(sum(weight) filter (where vote = 'reject'), 0)
    into v_approve, v_reject
    from public.decision_votes where decision_id = p_decision_id;

  if v_d.payload ? 'options' then
    -- cierre por opciones: gana la pluralidad de los votos emitidos
    select coalesce(jsonb_object_agg(opt, votes), '{}'::jsonb) into v_option_tally
    from (
      select dv.metadata->>'option' as opt, sum(dv.weight) as votes
        from public.decision_votes dv
       where dv.decision_id = p_decision_id and dv.metadata->>'option' is not null
       group by dv.metadata->>'option'
    ) t;

    select opt into v_winning_option
    from (
      select dv.metadata->>'option' as opt, sum(dv.weight) as votes
        from public.decision_votes dv
       where dv.decision_id = p_decision_id and dv.metadata->>'option' is not null
       group by dv.metadata->>'option'
       order by sum(dv.weight) desc limit 1
    ) w;

    v_new_status := case when v_winning_option is not null then 'approved' else 'rejected' end;
  else
    v_new_status := case when v_approve > v_reject and v_approve > 0 then 'approved' else 'rejected' end;
  end if;

  update public.decisions
     set status = v_new_status, decided_at = now(), closes_at = coalesce(closes_at, now()),
         result = jsonb_strip_nulls(jsonb_build_object(
           'approve', v_approve, 'reject', v_reject, 'members', v_members,
           'option_tally', v_option_tally, 'winning_option', v_winning_option))
   where id = p_decision_id;

  perform public._emit_activity(v_d.context_actor_id, v_caller, 'decision.closed', 'decision', p_decision_id,
    jsonb_strip_nulls(jsonb_build_object('status', v_new_status, 'winning_option', v_winning_option,
                                         'closed_by', 'explicit_close')),
    p_decision_id := p_decision_id);

  return jsonb_build_object('decision_id', p_decision_id, 'status', v_new_status,
    'winning_option', v_winning_option,
    'tally', jsonb_strip_nulls(jsonb_build_object(
      'approve', v_approve, 'reject', v_reject, 'members', v_members, 'option_tally', v_option_tally)));
end; $$;

revoke all on function public.close_decision(uuid) from public, anon;
grant execute on function public.close_decision(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. execute_decision v2: consecuencias automáticas para reservation_dispute
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.execute_decision(p_decision_id uuid, p_result jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_winner_option text;
  v_winner_res uuid;
  v_loser_res uuid;
  v_conflict public.reservation_conflicts%rowtype;
  v_effects jsonb := '[]'::jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_d from public.decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.execute') then
    raise exception 'not authorized to execute decisions' using errcode = '42501';
  end if;

  -- R.2G idempotencia: ejecutar dos veces es no-op seguro (no duplica efectos)
  if v_d.status = 'executed' then
    return jsonb_build_object('decision_id', p_decision_id, 'status', 'executed', 'already_executed', true);
  end if;
  if v_d.status <> 'approved' then
    raise exception 'only approved decisions can be executed (status: %)', v_d.status using errcode = '22023';
  end if;

  -- ═══ R.2G consecuencias automáticas: reservation_dispute ═══
  -- Si la decisión trae el conflicto y el mapeo opción→reservación, ejecutar
  -- resuelve el conflicto: ganadora approved, perdedora rejected.
  v_winner_option := v_d.result->>'winning_option';
  if v_d.decision_type = 'reservation_dispute'
     and v_d.payload ? 'reservation_conflict_id'
     and v_winner_option is not null
     and v_d.payload->'option_reservations' ? v_winner_option then

    select * into v_conflict from public.reservation_conflicts
     where id = (v_d.payload->>'reservation_conflict_id')::uuid for update;

    -- no duplicar efectos: solo si el conflicto sigue abierto
    if v_conflict.id is not null and v_conflict.resolution_status = 'open' then
      v_winner_res := (v_d.payload->'option_reservations'->>v_winner_option)::uuid;
      v_loser_res := case when v_winner_res = v_conflict.reservation_a_id
                          then v_conflict.reservation_b_id else v_conflict.reservation_a_id end;

      -- perdedora rejected ANTES (libera el rango para el EXCLUDE constraint)
      update public.resource_reservations
         set status = 'rejected', source_decision_id = p_decision_id,
             metadata = metadata || jsonb_build_object('rejected_by_decision', p_decision_id)
       where id = v_loser_res and status in ('requested', 'approved');

      update public.resource_reservations
         set status = 'approved', source_decision_id = p_decision_id,
             metadata = metadata || jsonb_build_object('approved_by_decision', p_decision_id)
       where id = v_winner_res and status = 'requested';

      update public.reservation_conflicts
         set resolution_status = 'resolved', resolved_at = now(), source_decision_id = p_decision_id,
             metadata = metadata || jsonb_build_object('resolved_by_decision', p_decision_id,
                                                       'winner_reservation_id', v_winner_res)
       where id = v_conflict.id;

      -- activity: las reservaciones cambiaron por la decisión comunitaria
      perform public._emit_activity(v_d.context_actor_id, v_caller, 'reservation.approved',
        'reservation', v_winner_res,
        jsonb_build_object('by_decision', p_decision_id, 'winning_option', v_winner_option),
        p_resource_id := v_conflict.resource_id, p_decision_id := p_decision_id);
      perform public._emit_activity(v_d.context_actor_id, v_caller, 'reservation.rejected',
        'reservation', v_loser_res,
        jsonb_build_object('by_decision', p_decision_id),
        p_resource_id := v_conflict.resource_id, p_decision_id := p_decision_id);

      v_effects := jsonb_build_array(
        jsonb_build_object('type', 'conflict_resolved', 'conflict_id', v_conflict.id),
        jsonb_build_object('type', 'reservation_approved', 'reservation_id', v_winner_res),
        jsonb_build_object('type', 'reservation_rejected', 'reservation_id', v_loser_res));
    end if;
  end if;

  update public.decisions
     set status = 'executed', executed_at = now(),
         result = result || coalesce(p_result, '{}'::jsonb)
                  || jsonb_build_object('executed_by_actor_id', v_caller, 'effects', v_effects)
   where id = p_decision_id;

  perform public._emit_activity(v_d.context_actor_id, v_caller, 'decision.executed', 'decision', p_decision_id,
    jsonb_build_object('effects', v_effects), p_decision_id := p_decision_id);

  return jsonb_build_object('decision_id', p_decision_id, 'status', 'executed', 'effects', v_effects);
end; $$;

revoke all on function public.execute_decision(uuid, jsonb) from public, anon;
grant execute on function public.execute_decision(uuid, jsonb) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Smoke R.2G — caso exacto del founder
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2g_decisions_dod()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_abuelo uuid; a_abuelo uuid;
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  u_moises uuid; a_moises uuid;
  u_daniel uuid; a_daniel uuid;
  u_out uuid; a_out uuid;
  v_ctx uuid; v_casa uuid; v_code text;
  v_res_david uuid; v_res_isaac uuid;
  v_conflict_id uuid;
  v_decision uuid; v_decision2 uuid;
  v_result jsonb;
  v_starts timestamptz := '2026-07-10 16:00-06'::timestamptz;
  v_ends timestamptz := '2026-07-12 18:00-06'::timestamptz;
  v_caught boolean;
  v_fn text;
begin
  -- ═══ Setup: Familia Mizrahi (6 miembros) + conflicto de R.2F ═══
  select auth_id, actor_id into u_abuelo, a_abuelo from public._r2_make_person('Abuelo R2G', '+5210000070');
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2G', '+5210000071');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2G', '+5210000072');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2G', '+5210000073');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés R2G', '+5210000074');
  select auth_id, actor_id into u_daniel, a_daniel from public._r2_make_person('Daniel R2G', '+5210000075');
  select auth_id, actor_id into u_out, a_out from public._r2_make_person('Outsider R2G', '+5210000076');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_ctx := (public.create_context('Familia Mizrahi', 'collective', 'family'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
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

  -- Casa Valle + rights + el conflicto de R.2F (David e Isaac, 10-12 julio)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_casa := (public.create_resource(a_abuelo, 'house', 'Casa Valle'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, v_ctx::uuid, 'GOVERN');
  perform public.grant_right(v_casa::uuid, a_david, 'USE');
  perform public.grant_right(v_casa::uuid, a_isaac, 'USE');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_res_david := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid, v_starts, v_ends))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_res_isaac := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid, v_starts, v_ends))->>'reservation_id';

  select id into v_conflict_id from public.reservation_conflicts
   where resource_id = v_casa::uuid and resolution_status = 'open';
  if v_conflict_id is null then raise exception 'R2G FAIL setup: no existe el conflicto de R.2F'; end if;

  -- ═══ 1-2. Se crea la decisión (community_vote) y se abre la votación ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_decision := (public.create_decision(v_ctx::uuid, 'reservation_dispute',
    '¿Quién debe recibir Casa Valle del 10 al 12 de julio?',
    p_payload := jsonb_build_object(
      'resolution_mode', 'community_vote',
      'reservation_conflict_id', v_conflict_id,
      'resource_id', v_casa,
      'reservation_a_id', v_res_david,
      'reservation_b_id', v_res_isaac,
      'options', jsonb_build_array('David', 'Isaac'),
      'option_reservations', jsonb_build_object('David', v_res_david, 'Isaac', v_res_isaac))
    ))->>'decision_id';
  if v_decision is null then raise exception 'R2G FAIL 1: decisión no creada'; end if;
  if (select status from public.decisions where id = v_decision::uuid) <> 'open' then
    raise exception 'R2G FAIL 2: la votación no quedó abierta';
  end if;

  -- ═══ 3. José vota David (y repetir actualiza el mismo voto) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.vote_decision(v_decision::uuid, 'approve', 'David');
  -- Idempotencia: votar dos veces actualiza el voto existente, no crea otro
  perform public.vote_decision(v_decision::uuid, 'approve', 'David');
  if (select count(*) from public.decision_votes where decision_id = v_decision::uuid) <> 1 then
    raise exception 'R2G FAIL idempotencia: votar dos veces creó dos votos';
  end if;

  -- ═══ 4. Daniel vota David ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.vote_decision(v_decision::uuid, 'approve', 'David');

  -- ═══ 5. Moisés vota Isaac ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.vote_decision(v_decision::uuid, 'approve', 'Isaac');

  -- ═══ 6. Abuelo se abstiene ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  perform public.vote_decision(v_decision::uuid, 'abstain');

  -- ═══ 7. Isaac vota Isaac ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_result := public.vote_decision(v_decision::uuid, 'approve', 'Isaac');
  if v_result->>'status' <> 'open' then
    raise exception 'R2G FAIL 7: la decisión cerró antes de que todos votaran (%)', v_result->>'status';
  end if;

  -- ═══ 8. David vota David → todos votaron → cierra con ganador David ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.vote_decision(v_decision::uuid, 'approve', 'David');
  if v_result->>'status' <> 'approved' then
    raise exception 'R2G FAIL 8: la decisión no cerró al votar todos (%)', v_result->>'status';
  end if;

  -- ═══ Resultado: David 3, Isaac 2, Abuelo abstain, winner David ═══
  if (select (result->'option_tally'->>'David')::numeric from public.decisions where id = v_decision::uuid) <> 3 then
    raise exception 'R2G FAIL resultado: David debió tener 3 votos';
  end if;
  if (select (result->'option_tally'->>'Isaac')::numeric from public.decisions where id = v_decision::uuid) <> 2 then
    raise exception 'R2G FAIL resultado: Isaac debió tener 2 votos';
  end if;
  if (select result->>'winning_option' from public.decisions where id = v_decision::uuid) <> 'David' then
    raise exception 'R2G FAIL resultado: el ganador debió ser David';
  end if;
  if not exists (select 1 from public.decision_votes
                 where decision_id = v_decision::uuid and voter_actor_id = a_abuelo and vote = 'abstain') then
    raise exception 'R2G FAIL resultado: la abstención del Abuelo no quedó registrada';
  end if;

  -- ═══ 9. close_decision() — ya cerrada por auto-finalize → no-op seguro ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_result := public.close_decision(v_decision::uuid);
  if not coalesce((v_result->>'already_closed')::boolean, false) then
    raise exception 'R2G FAIL 9: close sobre decisión cerrada no fue no-op';
  end if;
  -- repetido sigue siendo no-op
  v_result := public.close_decision(v_decision::uuid);
  if not coalesce((v_result->>'already_closed')::boolean, false) then
    raise exception 'R2G FAIL idempotencia: close repetido no fue no-op';
  end if;

  -- ═══ 10. execute_decision() → consecuencias automáticas ═══
  v_result := public.execute_decision(v_decision::uuid);
  if v_result->>'status' <> 'executed' then
    raise exception 'R2G FAIL 10: execute falló';
  end if;

  -- Consecuencias: conflicto resuelto, David approved, Isaac rejected
  if (select resolution_status from public.reservation_conflicts where id = v_conflict_id) <> 'resolved' then
    raise exception 'R2G FAIL consecuencias: el conflicto no quedó resolved';
  end if;
  if (select source_decision_id from public.reservation_conflicts where id = v_conflict_id) is distinct from v_decision::uuid then
    raise exception 'R2G FAIL consecuencias: el conflicto no apunta a la decisión (provenance)';
  end if;
  if (select status from public.resource_reservations where id = v_res_david::uuid) <> 'approved' then
    raise exception 'R2G FAIL consecuencias: la reservación de David no quedó approved';
  end if;
  if (select source_decision_id from public.resource_reservations where id = v_res_david::uuid) is distinct from v_decision::uuid then
    raise exception 'R2G FAIL consecuencias: la reservación de David sin provenance de la decisión';
  end if;
  if (select status from public.resource_reservations where id = v_res_isaac::uuid) <> 'rejected' then
    raise exception 'R2G FAIL consecuencias: la reservación de Isaac no quedó rejected';
  end if;

  -- Idempotencia: execute repetido es no-op y NO duplica efectos
  v_result := public.execute_decision(v_decision::uuid);
  if not coalesce((v_result->>'already_executed')::boolean, false) then
    raise exception 'R2G FAIL idempotencia: execute repetido no fue no-op';
  end if;
  if (select status from public.resource_reservations where id = v_res_david::uuid) <> 'approved'
     or (select status from public.resource_reservations where id = v_res_isaac::uuid) <> 'rejected'
     or (select resolution_status from public.reservation_conflicts where id = v_conflict_id) <> 'resolved' then
    raise exception 'R2G FAIL idempotencia: execute repetido alteró los efectos';
  end if;
  -- las activities de reservación no se duplicaron
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'reservation.approved'
        and subject_id = v_res_david::uuid) <> 1 then
    raise exception 'R2G FAIL idempotencia: reservation.approved duplicada';
  end if;

  -- ═══ Auditoría (activity_events) ═══
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'decision.created'
        and subject_id = v_decision::uuid) <> 1 then
    raise exception 'R2G FAIL activity: decision.created debe ser 1';
  end if;
  -- vote_cast: 6 votos + 1 repetido de José = 7
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'decision.vote_cast'
        and (payload->>'decision_id')::uuid = v_decision::uuid) <> 7 then
    raise exception 'R2G FAIL activity: decision.vote_cast debe ser 7 (6 votos + 1 actualización)';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'decision.closed'
        and subject_id = v_decision::uuid) <> 1 then
    raise exception 'R2G FAIL activity: decision.closed debe ser 1';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'decision.executed'
        and subject_id = v_decision::uuid) <> 1 then
    raise exception 'R2G FAIL activity: decision.executed debe ser 1';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'reservation.rejected'
        and subject_id = v_res_isaac::uuid) <> 1 then
    raise exception 'R2G FAIL activity: reservation.rejected debe ser 1';
  end if;

  -- ═══ Permisos (sobre una segunda decisión abierta) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_decision2 := (public.create_decision(v_ctx::uuid, 'generic', 'R2G decisión de permisos',
    p_payload := jsonb_build_object('options', jsonb_build_array('David', 'Isaac'))))->>'decision_id';

  -- No-miembro no puede votar
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin
    perform public.vote_decision(v_decision2::uuid, 'approve', 'David');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2G FAIL permisos: no-miembro pudo votar'; end if;

  -- Miembro removido no puede votar
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  perform public.remove_member(v_ctx::uuid, a_daniel, 'prueba R2G');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_caught := false;
  begin
    perform public.vote_decision(v_decision2::uuid, 'approve', 'David');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2G FAIL permisos: miembro removido pudo votar'; end if;

  -- ═══ close_decision explícito (camino real): 1 voto → cierre → ganador por pluralidad ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.vote_decision(v_decision2::uuid, 'approve', 'David');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_result := public.close_decision(v_decision2::uuid);
  if v_result->>'status' <> 'approved' or v_result->>'winning_option' <> 'David' then
    raise exception 'R2G FAIL close: cierre explícito no determinó al ganador (% / %)',
      v_result->>'status', v_result->>'winning_option';
  end if;
  -- José (member, sin decisions.execute) no puede cerrar decisiones
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_caught := false;
  begin
    perform public.close_decision(v_decision2::uuid);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2G FAIL permisos: member pudo cerrar decisión'; end if;

  -- ═══ Anon bloqueado ═══
  foreach v_fn in array array[
    'public.create_decision(uuid, text, text, text, timestamptz, jsonb, text)',
    'public.vote_decision(uuid, text, text)',
    'public.close_decision(uuid)',
    'public.execute_decision(uuid, jsonb)'
  ] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'R2G FAIL permisos: anon puede ejecutar %', v_fn;
    end if;
  end loop;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_abuelo, a_jose, a_david, a_isaac, a_moises, a_daniel, a_out],
    array[u_abuelo, u_jose, u_david, u_isaac, u_moises, u_daniel, u_out]);

  raise notice 'R.2G DECISIONS DoD: PASS (David 3-2, conflicto resuelto por votación, reservaciones actualizadas, auditoría completa)';
end; $$;

revoke all on function public._smoke_r2g_decisions_dod() from public, anon, authenticated;

comment on function public._smoke_r2g_decisions_dod() is
  'R.2G DoD exacto: conflicto de R.2F → decisión community_vote → David 3, Isaac 2, Abuelo abstain → execute → conflicto resolved, David approved, Isaac rejected → auditoría → permisos → idempotencia.';

-- Wrapper para CI (descubre funciones _smoke_mvp2_%)
create or replace function public._smoke_mvp2_r2g_decisions_dod()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._smoke_r2g_decisions_dod();
end; $$;

revoke all on function public._smoke_mvp2_r2g_decisions_dod() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2g_decisions_dod() is
  'Wrapper CI del smoke R.2G (_smoke_r2g_decisions_dod).';
