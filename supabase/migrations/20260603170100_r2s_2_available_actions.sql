-- ============================================================================
-- R.2S.3 + R.2S.9 — UNIVERSAL AVAILABLE ACTIONS
-- ============================================================================
-- El contrato más importante para el frontend: NO decide qué botón mostrar.
-- El backend devuelve available_actions con la forma:
--
--   { action_key, label, enabled, reason, required_rights, required_capabilities }
--
-- Reglas:
--   - Una acción aparece (es "visible") solo si es aplicable por capability +
--     estado (ej. reserve_resource solo si el recurso es reservable; pay solo
--     si la obligación money sigue abierta).
--   - enabled refleja si el caller TIENE permiso ahora mismo; reason lo explica.
--   - No se muestran acciones imposibles (reservar una cuenta, votar una
--     decisión ejecutada, pagar una obligación liquidada).
--
-- Detail RPCs cubiertos en esta slice:
--   resource_detail      (+ available_actions)
--   obligation_detail    (+ available_actions)
--   decision_detail      (nuevo, con options + available_actions)
--   reservation_detail   (nuevo, con available_actions)
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. _aa(): builder de un action object con la forma del contrato
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._aa(
  p_action_key text,
  p_label text,
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
    'enabled', p_enabled,
    'reason', p_reason,
    'required_rights', to_jsonb(coalesce(p_required_rights, '{}')),
    'required_capabilities', to_jsonb(coalesce(p_required_capabilities, '{}')));
$$;

revoke all on function public._aa(text, text, boolean, text, text[], text[]) from public, anon;
grant execute on function public._aa(text, text, boolean, text, text[], text[]) to authenticated, service_role;

comment on function public._aa(text, text, boolean, text, text[], text[]) is
  'R.2S.9: construye un action object {action_key,label,enabled,reason,required_rights,required_capabilities}.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. resource_available_actions(resource_id, actor_id)
