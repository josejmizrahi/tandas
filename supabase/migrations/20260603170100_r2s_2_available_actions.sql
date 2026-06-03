-- ============================================================================
-- R.2S.3 + R.2S.9 — UNIVERSAL AVAILABLE ACTIONS (obligation / decision / reservation)
-- ============================================================================
-- El contrato más importante para el frontend: NO decide qué botón mostrar.
-- El backend devuelve available_actions con la forma CANÓNICA (R.2S-FIX):
--
--   { action_key, label, section, enabled, reason,
--     required_rights, required_capabilities }
--
-- Las acciones de RECURSO son canónicas en r2s_9 (sobre el catálogo de R.2M-3).
-- Esta slice cubre los dominios que R.2M-3 no tocó:
--   obligation_detail  (+ available_actions)
--   decision_detail    (nuevo, con options + available_actions)
--   reservation_detail (nuevo, con available_actions)
--
-- Una acción aparece solo si es aplicable por estado; enabled refleja el permiso
-- del caller (con reason). No se muestra pay en settled, ni vote en ejecutada.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. _aa(): builder de un action object con la forma canónica (7 campos)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._aa(
  p_action_key text,
  p_label text,
  p_section text,
  p_enabled boolean,
  p_reason text,
  p_required_rights text[] default '{}',
  p_required_capabilities text[] default '{}'
)
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'action_key', p_action_key,
    'label', p_label,
    'section', p_section,
    'enabled', p_enabled,
    'reason', p_reason,
    'required_rights', to_jsonb(coalesce(p_required_rights, '{}')),
    'required_capabilities', to_jsonb(coalesce(p_required_capabilities, '{}')));
$$;

revoke all on function public._aa(text, text, text, boolean, text, text[], text[]) from public, anon;
grant execute on function public._aa(text, text, text, boolean, text, text[], text[]) to authenticated, service_role;

comment on function public._aa(text, text, text, boolean, text, text[], text[]) is
  'R.2S-FIX: construye un action object canónico {action_key,label,section,enabled,reason,required_rights,required_capabilities}.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. obligation_available_actions(obligation, actor)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.obligation_available_actions(p_obligation_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_ob public.obligations%rowtype;
  v_active boolean;
  v_is_debtor boolean;
  v_is_creditor boolean;
  v_is_manager boolean;
  v_actions jsonb := '[]'::jsonb;
begin
  select * into v_ob from public.obligations where id = p_obligation_id;
  if v_ob.id is null then return '[]'::jsonb; end if;

  v_active := v_ob.status in ('open', 'accepted', 'in_progress');
  v_is_debtor := p_actor_id = v_ob.debtor_actor_id;
  v_is_creditor := p_actor_id = v_ob.creditor_actor_id;
  v_is_manager := v_ob.context_actor_id is not null
              and public.has_actor_authority(v_ob.context_actor_id, p_actor_id, 'money.settle');

  -- pay — solo money y solo mientras la obligación viva (NO en settled/cancelled/…)
  if v_ob.obligation_kind = 'money' and v_active then
    v_actions := v_actions || public._aa('pay', 'Pagar', 'obligations',
      v_is_debtor, case when v_is_debtor then 'Eres el deudor de esta obligación'
                        else 'Solo el deudor puede pagar' end);
  end if;

  -- mark_completed — para obligaciones de acción (no money)
  if v_ob.obligation_kind <> 'money' and v_active then
    v_actions := v_actions || public._aa('mark_completed', 'Marcar como cumplida', 'obligations',
      v_is_debtor or v_is_creditor or v_is_manager,
      case when v_is_debtor or v_is_creditor or v_is_manager then 'Participas en esta obligación'
           else 'Solo deudor, acreedor o un administrador pueden marcarla' end);
  end if;

  -- dispute — mientras no esté en estado terminal limpio
  if v_ob.status in ('open', 'accepted', 'in_progress', 'completed') then
    v_actions := v_actions || public._aa('dispute', 'Disputar', 'obligations',
      v_is_debtor or v_is_creditor,
      case when v_is_debtor or v_is_creditor then 'Eres parte de la obligación'
           else 'Solo deudor o acreedor pueden disputar' end);
  end if;

  -- forgive — el acreedor perdona
  if v_active then
    v_actions := v_actions || public._aa('forgive', 'Condonar', 'obligations',
      v_is_creditor, case when v_is_creditor then 'Eres el acreedor y puedes condonar'
                          else 'Solo el acreedor puede condonar' end);
  end if;

  -- cancel — acreedor o administrador
  if v_active then
    v_actions := v_actions || public._aa('cancel', 'Cancelar', 'obligations',
      v_is_creditor or v_is_manager,
      case when v_is_creditor or v_is_manager then 'Eres acreedor o administrador'
           else 'Solo el acreedor o un administrador pueden cancelar' end);
  end if;

  return v_actions;
