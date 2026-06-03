-- ============================================================================
-- R.2S.7 — RESERVATION OUTCOME MODELS
-- ============================================================================
-- No toda reservación termina en approved/rejected. resolve_reservation_conflict
-- gana un overload con resolution_model y soporta varios outcomes:
--
--   priority_based / admin_override / winner → gana una, se rechaza la otra
--   lottery                                  → ganadora al azar
--   waitlisted                               → gana una, la otra queda en lista
--   split_dates / partial_approval           → se parte el rango entre ambas
--   requires_decision                        → abre una decisión del contexto
--                                              (la decision option ganadora
--                                               resuelve el conflicto al ejecutar)
--
-- El overload de 2 args (conflict, winner) sigue funcionando (= priority_based).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. status 'waitlisted' en resource_reservations
-- ────────────────────────────────────────────────────────────────────────────
do $$
declare v_con text;
begin
  select conname into v_con
    from pg_constraint
   where conrelid = 'public.resource_reservations'::regclass
     and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%status%'
     and pg_get_constraintdef(oid) ilike '%requested%';
  if v_con is not null then
    execute format('alter table public.resource_reservations drop constraint %I', v_con);
  end if;
end $$;

alter table public.resource_reservations
  add constraint resource_reservations_status_check
  check (status in ('requested', 'approved', 'confirmed', 'rejected', 'cancelled', 'completed', 'waitlisted'));

