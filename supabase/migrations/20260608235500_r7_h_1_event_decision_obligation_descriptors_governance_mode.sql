-- R.7.H.1 — Wire _aa_apply_governance_mode en 3 descriptors (event/decision/obligation)
-- Doctrina: Plans/Active/R7_GovernanceOrchestrationEngine.md (R.7 followup)
-- Futureproof: ningún action_key actual matchea catalog → no-op observable hoy.
-- Skip intencional: list_resource_actions ya tiene su propio campo `mode`
-- (rac.execution_mode del resource_action_catalog R.5A.B.8). Founder firmó
-- "sin colisión R.2M3" en R.7.D camino B.

-- §1 event_available_actions(event_id, actor_id)
create or replace function public.event_available_actions(p_event_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to public, auth
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

  if v_is_active and (v_participant.id is null or v_participant.status in ('invited', 'going', 'maybe', 'declined')) then
    v_actions := v_actions || public._aa('rsvp_event', 'Responder asistencia', 'participation',
      true,
      case when v_participant.id is null then 'Puedes responder asistencia'
           else 'Puedes cambiar tu respuesta' end);
  end if;

  if v_is_active and v_participant.id is not null
     and v_participant.checked_in_at is null
     and v_participant.status not in ('cancelled', 'declined') then
    v_actions := v_actions || public._aa('check_in_participant', 'Marcar mi llegada', 'participation',
      true, 'Puedes registrar tu propia llegada al evento');
  end if;

  if v_is_active and v_participant.id is not null
     and v_participant.status in ('invited', 'going', 'maybe') then
    v_actions := v_actions || public._aa('cancel_participation', 'Cancelar mi asistencia', 'participation',
      true, 'Puedes cancelar tu participación');
  end if;

  if v_is_active then
    v_actions := v_actions || public._aa('close_event', 'Cerrar evento', 'participation',
      v_is_host or v_can_manage_events,
      case when v_is_host then 'Eres el anfitrión del evento'
           when v_can_manage_events then 'Tienes permiso para administrar eventos'
           else 'Solo el anfitrión o un administrador pueden cerrar el evento' end);
  end if;

  if v_is_active then
    v_actions := v_actions || public._aa('edit_event', 'Editar evento', 'participation',
      v_is_host or v_can_manage_events,
      case when v_is_host then 'Eres el anfitrión del evento'
           when v_can_manage_events then 'Tienes permiso para administrar eventos'
           else 'Solo el anfitrión o un administrador pueden editar el evento' end);
  end if;

  if v_e.status <> 'cancelled' then
    v_actions := v_actions || public._aa('record_expense', 'Registrar gasto', 'money',
      v_can_record_money,
      case when v_can_record_money then 'Puedes registrar un gasto asociado al evento'
           else 'Requiere permiso money.record' end);
  end if;

  if not v_is_terminal then
    v_actions := v_actions || public._aa('create_decision', 'Abrir decisión', 'decisions',
      v_can_create_decision,
      case when v_can_create_decision then 'Puedes abrir una decisión vinculada al evento'
           else 'Requiere permiso decisions.create' end);
  end if;

  v_actions := v_actions || public._aa('attach_document', 'Adjuntar documento', 'documents',
    true, 'Puedes adjuntar un documento al evento');

  return public._aa_apply_governance_mode(v_actions, v_e.context_actor_id);
end; $$;

-- §2 decision_available_actions(decision_id, actor_id)
create or replace function public.decision_available_actions(p_decision_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to public
as $$
declare
  v_d public.decisions%rowtype;
  v_can_vote boolean;
  v_can_manage boolean;
  v_is_author boolean;
  v_already_voted boolean;
  v_actions jsonb := '[]'::jsonb;
begin
  select * into v_d from public.decisions where id = p_decision_id;
  if v_d.id is null then return '[]'::jsonb; end if;

  v_can_vote := public.has_actor_authority(v_d.context_actor_id, p_actor_id, 'decisions.vote');
  v_can_manage := public.has_actor_authority(v_d.context_actor_id, p_actor_id, 'decisions.execute');
  v_is_author := v_d.created_by_actor_id = p_actor_id;
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
    v_actions := v_actions || public._aa('edit_decision', 'Editar decisión', 'decisions',
      v_is_author or v_can_manage,
      case when v_is_author then 'Eres el autor de la decisión'
           when v_can_manage then 'Tienes permiso para administrar decisiones'
           else 'Solo el autor o un administrador pueden editar la decisión' end);
  elsif v_d.status in ('approved', 'rejected') then
    v_actions := v_actions || public._aa('execute_decision', 'Ejecutar resultado', 'decisions',
      v_can_manage, case when v_can_manage then 'La decisión está cerrada y lista para ejecutar'
                         else 'Requiere permiso decisions.execute' end);
  end if;

  return public._aa_apply_governance_mode(v_actions, v_d.context_actor_id);
end; $$;

-- §3 obligation_available_actions(obligation_id, actor_id)
create or replace function public.obligation_available_actions(p_obligation_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to public
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

  if v_ob.obligation_kind = 'money' and v_active then
    v_actions := v_actions || public._aa('pay', 'Pagar', 'obligations',
      v_is_debtor, case when v_is_debtor then 'Eres el deudor de esta obligación'
                        else 'Solo el deudor puede pagar' end);
  end if;

  if v_ob.obligation_kind <> 'money' and v_active then
    v_actions := v_actions || public._aa('mark_completed', 'Marcar como cumplida', 'obligations',
      v_is_debtor or v_is_creditor or v_is_manager,
      case when v_is_debtor or v_is_creditor or v_is_manager then 'Participas en esta obligación'
           else 'Solo deudor, acreedor o un administrador pueden marcarla' end);
  end if;

  if v_ob.status in ('open', 'accepted', 'in_progress', 'completed') then
    v_actions := v_actions || public._aa('dispute', 'Disputar', 'obligations',
      v_is_debtor or v_is_creditor,
      case when v_is_debtor or v_is_creditor then 'Eres parte de la obligación'
           else 'Solo deudor o acreedor pueden disputar' end);
  end if;

  if v_active then
    v_actions := v_actions || public._aa('forgive', 'Condonar', 'obligations',
      v_is_creditor, case when v_is_creditor then 'Eres el acreedor y puedes condonar'
                          else 'Solo el acreedor puede condonar' end);
  end if;

  if v_active then
    v_actions := v_actions || public._aa('cancel', 'Cancelar', 'obligations',
      v_is_creditor or v_is_manager,
      case when v_is_creditor or v_is_manager then 'Eres acreedor o administrador'
           else 'Solo el acreedor o un administrador pueden cancelar' end);
  end if;

  if v_active then
    v_actions := v_actions || public._aa('edit_obligation', 'Editar obligación', 'obligations',
      v_is_creditor or v_is_manager,
      case when v_is_creditor then 'Eres el acreedor y puedes editar'
           when v_is_manager then 'Tienes permiso para administrar dinero'
           else 'Solo el acreedor o un administrador pueden editar la obligación' end);
  end if;

  if v_ob.context_actor_id is not null then
    return public._aa_apply_governance_mode(v_actions, v_ob.context_actor_id);
  end if;
  return v_actions;
end; $$;