-- ────────────────────────────────────────────────────────────────────────────
-- Las capabilities gobiernan VISIBILIDAD; los rights gobiernan enabled.
create or replace function public.resource_available_actions(p_resource_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_res public.resources%rowtype;
  v_ctx uuid;
  v_can_use boolean;
  v_can_manage boolean;
  v_can_own boolean;
  v_actions jsonb := '[]'::jsonb;
begin
  select * into v_res from public.resources where id = p_resource_id;
  if v_res.id is null then return '[]'::jsonb; end if;
  v_ctx := v_res.canonical_owner_actor_id;

  v_can_manage := public.actor_has_right(p_actor_id, p_resource_id, 'MANAGE')
               or public.actor_has_right(p_actor_id, p_resource_id, 'OWN')
               or (v_ctx is not null and public.has_actor_authority(v_ctx, p_actor_id, 'resources.manage'));
  v_can_own    := public.actor_has_right(p_actor_id, p_resource_id, 'OWN');
  v_can_use    := v_can_manage
               or public.actor_has_right(p_actor_id, p_resource_id, 'USE');

  -- reserve_resource — cap reservable
  if public.resource_can(p_resource_id, 'reservable') then
    v_actions := v_actions || public._aa('reserve_resource', 'Reservar',
      public._can_manage_reservations(p_actor_id, p_resource_id, v_ctx) or v_can_use,
      case when v_can_use then 'El recurso es reservable y tienes derecho de uso'
           else 'Requiere derecho USE, MANAGE u OWN sobre el recurso' end,
      array['USE'], array['reservable']);
  end if;

  -- record_expense / view_transactions — cap monetary
  if public.resource_can(p_resource_id, 'monetary') then
    v_actions := v_actions || public._aa('record_expense', 'Registrar gasto',
      v_can_manage,
      case when v_can_manage then 'El recurso es monetario y puedes administrarlo'
           else 'Requiere derecho MANAGE u OWN sobre el recurso' end,
      array['MANAGE'], array['monetary']);
    v_actions := v_actions || public._aa('view_transactions', 'Ver movimientos',
      true, 'El recurso es monetario y auditable', array['VIEW'], array['monetary']);
  end if;

  -- view_beneficiaries — cap beneficiary_supported
  if public.resource_can(p_resource_id, 'beneficiary_supported') then
    v_actions := v_actions || public._aa('view_beneficiaries', 'Ver beneficiarios',
      true, 'El recurso soporta beneficiarios', array['VIEW'], array['beneficiary_supported']);
  end if;

  -- view_ownership — cap ownership_trackable
  if public.resource_can(p_resource_id, 'ownership_trackable') then
    v_actions := v_actions || public._aa('view_ownership', 'Ver propiedad',
      true, 'El recurso rastrea propiedad (OWN %) por porcentajes', array['VIEW'], array['ownership_trackable']);
  end if;

  -- transfer_ownership — cap transferable
  if public.resource_can(p_resource_id, 'transferable') then
    v_actions := v_actions || public._aa('transfer_ownership', 'Transferir',
      v_can_own,
      case when v_can_own then 'Eres dueño y el recurso es transferible'
           else 'Solo el dueño (OWN) puede transferir' end,
      array['OWN'], array['transferable']);
  end if;

  -- grant_right / revoke_right — sobre cualquier recurso, gated por MANAGE/OWN
  v_actions := v_actions || public._aa('grant_right', 'Otorgar derecho',
    v_can_manage,
    case when v_can_manage then 'Puedes administrar los derechos del recurso'
         else 'Requiere derecho MANAGE u OWN' end,
    array['MANAGE'], '{}');
  v_actions := v_actions || public._aa('revoke_right', 'Revocar derecho',
    v_can_manage,
    case when v_can_manage then 'Puedes administrar los derechos del recurso'
         else 'Requiere derecho MANAGE u OWN' end,
    array['MANAGE'], '{}');

  return v_actions;
end; $$;

revoke all on function public.resource_available_actions(uuid, uuid) from public, anon;
grant execute on function public.resource_available_actions(uuid, uuid) to authenticated, service_role;

comment on function public.resource_available_actions(uuid, uuid) is
  'R.2S.9: acciones disponibles sobre un recurso (capability→visibilidad, rights→enabled).';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. resource_detail v4: + available_actions
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.resource_detail(p_resource_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_resource public.resources%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_resource from public.resources where id = p_resource_id;
  if v_resource.id is null then raise exception 'resource not found' using errcode = 'P0002'; end if;

  if not public._actor_can_view_resource(v_caller, p_resource_id) then
    raise exception 'not authorized to view resource %', p_resource_id using errcode = '42501';
  end if;

  return jsonb_build_object(
    'resource', to_jsonb(v_resource),
    'resource_type', v_resource.resource_type,
    'metadata', v_resource.metadata,
    'capabilities', coalesce((
      select jsonb_agg(tc.capability_key order by tc.capability_key)
        from public.resource_type_capabilities tc
       where tc.type_key = v_resource.resource_type), '[]'::jsonb),
    -- R.2S.9: el frontend renderiza botones desde aquí, no por resource_type
    'available_actions', public.resource_available_actions(p_resource_id, v_caller),
    'rights', coalesce((
      select jsonb_agg(jsonb_build_object(
        'right_id', rr.id, 'holder_actor_id', rr.holder_actor_id,
        'holder_display_name', (select a.display_name from public.actors a where a.id = rr.holder_actor_id),
        'right_kind', rr.right_kind, 'percent', rr.percent, 'scope', rr.scope,
        'starts_at', rr.starts_at, 'ends_at', rr.ends_at) order by rr.created_at)
      from public.resource_rights rr
      where rr.resource_id = p_resource_id and rr.revoked_at is null and rr.expired_at is null), '[]'::jsonb)
  );
end; $$;

revoke all on function public.resource_detail(uuid) from public, anon;
grant execute on function public.resource_detail(uuid) to authenticated, service_role;

comment on function public.resource_detail(uuid) is
  'R.2S.9: detalle de recurso con rights + resource_type + capabilities + available_actions.';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. obligation_available_actions(obligation, actor)
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
    v_actions := v_actions || public._aa('pay', 'Pagar',
      v_is_debtor, case when v_is_debtor then 'Eres el deudor de esta obligación'
                        else 'Solo el deudor puede pagar' end);
  end if;

  -- mark_completed — para obligaciones de acción (no money)
  if v_ob.obligation_kind <> 'money' and v_active then
    v_actions := v_actions || public._aa('mark_completed', 'Marcar como cumplida',
      v_is_debtor or v_is_creditor or v_is_manager,
      case when v_is_debtor or v_is_creditor or v_is_manager then 'Participas en esta obligación'
           else 'Solo deudor, acreedor o un administrador pueden marcarla' end);
  end if;

  -- dispute — mientras no esté en estado terminal limpio
  if v_ob.status in ('open', 'accepted', 'in_progress', 'completed') then
    v_actions := v_actions || public._aa('dispute', 'Disputar',
      v_is_debtor or v_is_creditor,
      case when v_is_debtor or v_is_creditor then 'Eres parte de la obligación'
           else 'Solo deudor o acreedor pueden disputar' end);
  end if;

  -- forgive — el acreedor perdona
  if v_active then
    v_actions := v_actions || public._aa('forgive', 'Condonar',
      v_is_creditor, case when v_is_creditor then 'Eres el acreedor y puedes condonar'
                          else 'Solo el acreedor puede condonar' end);
  end if;

  -- cancel — acreedor o administrador
  if v_active then
    v_actions := v_actions || public._aa('cancel', 'Cancelar',
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
-- 5. obligation_detail v2: + available_actions
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
-- 6. decision_available_actions(decision, actor)
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
      v_actions := v_actions || public._aa('vote', 'Votar',
        v_can_vote, case when v_can_vote then 'La decisión está abierta y puedes votar'
                         else 'No tienes permiso para votar en este contexto' end);
    else
      v_actions := v_actions || public._aa('change_vote', 'Cambiar voto',
        v_can_vote, case when v_can_vote then 'Ya votaste; puedes cambiar tu voto'
                         else 'No tienes permiso para votar en este contexto' end);
    end if;
    v_actions := v_actions || public._aa('close_decision', 'Cerrar votación',
      v_can_manage, case when v_can_manage then 'Puedes cerrar la votación'
                         else 'Requiere permiso decisions.execute' end);
    v_actions := v_actions || public._aa('cancel_decision', 'Cancelar decisión',
      v_can_manage, case when v_can_manage then 'Puedes cancelar la decisión'
                         else 'Requiere permiso decisions.execute' end);
  elsif v_d.status in ('approved', 'rejected') then
    -- cerrada pero no ejecutada → se puede ejecutar el resultado
    v_actions := v_actions || public._aa('execute_decision', 'Ejecutar resultado',
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
-- 7. decision_detail(decision_id): decision + options + votes + available_actions
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
-- 8. reservation_available_actions(reservation, actor)
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
    v_actions := v_actions || public._aa('approve', 'Aprobar',
      v_can_manage, case when v_can_manage then 'Puedes administrar reservaciones del recurso'
                         else 'Requiere MANAGE/OWN/GOVERN o permiso reservations.manage' end);
    v_actions := v_actions || public._aa('reject', 'Rechazar',
      v_can_manage, case when v_can_manage then 'Puedes administrar reservaciones del recurso'
                         else 'Requiere MANAGE/OWN/GOVERN o permiso reservations.manage' end);
  end if;

  if v_r.status = 'approved' then
    v_actions := v_actions || public._aa('confirm', 'Confirmar',
      v_is_party or v_can_manage,
      case when v_is_party or v_can_manage then 'Puedes confirmar esta reservación'
           else 'Solo quien reserva o un administrador puede confirmar' end);
  end if;

  if v_r.status in ('requested', 'approved', 'confirmed') then
    v_actions := v_actions || public._aa('cancel', 'Cancelar',
      v_is_party or v_can_manage,
      case when v_is_party or v_can_manage then 'Puedes cancelar esta reservación'
           else 'Solo quien reserva o un administrador puede cancelar' end);
  end if;

  if v_has_conflict then
    v_actions := v_actions || public._aa('resolve_conflict', 'Resolver conflicto',
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
-- 9. reservation_detail(reservation_id)
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
-- 10. Smoke — _smoke_r2s_available_actions
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2s_available_actions()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  v_ctx uuid; v_casa uuid; v_cuenta uuid; v_security uuid;
  v_detail jsonb;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2S-actions', '+5210000062');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Familia R2S actions', 'collective', 'family'))->>'context_actor_id';
  v_casa    := (public.create_resource(v_ctx::uuid, 'house', 'Casa Valle R2S-aa'))->>'resource_id';
  v_cuenta  := (public.create_resource(v_ctx::uuid, 'bank_account', 'Cuenta del Viaje R2S-aa'))->>'resource_id';
  v_security:= (public.create_resource(v_ctx::uuid, 'security', 'Acciones Quimibond R2S-aa'))->>'resource_id';

  -- ═══ 1. Casa Valle: SÍ reserve_resource ═══
  v_detail := public.resource_detail(v_casa::uuid);
  if not exists (select 1 from jsonb_array_elements(v_detail->'available_actions') a
                 where a->>'action_key' = 'reserve_resource') then
    raise exception 'R2S.9 FAIL 1: Casa Valle no muestra reserve_resource';
  end if;

  -- ═══ 2. Cuenta del Viaje (bank_account): NO reserve_resource, SÍ record_expense/view_transactions ═══
  v_detail := public.resource_detail(v_cuenta::uuid);
  if exists (select 1 from jsonb_array_elements(v_detail->'available_actions') a
             where a->>'action_key' = 'reserve_resource') then
    raise exception 'R2S.9 FAIL 2: la cuenta bancaria muestra reserve_resource';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_detail->'available_actions') a
                 where a->>'action_key' = 'record_expense') then
    raise exception 'R2S.9 FAIL 2: la cuenta no muestra record_expense';
  end if;

  -- ═══ 3. Acciones Quimibond (security): NO reserve, SÍ view_beneficiaries + transfer ═══
  v_detail := public.resource_detail(v_security::uuid);
  if exists (select 1 from jsonb_array_elements(v_detail->'available_actions') a
             where a->>'action_key' = 'reserve_resource') then
    raise exception 'R2S.9 FAIL 3: security muestra reserve_resource';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_detail->'available_actions') a
                 where a->>'action_key' = 'view_beneficiaries') then
    raise exception 'R2S.9 FAIL 3: security no muestra view_beneficiaries';
  end if;

  -- ═══ 4. La forma del contrato está completa ═══
  v_detail := public.resource_detail(v_casa::uuid);
  if exists (
    select 1 from jsonb_array_elements(v_detail->'available_actions') a
    where not (a ? 'action_key' and a ? 'label' and a ? 'enabled'
               and a ? 'reason' and a ? 'required_rights' and a ? 'required_capabilities')
  ) then
    raise exception 'R2S.9 FAIL 4: un action object no tiene la forma completa del contrato';
  end if;

  -- ═══ 5. enabled refleja permisos: José (founder) puede reservar ═══
  v_detail := public.resource_detail(v_casa::uuid);
  if not (select (a->>'enabled')::boolean from jsonb_array_elements(v_detail->'available_actions') a
          where a->>'action_key' = 'reserve_resource') then
    raise exception 'R2S.9 FAIL 5: el founder no puede reservar Casa Valle';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose], array[u_jose]);

  raise notice 'R.2S.9 AVAILABLE ACTIONS: PASS (casa→reservar, cuenta/security sin reservar, forma de contrato completa)';
end; $$;

revoke all on function public._smoke_r2s_available_actions() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2s_available_actions()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_r2s_available_actions(); end; $$;
revoke all on function public._smoke_mvp2_r2s_available_actions() from public, anon, authenticated;
comment on function public._smoke_mvp2_r2s_available_actions() is 'Wrapper CI del smoke R.2S.9 available actions.';