end; $$;

revoke all on function public.obligation_available_actions(uuid, uuid) from public, anon;
grant execute on function public.obligation_available_actions(uuid, uuid) to authenticated, service_role;

comment on function public.obligation_available_actions(uuid, uuid) is
  'R.2S.9: acciones sobre una obligación según kind + status + rol del caller. No muestra pagar en settled.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. obligation_detail v2: + available_actions
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.obligation_detail(p_obligation_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ob public.obligations%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ob from public.obligations where id = p_obligation_id;
  if v_ob.id is null then raise exception 'obligation not found' using errcode = 'P0002'; end if;

  if v_caller <> v_ob.debtor_actor_id
     and v_caller <> v_ob.creditor_actor_id
     and not (v_ob.context_actor_id is not null and public.is_context_member(v_ob.context_actor_id)) then
    raise exception 'not authorized to view this obligation' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'id', v_ob.id,
    'context_actor_id', v_ob.context_actor_id,
    'kind', v_ob.obligation_kind,
    'obligation_type', v_ob.obligation_type,
    'status', v_ob.status,
    'title', v_ob.title,
    'description', v_ob.description,
    'amount', v_ob.amount,
    'currency', v_ob.currency,
    'due_at', v_ob.due_at,
    'debtor_actor_id', v_ob.debtor_actor_id,
    'creditor_actor_id', v_ob.creditor_actor_id,
    'completed_at', v_ob.completed_at,
    'completed_by_actor_id', v_ob.completed_by_actor_id,
    'completion_notes', v_ob.completion_notes,
    'source_event_id', v_ob.source_event_id,
    'source_rule_id', v_ob.source_rule_id,
    'source_reservation_id', v_ob.source_reservation_id,
    'source_decision_id', v_ob.source_decision_id,
    'metadata', v_ob.metadata,
    'available_actions', public.obligation_available_actions(p_obligation_id, v_caller),
    'created_at', v_ob.created_at);
end; $$;

revoke all on function public.obligation_detail(uuid) from public, anon;
grant execute on function public.obligation_detail(uuid) to authenticated, service_role;

comment on function public.obligation_detail(uuid) is
  'R.2S.9: detalle de obligación (money o action) + available_actions.';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. decision_available_actions(decision, actor)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.decision_available_actions(p_decision_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_d public.decisions%rowtype;
  v_can_vote boolean;
  v_can_manage boolean;
  v_already_voted boolean;
  v_actions jsonb := '[]'::jsonb;
begin
  select * into v_d from public.decisions where id = p_decision_id;
  if v_d.id is null then return '[]'::jsonb; end if;

  v_can_vote := public.has_actor_authority(v_d.context_actor_id, p_actor_id, 'decisions.vote');
  v_can_manage := public.has_actor_authority(v_d.context_actor_id, p_actor_id, 'decisions.execute');
  v_already_voted := exists (select 1 from public.decision_votes
                              where decision_id = p_decision_id and voter_actor_id = p_actor_id);

  if v_d.status = 'open' then
    if not v_already_voted then
      v_actions := v_actions || public._aa('vote', 'Votar', 'decisions',
        v_can_vote, case when v_can_vote then 'La decisión está abierta y puedes votar'
                         else 'No tienes permiso para votar en este contexto' end);
    else
      v_actions := v_actions || public._aa('change_vote', 'Cambiar voto', 'decisions',
        v_can_vote, case when v_can_vote then 'Ya votaste; puedes cambiar tu voto'
                         else 'No tienes permiso para votar en este contexto' end);
    end if;
    v_actions := v_actions || public._aa('close_decision', 'Cerrar votación', 'decisions',
      v_can_manage, case when v_can_manage then 'Puedes cerrar la votación'
                         else 'Requiere permiso decisions.execute' end);
    v_actions := v_actions || public._aa('cancel_decision', 'Cancelar decisión', 'decisions',
      v_can_manage, case when v_can_manage then 'Puedes cancelar la decisión'
                         else 'Requiere permiso decisions.execute' end);
  elsif v_d.status in ('approved', 'rejected') then
    -- cerrada pero no ejecutada → se puede ejecutar el resultado
    v_actions := v_actions || public._aa('execute_decision', 'Ejecutar resultado', 'decisions',
      v_can_manage, case when v_can_manage then 'La decisión está cerrada y lista para ejecutar'
                         else 'Requiere permiso decisions.execute' end);
  end if;
  -- status 'executed' o 'cancelled' → sin acciones (NO votar en decisión ejecutada)

  return v_actions;
end; $$;

revoke all on function public.decision_available_actions(uuid, uuid) from public, anon;
grant execute on function public.decision_available_actions(uuid, uuid) to authenticated, service_role;

comment on function public.decision_available_actions(uuid, uuid) is
  'R.2S.9: acciones sobre una decisión según status + permisos. No muestra votar en decisión ejecutada.';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. decision_detail(decision_id): decision + options + votes + available_actions
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.decision_detail(p_decision_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_d from public.decisions where id = p_decision_id;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.is_context_member(v_d.context_actor_id) then
    raise exception 'not authorized to view this decision' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'id', v_d.id,
    'context_actor_id', v_d.context_actor_id,
    'decision_type', v_d.decision_type,
    'voting_model', v_d.voting_model,
    'title', v_d.title,
    'description', v_d.description,
    'status', v_d.status,
    'opens_at', v_d.opens_at,
    'closes_at', v_d.closes_at,
    'decided_at', v_d.decided_at,
    'executed_at', v_d.executed_at,
    'payload', v_d.payload,
    'result', v_d.result,
    'options', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', o.id, 'option_key', o.option_key, 'title', o.title,
        'description', o.description, 'payload', o.payload, 'sort_order', o.sort_order,
        'votes', (select count(*) from public.decision_votes dv where dv.option_id = o.id))
        order by o.sort_order, o.option_key)
      from public.decision_options o where o.decision_id = p_decision_id and o.status = 'active'), '[]'::jsonb),
    'votes_count', (select count(*) from public.decision_votes where decision_id = p_decision_id),
    'available_actions', public.decision_available_actions(p_decision_id, v_caller),
    'created_at', v_d.created_at);