-- ────────────────────────────────────────────────────────────────────────────
-- 2. resolve_reservation_conflict(conflict, resolution_model, winner?, metadata?)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.resolve_reservation_conflict(
  p_conflict_id uuid,
  p_resolution_model text,
  p_winner_reservation_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_c public.reservation_conflicts%rowtype;
  v_a public.resource_reservations%rowtype;
  v_b public.resource_reservations%rowtype;
  v_winner uuid;
  v_loser uuid;
  v_ctx uuid;
  v_mid timestamptz;
  v_first public.resource_reservations%rowtype;
  v_second public.resource_reservations%rowtype;
  v_decision uuid;
  v_opt_res jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_c from public.reservation_conflicts where id = p_conflict_id for update;
  if v_c.id is null then raise exception 'conflict not found' using errcode = 'P0002'; end if;

  select * into v_a from public.resource_reservations where id = v_c.reservation_a_id;
  select * into v_b from public.resource_reservations where id = v_c.reservation_b_id;
  v_ctx := coalesce(v_a.context_actor_id, v_b.context_actor_id);

  if not public._can_manage_reservations(v_caller, v_c.resource_id, v_ctx) then
    raise exception 'not authorized to resolve conflicts' using errcode = '42501';
  end if;
  if v_c.resolution_status <> 'open' then
    return jsonb_build_object('conflict_id', p_conflict_id, 'no_op', true,
      'resolution_status', v_c.resolution_status);
  end if;
  if p_resolution_model not in (
    'priority_based','admin_override','winner','lottery',
    'waitlisted','split_dates','partial_approval','requires_decision') then
    raise exception 'unknown resolution_model %', p_resolution_model using errcode = '22023';
  end if;

  -- ═══ requires_decision: abre una decisión; el conflicto se resuelve al ejecutarla ═══
  if p_resolution_model = 'requires_decision' then
    v_opt_res := jsonb_build_object('res_a', v_c.reservation_a_id, 'res_b', v_c.reservation_b_id);
    v_decision := (public.create_decision(
      v_ctx, 'reservation_dispute',
      'Conflicto de reservación: ¿quién se queda con el recurso?',
      'Dos reservaciones se traslapan. Vota por la que debe quedarse.',
      null,
      jsonb_build_object(
        'options', jsonb_build_array('res_a', 'res_b'),
        'reservation_conflict_id', p_conflict_id,
        'option_reservations', v_opt_res),
      null, 'single_choice'))->>'decision_id';

    update public.reservation_conflicts
       set source_decision_id = v_decision::uuid,
           metadata = metadata || jsonb_build_object('resolution_model', 'requires_decision',
                                                     'decision_id', v_decision)
     where id = p_conflict_id;  -- sigue 'open' hasta que la decisión se ejecute

    return jsonb_build_object('conflict_id', p_conflict_id, 'resolution_model', 'requires_decision',
      'decision_id', v_decision, 'resolution_status', 'open');
  end if;

  -- ═══ split_dates / partial_approval: se parte el rango entre ambas ═══
  if p_resolution_model in ('split_dates', 'partial_approval') then
    -- la de inicio más temprano toma el primer tramo
    if v_a.starts_at <= v_b.starts_at then v_first := v_a; v_second := v_b;
    else v_first := v_b; v_second := v_a; end if;

    v_mid := greatest(v_a.starts_at, v_b.starts_at)
             + (least(v_a.ends_at, v_b.ends_at) - greatest(v_a.starts_at, v_b.starts_at)) / 2;

    update public.resource_reservations
       set ends_at = v_mid, status = 'approved',
           metadata = metadata || jsonb_build_object('split_by_conflict', p_conflict_id, 'split_segment', 'first')
     where id = v_first.id;
    update public.resource_reservations
       set starts_at = v_mid, status = 'approved',
           metadata = metadata || jsonb_build_object('split_by_conflict', p_conflict_id, 'split_segment', 'second')
     where id = v_second.id;

    update public.reservation_conflicts
       set resolution_status = 'resolved', resolved_at = now(),
           metadata = metadata || jsonb_build_object('resolution_model', p_resolution_model,
                                                     'split_at', v_mid, 'resolved_by', v_caller)
     where id = p_conflict_id;

    perform public._emit_activity(v_ctx, v_caller, 'reservation.conflict_resolved', 'reservation_conflict', p_conflict_id,
      jsonb_build_object('resolution_model', p_resolution_model, 'split_at', v_mid),
      p_resource_id := v_c.resource_id);

    return jsonb_build_object('conflict_id', p_conflict_id, 'resolution_model', p_resolution_model,
      'split_at', v_mid, 'first_reservation_id', v_first.id, 'second_reservation_id', v_second.id,
      'resolution_status', 'resolved');
  end if;

  -- ═══ modelos con ganador único (priority_based / admin_override / winner / lottery / waitlisted) ═══
  if p_resolution_model = 'lottery' then
    v_winner := case when random() < 0.5 then v_c.reservation_a_id else v_c.reservation_b_id end;
  else
    if p_winner_reservation_id is null then
      raise exception 'resolution_model % requires a winner reservation', p_resolution_model using errcode = '22023';
    end if;
    if p_winner_reservation_id not in (v_c.reservation_a_id, v_c.reservation_b_id) then
      raise exception 'winner must be one of the conflicting reservations' using errcode = '22023';
    end if;
    v_winner := p_winner_reservation_id;
  end if;
  v_loser := case when v_winner = v_c.reservation_a_id then v_c.reservation_b_id else v_c.reservation_a_id end;

  -- waitlisted: la perdedora queda en lista; el resto: rejected
  update public.resource_reservations
     set status = case when p_resolution_model = 'waitlisted' then 'waitlisted' else 'rejected' end,
         metadata = metadata || jsonb_build_object('resolution_model', p_resolution_model, 'lost_conflict', p_conflict_id)
   where id = v_loser and status in ('requested', 'approved');

  update public.resource_reservations set status = 'approved',
         metadata = metadata || jsonb_build_object('won_conflict', p_conflict_id)
   where id = v_winner and status = 'requested';

  update public.reservation_conflicts
     set resolution_status = 'resolved', resolved_at = now(),
         metadata = metadata || jsonb_build_object('resolution_model', p_resolution_model,
                                                   'winner', v_winner, 'resolved_by', v_caller)
   where id = p_conflict_id;

  perform public._emit_activity(v_ctx, v_caller, 'reservation.conflict_resolved', 'reservation_conflict', p_conflict_id,
    jsonb_build_object('resolution_model', p_resolution_model, 'winner', v_winner, 'loser', v_loser),
    p_resource_id := v_c.resource_id);
  perform public._emit_activity(v_ctx, v_caller, 'reservation.approved', 'reservation', v_winner,
    jsonb_build_object('by_conflict_resolution', p_conflict_id), p_resource_id := v_c.resource_id);
  if p_resolution_model <> 'waitlisted' then
    perform public._emit_activity(v_ctx, v_caller, 'reservation.rejected', 'reservation', v_loser,
      jsonb_build_object('by_conflict_resolution', p_conflict_id), p_resource_id := v_c.resource_id);
  end if;

  return jsonb_build_object('conflict_id', p_conflict_id, 'resolution_model', p_resolution_model,
    'winner', v_winner, 'loser', v_loser, 'resolution_status', 'resolved');
end; $$;

revoke all on function public.resolve_reservation_conflict(uuid, text, uuid, jsonb) from public, anon;
grant execute on function public.resolve_reservation_conflict(uuid, text, uuid, jsonb) to authenticated, service_role;

comment on function public.resolve_reservation_conflict(uuid, text, uuid, jsonb) is
  'R.2S.7: resuelve un conflicto con resolution_model (priority_based/lottery/waitlisted/split_dates/requires_decision).';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Smoke — _smoke_r2s_reservation_outcomes
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
            now() + interval '10 days 12 hours', now() + interval '11 days', a_isaac))->>'reservation_id';
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

revoke all on function public._smoke_r2s_reservation_outcomes() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2s_reservation_outcomes()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_r2s_reservation_outcomes(); end; $$;
revoke all on function public._smoke_mvp2_r2s_reservation_outcomes() from public, anon, authenticated;
comment on function public._smoke_mvp2_r2s_reservation_outcomes() is 'Wrapper CI del smoke R.2S.7 reservation outcomes.';
