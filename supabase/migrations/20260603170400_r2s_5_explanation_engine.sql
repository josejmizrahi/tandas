-- ============================================================================
-- R.2S.10 — EXPLANATION ENGINE
-- ============================================================================
-- Toda acción importante puede explicarse. why_obligation_exists ya existe
-- (R.2R). Esta slice agrega el resto:
--
--   why_can_view_resource(actor_id, resource_id) → por qué veo (o no) el recurso
--   why_can_reserve(actor_id, resource_id)       → por qué puedo (o no) reservar
--   why_reservation_won(conflict_id)             → por qué ganó esa reservación
--   why_decision_result(decision_id)             → conteo y resultado
--
-- Forma común: { ..._flags booleanos, reasons: [text] } — el frontend muestra
-- la explicación tal cual, sin reconstruir la lógica.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. why_can_view_resource(actor_id, resource_id)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.why_can_view_resource(p_actor_id uuid, p_resource_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_res public.resources%rowtype;
  v_reasons jsonb := '[]'::jsonb;
  v_can boolean;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_res from public.resources where id = p_resource_id;
  if v_res.id is null then raise exception 'resource not found' using errcode = 'P0002'; end if;
  -- solo se puede preguntar por un recurso que el caller ve, o por uno mismo
  if v_caller <> p_actor_id and not public._actor_can_view_resource(v_caller, p_resource_id) then
    raise exception 'not authorized to explain this resource' using errcode = '42501';
  end if;

  v_can := public._actor_can_view_resource(p_actor_id, p_resource_id);

  -- a) canonical owner
  if v_res.canonical_owner_actor_id = p_actor_id then
    v_reasons := v_reasons || to_jsonb('Es el dueño canónico del recurso (OWN dominante)'::text);
  end if;
  -- b) holder directo de un right activo
  if exists (
    select 1 from public.resource_rights rr
    where rr.resource_id = p_resource_id and rr.holder_actor_id = p_actor_id
      and rr.revoked_at is null and rr.expired_at is null
      and (rr.starts_at is null or rr.starts_at <= now())
      and (rr.ends_at is null or rr.ends_at > now())
  ) then
    v_reasons := v_reasons || (
      select jsonb_agg(('Tiene el derecho ' || rr.right_kind || ' sobre el recurso')::text)
        from public.resource_rights rr
       where rr.resource_id = p_resource_id and rr.holder_actor_id = p_actor_id
         and rr.revoked_at is null and rr.expired_at is null
         and (rr.starts_at is null or rr.starts_at <= now())
         and (rr.ends_at is null or rr.ends_at > now()));
  end if;
  -- c) autoridad sobre un holder colectivo
  if exists (
    select 1 from public.resource_rights rr
    where rr.resource_id = p_resource_id and rr.holder_actor_id <> p_actor_id
      and rr.revoked_at is null and rr.expired_at is null
      and (rr.starts_at is null or rr.starts_at <= now())
      and (rr.ends_at is null or rr.ends_at > now())
      and public.has_actor_authority(rr.holder_actor_id, p_actor_id, 'resources.manage')
  ) then
    v_reasons := v_reasons || to_jsonb('Puede administrar un holder colectivo del recurso (resources.manage)'::text);
  end if;

  if not v_can then
    v_reasons := to_jsonb(array['No tiene ningún derecho activo ni autoridad sobre un holder del recurso']);
  end if;

  return jsonb_build_object(
    'actor_id', p_actor_id,
    'resource_id', p_resource_id,
    'can_view', v_can,
    'reasons', v_reasons);
end; $$;

revoke all on function public.why_can_view_resource(uuid, uuid) from public, anon;
grant execute on function public.why_can_view_resource(uuid, uuid) to authenticated, service_role;