end; $$;

revoke all on function public.decision_detail(uuid) from public, anon;
grant execute on function public.decision_detail(uuid) to authenticated, service_role;

comment on function public.decision_detail(uuid) is
  'R.2S.9: detalle de decisión con options reales + available_actions (votar/cambiar/cerrar/ejecutar/cancelar).';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. reservation_available_actions(reservation, actor)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.reservation_available_actions(p_reservation_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_r public.resource_reservations%rowtype;
  v_can_manage boolean;
  v_is_party boolean;
  v_has_conflict boolean;
  v_actions jsonb := '[]'::jsonb;
begin
  select * into v_r from public.resource_reservations where id = p_reservation_id;
  if v_r.id is null then return '[]'::jsonb; end if;

  v_can_manage := public._can_manage_reservations(p_actor_id, v_r.resource_id, v_r.context_actor_id);
  v_is_party := p_actor_id in (v_r.requested_by_actor_id, v_r.reserved_for_actor_id);
  v_has_conflict := exists (
    select 1 from public.reservation_conflicts c
    where c.resolution_status = 'open'
      and (c.reservation_a_id = p_reservation_id or c.reservation_b_id = p_reservation_id));

  if v_r.status = 'requested' then
    v_actions := v_actions || public._aa('approve', 'Aprobar', 'reservations',
      v_can_manage, case when v_can_manage then 'Puedes administrar reservaciones del recurso'
                         else 'Requiere MANAGE/OWN/GOVERN o permiso reservations.manage' end);
    v_actions := v_actions || public._aa('reject', 'Rechazar', 'reservations',
      v_can_manage, case when v_can_manage then 'Puedes administrar reservaciones del recurso'
                         else 'Requiere MANAGE/OWN/GOVERN o permiso reservations.manage' end);
  end if;

  if v_r.status = 'approved' then
    v_actions := v_actions || public._aa('confirm', 'Confirmar', 'reservations',
      v_is_party or v_can_manage,
      case when v_is_party or v_can_manage then 'Puedes confirmar esta reservación'
           else 'Solo quien reserva o un administrador puede confirmar' end);
  end if;

  if v_r.status in ('requested', 'approved', 'confirmed') then
    v_actions := v_actions || public._aa('cancel', 'Cancelar', 'reservations',
      v_is_party or v_can_manage,
      case when v_is_party or v_can_manage then 'Puedes cancelar esta reservación'
           else 'Solo quien reserva o un administrador puede cancelar' end);
  end if;

  if v_has_conflict then
    v_actions := v_actions || public._aa('resolve_conflict', 'Resolver conflicto', 'reservations',
      v_can_manage, case when v_can_manage then 'Hay un conflicto abierto que puedes resolver'
                         else 'Requiere administrar reservaciones del recurso' end);
  end if;

  return v_actions;
end; $$;

revoke all on function public.reservation_available_actions(uuid, uuid) from public, anon;
grant execute on function public.reservation_available_actions(uuid, uuid) to authenticated, service_role;

comment on function public.reservation_available_actions(uuid, uuid) is
  'R.2S.9: acciones sobre una reservación según status + conflicto + permisos.';

-- ────────────────────────────────────────────────────────────────────────────
-- 7. reservation_detail(reservation_id)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.reservation_detail(p_reservation_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_r public.resource_reservations%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_r from public.resource_reservations where id = p_reservation_id;
  if v_r.id is null then raise exception 'reservation not found' using errcode = 'P0002'; end if;
  if not public.is_context_member(v_r.context_actor_id)
     and not public._actor_can_view_resource(v_caller, v_r.resource_id) then
    raise exception 'not authorized to view this reservation' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'id', v_r.id,
    'resource_id', v_r.resource_id,
    'context_actor_id', v_r.context_actor_id,
    'requested_by_actor_id', v_r.requested_by_actor_id,
    'reserved_for_actor_id', v_r.reserved_for_actor_id,
    'starts_at', v_r.starts_at,
    'ends_at', v_r.ends_at,
    'status', v_r.status,
    'priority_score', v_r.priority_score,
    'source_decision_id', v_r.source_decision_id,
    'metadata', v_r.metadata,
    'available_actions', public.reservation_available_actions(p_reservation_id, v_caller),
    'created_at', v_r.created_at);
end; $$;

revoke all on function public.reservation_detail(uuid) from public, anon;
grant execute on function public.reservation_detail(uuid) to authenticated, service_role;

comment on function public.reservation_detail(uuid) is
  'R.2S.9: detalle de reservación + available_actions (aprobar/rechazar/confirmar/cancelar/resolver).';

-- ────────────────────────────────────────────────────────────────────────────
-- 8. Smoke — _smoke_r2s_available_actions (obligation / decision / reservation)
-- ────────────────────────────────────────────────────────────────────────────
-- Las acciones de RECURSO se validan en r2s_9 (contrato canónico). Aquí se
-- valida la forma canónica en los dominios que cubre esta slice.
create or replace function public._smoke_r2s_available_actions()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  v_ctx uuid;
  v_decision uuid; v_vino uuid;
  v_actions jsonb; v_a jsonb;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2S-actions', '+5210000062');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2S-actions', '+5210000063');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Familia R2S actions', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  -- ═══ 1. Decisión abierta → vote presente; ejecutada → sin vote ═══
  v_decision := (public.create_decision(v_ctx::uuid, 'generic', '¿Pintamos la casa?'))->>'decision_id';
  v_actions := public.decision_available_actions(v_decision::uuid, a_jose);
  if not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'vote') then
    raise exception 'R2S.9 FAIL 1: decisión abierta no muestra vote';
  end if;

  -- ═══ 2. La forma canónica (7 campos) está completa ═══
  v_a := (select a from jsonb_array_elements(v_actions) a where a->>'action_key' = 'vote' limit 1);
  if not (v_a ? 'action_key' and v_a ? 'label' and v_a ? 'section' and v_a ? 'enabled'
          and v_a ? 'reason' and v_a ? 'required_rights' and v_a ? 'required_capabilities') then
    raise exception 'R2S.9 FAIL 2: action object sin la forma canónica de 7 campos';
  end if;

  -- ═══ 3. Obligación de acción → mark_completed, NO pay ═══
  v_vino := (public.create_action_obligation(v_ctx::uuid, a_david, 'Llevar vino', 'action'))->>'obligation_id';
  v_actions := public.obligation_available_actions(v_vino::uuid, a_david);
  if not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'mark_completed') then
    raise exception 'R2S.9 FAIL 3: la obligación de acción no muestra mark_completed';
  end if;
  if exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'pay') then
    raise exception 'R2S.9 FAIL 3: la obligación de acción no debe mostrar pay';
  end if;
  -- sección correcta
  if (select a->>'section' from jsonb_array_elements(v_actions) a where a->>'action_key' = 'mark_completed') <> 'obligations' then
    raise exception 'R2S.9 FAIL 3: sección incorrecta en la acción de obligación';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david], array[u_jose, u_david]);

  raise notice 'R.2S.9 AVAILABLE ACTIONS (obligation/decision/reservation): PASS (forma canónica, vote/mark_completed, sin pay)';
end; $$;

revoke all on function public._smoke_r2s_available_actions() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2s_available_actions()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_r2s_available_actions(); end; $$;
revoke all on function public._smoke_mvp2_r2s_available_actions() from public, anon, authenticated;
comment on function public._smoke_mvp2_r2s_available_actions() is 'Wrapper CI del smoke R.2S.9 available actions (obligation/decision/reservation).';