comment on function public.why_can_view_resource(uuid, uuid) is
  'R.2S.10: explica por qué un actor ve (o no) un recurso (owner, right directo, autoridad sobre holder).';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. why_can_reserve(actor_id, resource_id)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.why_can_reserve(p_actor_id uuid, p_resource_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_res public.resources%rowtype;
  v_reasons jsonb := '[]'::jsonb;
  v_reservable boolean;
  v_has_right boolean;
  v_can boolean;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_res from public.resources where id = p_resource_id;
  if v_res.id is null then raise exception 'resource not found' using errcode = 'P0002'; end if;
  if v_caller <> p_actor_id and not public._actor_can_view_resource(v_caller, p_resource_id) then
    raise exception 'not authorized to explain this resource' using errcode = '42501';
  end if;

  v_reservable := public.resource_can(p_resource_id, 'reservable');
  v_has_right := public.actor_has_right(p_actor_id, p_resource_id, 'USE')
              or public.actor_has_right(p_actor_id, p_resource_id, 'MANAGE')
              or public.actor_has_right(p_actor_id, p_resource_id, 'OWN')
              or public._can_manage_reservations(p_actor_id, p_resource_id, v_res.canonical_owner_actor_id);
  v_can := v_reservable and v_has_right;

  if not v_reservable then
    v_reasons := v_reasons || to_jsonb(
      ('El tipo "' || v_res.resource_type || '" no tiene la capability reservable')::text);
  else
    v_reasons := v_reasons || to_jsonb('El recurso es reservable'::text);
  end if;
  if v_reservable and not v_has_right then
    v_reasons := v_reasons || to_jsonb('Falta un derecho USE, MANAGE u OWN (o autoridad para administrar reservaciones)'::text);
  elsif v_has_right then
    v_reasons := v_reasons || to_jsonb('Tiene un derecho que habilita reservar'::text);
  end if;

  return jsonb_build_object(
    'actor_id', p_actor_id,
    'resource_id', p_resource_id,
    'can_reserve', v_can,
    'required_capability', 'reservable',
    'reasons', v_reasons);
end; $$;

revoke all on function public.why_can_reserve(uuid, uuid) from public, anon;
grant execute on function public.why_can_reserve(uuid, uuid) to authenticated, service_role;

comment on function public.why_can_reserve(uuid, uuid) is
  'R.2S.10: explica por qué un actor puede (o no) reservar: capability reservable + derecho de uso.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. why_reservation_won(conflict_id)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.why_reservation_won(p_conflict_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_c public.reservation_conflicts%rowtype;
  v_winner uuid;
  v_ctx uuid;
  v_reasons jsonb := '[]'::jsonb;
  v_a public.resource_reservations%rowtype;
  v_b public.resource_reservations%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_c from public.reservation_conflicts where id = p_conflict_id;
  if v_c.id is null then raise exception 'conflict not found' using errcode = 'P0002'; end if;

  select * into v_a from public.resource_reservations where id = v_c.reservation_a_id;
  select * into v_b from public.resource_reservations where id = v_c.reservation_b_id;
  v_ctx := coalesce(v_a.context_actor_id, v_b.context_actor_id);
  if not public.is_context_member(v_ctx)
     and not public._can_manage_reservations(v_caller, v_c.resource_id, v_ctx) then
    raise exception 'not authorized to explain this conflict' using errcode = '42501';
  end if;

  -- el ganador puede haberse guardado como 'winner' (resolución directa) o
  -- 'winner_reservation_id' (resolución vía decisión ejecutada)
  v_winner := coalesce(
    nullif(v_c.metadata->>'winner', '')::uuid,
    nullif(v_c.metadata->>'winner_reservation_id', '')::uuid);

  if v_c.resolution_status <> 'resolved' or v_winner is null then
    return jsonb_build_object(
      'conflict_id', p_conflict_id,
      'resolution_status', v_c.resolution_status,
      'winner_reservation_id', null,
      'reasons', to_jsonb(array['El conflicto aún no se resuelve']),
      'recommended_winner_actor_id', v_c.recommended_winner_actor_id);
  end if;

  -- cómo se resolvió
  if v_c.metadata ? 'resolution_model' then
    v_reasons := v_reasons || to_jsonb(('Modelo de resolución: ' || (v_c.metadata->>'resolution_model'))::text);
  end if;
  if v_c.source_decision_id is not null then
    v_reasons := v_reasons || to_jsonb('Se resolvió por una decisión del contexto (decision option ganadora)'::text);
  elsif v_c.metadata ? 'resolved_by' then
    v_reasons := v_reasons || to_jsonb('Lo resolvió un administrador con autoridad sobre las reservaciones'::text);
  end if;

  -- prioridad (least_recent_use_wins): menor recent_use_count gana
  if v_a.priority_score is not null and v_b.priority_score is not null then
    v_reasons := v_reasons || to_jsonb((
      'Prioridad por menor uso reciente: ganadora score ' ||
      (case when v_winner = v_a.id then v_a.priority_score else v_b.priority_score end)::text ||
      ' vs ' ||
      (case when v_winner = v_a.id then v_b.priority_score else v_a.priority_score end)::text)::text);
  end if;
  if v_c.recommended_winner_actor_id is not null then
    v_reasons := v_reasons || to_jsonb('El motor de conflictos había recomendado a este actor'::text);
  end if;

  return jsonb_build_object(
    'conflict_id', p_conflict_id,
    'resolution_status', v_c.resolution_status,
    'winner_reservation_id', v_winner,
    'winner_actor_id', (select reserved_for_actor_id from public.resource_reservations where id = v_winner),
    'recommended_winner_actor_id', v_c.recommended_winner_actor_id,
    'reasons', v_reasons);
end; $$;

revoke all on function public.why_reservation_won(uuid) from public, anon;
grant execute on function public.why_reservation_won(uuid) to authenticated, service_role;

comment on function public.why_reservation_won(uuid) is
  'R.2S.10: explica por qué ganó una reservación en un conflicto (prioridad por uso, decisión, override admin).';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. why_decision_result(decision_id)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.why_decision_result(p_decision_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_approve numeric; v_reject numeric; v_abstain numeric;
  v_members numeric;
  v_reasons jsonb := '[]'::jsonb;
  v_option_tally jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_d from public.decisions where id = p_decision_id;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.is_context_member(v_d.context_actor_id) then
    raise exception 'not authorized to explain this decision' using errcode = '42501';
  end if;

  select coalesce(sum(weight) filter (where vote = 'approve'), 0),
         coalesce(sum(weight) filter (where vote = 'reject'), 0),
         coalesce(sum(weight) filter (where vote = 'abstain'), 0)
    into v_approve, v_reject, v_abstain
    from public.decision_votes where decision_id = p_decision_id;

  select count(*) into v_members from public.actor_memberships
   where context_actor_id = v_d.context_actor_id and membership_status = 'active';

  -- tally por opción (cuando la decisión tiene options)
  select coalesce(jsonb_object_agg(opt, votes), '{}'::jsonb) into v_option_tally
  from (
    select coalesce(o.title, dv.metadata->>'option') as opt, sum(dv.weight) as votes
      from public.decision_votes dv
      left join public.decision_options o on o.id = dv.option_id
     where dv.decision_id = p_decision_id
       and (dv.option_id is not null or dv.metadata->>'option' is not null)
     group by coalesce(o.title, dv.metadata->>'option')
  ) t;

  v_reasons := v_reasons || to_jsonb(('Modelo de votación: ' || v_d.voting_model)::text);
  v_reasons := v_reasons || to_jsonb((
    'Conteo: ' || v_approve::text || ' a favor, ' || v_reject::text || ' en contra, ' ||
    v_abstain::text || ' abstención sobre ' || v_members::text || ' miembros')::text);
  if v_d.result ? 'winning_option' then
    v_reasons := v_reasons || to_jsonb(('Opción ganadora: ' || (v_d.result->>'winning_option'))::text);
  end if;
  v_reasons := v_reasons || to_jsonb(('Estado actual: ' || v_d.status)::text);

  return jsonb_build_object(
    'decision_id', p_decision_id,
    'status', v_d.status,
    'voting_model', v_d.voting_model,
    'tally', jsonb_build_object('approve', v_approve, 'reject', v_reject, 'abstain', v_abstain),
    'option_tally', v_option_tally,
    'active_members', v_members,
    'result', v_d.result,
    'reasons', v_reasons);
end; $$;

revoke all on function public.why_decision_result(uuid) from public, anon;
grant execute on function public.why_decision_result(uuid) to authenticated, service_role;

comment on function public.why_decision_result(uuid) is
  'R.2S.10: explica el resultado de una decisión: modelo, conteo, opción ganadora, estado.';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Smoke — _smoke_r2s_explanation_engine
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2s_explanation_engine()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  v_ctx uuid; v_casa uuid; v_cuenta uuid;
  v_exp jsonb;
  v_decision uuid;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2S-why', '+5210000091');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2S-why', '+5210000092');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Familia R2S why', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_casa   := (public.create_resource(v_ctx::uuid, 'house', 'Casa Valle R2S-why'))->>'resource_id';
  v_cuenta := (public.create_resource(v_ctx::uuid, 'bank_account', 'Cuenta R2S-why'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, a_david, 'USE');

  -- ═══ 1. why_can_view_resource: David ve Casa Valle por su USE ═══
  v_exp := public.why_can_view_resource(a_david, v_casa::uuid);
  if not (v_exp->>'can_view')::boolean then
    raise exception 'R2S.10 FAIL 1: David debería ver Casa Valle';
  end if;
  if not exists (select 1 from jsonb_array_elements_text(v_exp->'reasons') r where r like '%USE%') then
    raise exception 'R2S.10 FAIL 1: la explicación no menciona el derecho USE';
  end if;

  -- ═══ 2. why_can_reserve: Casa sí (David USE), cuenta no (no reservable) ═══
  v_exp := public.why_can_reserve(a_david, v_casa::uuid);
  if not (v_exp->>'can_reserve')::boolean then
    raise exception 'R2S.10 FAIL 2: David debería poder reservar Casa Valle';
  end if;
  v_exp := public.why_can_reserve(a_david, v_cuenta::uuid);
  if (v_exp->>'can_reserve')::boolean then
    raise exception 'R2S.10 FAIL 2: nadie debería poder reservar una cuenta bancaria';
  end if;
  if not exists (select 1 from jsonb_array_elements_text(v_exp->'reasons') r where r like '%reservable%') then
    raise exception 'R2S.10 FAIL 2: la explicación no menciona la capability reservable';
  end if;

  -- ═══ 3. why_decision_result: conteo y estado ═══
  v_decision := (public.create_decision(v_ctx::uuid, 'generic', '¿Pintamos la casa?'))->>'decision_id';
  perform public.vote_decision(v_decision::uuid, 'approve');
  v_exp := public.why_decision_result(v_decision::uuid);
  if (v_exp->'tally'->>'approve')::numeric <> 1 then
    raise exception 'R2S.10 FAIL 3: el conteo no refleja el voto a favor';
  end if;
  if not exists (select 1 from jsonb_array_elements_text(v_exp->'reasons') r where r like '%Conteo%') then
    raise exception 'R2S.10 FAIL 3: la explicación no incluye el conteo';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david], array[u_jose, u_david]);

  raise notice 'R.2S.10 EXPLANATION ENGINE: PASS (view por USE, reserve por capability, decision por conteo)';
end; $$;

revoke all on function public._smoke_r2s_explanation_engine() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2s_explanation_engine()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_r2s_explanation_engine(); end; $$;
revoke all on function public._smoke_mvp2_r2s_explanation_engine() from public, anon, authenticated;
comment on function public._smoke_mvp2_r2s_explanation_engine() is 'Wrapper CI del smoke R.2S.10 explanation engine.';
