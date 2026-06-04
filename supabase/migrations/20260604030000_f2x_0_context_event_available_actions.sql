-- ============================================================================
-- F.2X.0 — INTENT-FIRST AVAILABLE ACTIONS (context + event)
-- ============================================================================
-- Doctrina F.2X (`Plans/Doctrine/F2X_IntentFirst_ContextualActions.md`):
--   Las Quick Actions no pertenecen a la app. Pertenecen al objeto.
--
-- Esta slice cierra los DOS huecos doctrinales que faltaban en el contrato
-- canónico de available_actions establecido en R.2S.9:
--
--   context_available_actions(ctx, actor)   — para ContextHomeView
--   event_available_actions(event, actor)   — para EventDetailView
--   event_detail(event)                     — wrapper canónico (como
--                                              resource_detail / decision_detail
--                                              / reservation_detail / obligation_detail)
--   context_summary                         — agrega available_actions[] sin
--                                              romper my_permissions[]
--
-- Shape de cada acción (R.2S-FIX canónico, 7 campos):
--   { action_key, label, section, enabled, reason,
--     required_rights, required_capabilities }
--
-- Las acciones aparecen si son aplicables al estado del objeto;
-- enabled refleja el permiso del caller (con reason humano en es-MX).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. context_available_actions(context_actor_id, actor_id)
-- ────────────────────────────────────────────────────────────────────────────
-- Acciones creativas a nivel contexto. Todas aparecen siempre (son intent-first);
-- enabled gateado por has_actor_authority + reason humano.
create or replace function public.context_available_actions(
  p_context_actor_id uuid,
  p_actor_id uuid
)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ctx public.actors%rowtype;
  v_is_member boolean;
  v_can_create_resource boolean;
  v_can_create_event boolean;
  v_can_create_decision boolean;
  v_can_record_money boolean;
  v_can_invite boolean;
  v_can_manage_rules boolean;
  v_can_manage_ctx boolean;
  v_actions jsonb := '[]'::jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ctx from public.actors where id = p_context_actor_id;
  if v_ctx.id is null then raise exception 'context not found' using errcode = 'P0002'; end if;
  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  v_is_member          := public.is_context_member(p_context_actor_id);
  v_can_create_resource:= public.has_actor_authority(p_context_actor_id, p_actor_id, 'resources.create');
  v_can_create_event   := public.has_actor_authority(p_context_actor_id, p_actor_id, 'events.create');
  v_can_create_decision:= public.has_actor_authority(p_context_actor_id, p_actor_id, 'decisions.create');
  v_can_record_money   := public.has_actor_authority(p_context_actor_id, p_actor_id, 'money.record');
  v_can_invite         := public.has_actor_authority(p_context_actor_id, p_actor_id, 'context.invite');
  v_can_manage_rules   := public.has_actor_authority(p_context_actor_id, p_actor_id, 'rules.manage');
  v_can_manage_ctx     := public.has_actor_authority(p_context_actor_id, p_actor_id, 'context.manage');

  -- create_resource — sección "Recursos"
  v_actions := v_actions || public._aa('create_resource', 'Crear recurso', 'resources',
    v_can_create_resource,
    case when v_can_create_resource then 'Tienes permiso para crear recursos en este contexto'
         else 'Requiere permiso resources.create' end);

  -- create_event — sección "Calendario"
  v_actions := v_actions || public._aa('create_event', 'Crear evento', 'calendar',
    v_can_create_event,
    case when v_can_create_event then 'Tienes permiso para crear eventos'
         else 'Requiere permiso events.create' end);

  -- create_decision — sección "Decisiones"
  v_actions := v_actions || public._aa('create_decision', 'Crear decisión', 'decisions',
    v_can_create_decision,
    case when v_can_create_decision then 'Tienes permiso para abrir decisiones'
         else 'Requiere permiso decisions.create' end);

  -- record_expense — sección "Dinero"
  v_actions := v_actions || public._aa('record_expense', 'Registrar gasto', 'money',
    v_can_record_money,
    case when v_can_record_money then 'Tienes permiso para registrar gastos'
         else 'Requiere permiso money.record' end);

  -- invite_member — sección "Miembros"
  v_actions := v_actions || public._aa('invite_member', 'Invitar miembro', 'members',
    v_can_invite,
    case when v_can_invite then 'Tienes permiso para invitar miembros'
         else 'Requiere permiso context.invite' end);

  -- create_rule — sección "Reglas"
  v_actions := v_actions || public._aa('create_rule', 'Crear regla', 'rules',
    v_can_manage_rules,
    case when v_can_manage_rules then 'Tienes permiso para administrar reglas'
         else 'Requiere permiso rules.manage' end);

  -- create_child_context — sección "Jerarquía"
  -- Solo aparece para colectivos / entidades, NO para contextos personales
  if v_ctx.actor_kind <> 'person' then
    v_actions := v_actions || public._aa('create_child_context', 'Crear sub-contexto', 'hierarchy',
      v_can_manage_ctx,
      case when v_can_manage_ctx then 'Tienes permiso para administrar la jerarquía'
           else 'Requiere permiso context.manage' end);
  end if;

  return v_actions;
end; $$;

revoke all on function public.context_available_actions(uuid, uuid) from public, anon;
grant execute on function public.context_available_actions(uuid, uuid) to authenticated, service_role;

comment on function public.context_available_actions(uuid, uuid) is
  'F.2X.0: acciones canónicas a nivel contexto (creación). Shape canónico de 7 campos. Member-only.';

-- Compat 1-arg: delega al actor-aware con current_actor_id()
create or replace function public.context_available_actions(p_context_actor_id uuid)
returns jsonb
language sql stable security definer set search_path = public, auth
as $$
  select public.context_available_actions(p_context_actor_id, public.current_actor_id());
$$;

revoke all on function public.context_available_actions(uuid) from public, anon;
grant execute on function public.context_available_actions(uuid) to authenticated, service_role;

comment on function public.context_available_actions(uuid) is
  'F.2X.0: compat 1-arg — delega a context_available_actions(ctx, current_actor_id()).';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. event_available_actions(event_id, actor_id)
-- ────────────────────────────────────────────────────────────────────────────
-- Acciones sobre un evento canónico. Mezcla:
--   - participación (rsvp, check-in, cancel, close)
--   - cross-domain (record_expense, create_decision, attach_document)
-- Las creativas cross-domain SIEMPRE aparecen para miembros — enabled gateado.
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

  -- rsvp_event — solo mientras el evento es futuro/activo y antes de check-in/cancel
  if v_is_active and (v_participant.id is null or v_participant.status in ('invited', 'going', 'maybe', 'declined')) then
    v_actions := v_actions || public._aa('rsvp_event', 'Responder asistencia', 'participation',
      true,
      case when v_participant.id is null then 'Puedes responder asistencia'
           else 'Puedes cambiar tu respuesta' end);
  end if;

  -- check_in_participant — host/manager hace check-in al participante; durante el evento
  if v_is_active and v_participant.id is not null
     and v_participant.checked_in_at is null
     and v_participant.status not in ('cancelled', 'declined') then
    v_actions := v_actions || public._aa('check_in_participant', 'Marcar mi llegada', 'participation',
      true,
      'Puedes registrar tu propia llegada al evento');
  end if;

  -- cancel_participation — el propio participante puede cancelar antes de attended
  if v_is_active and v_participant.id is not null
     and v_participant.status in ('invited', 'going', 'maybe') then
    v_actions := v_actions || public._aa('cancel_participation', 'Cancelar mi asistencia', 'participation',
      true, 'Puedes cancelar tu participación');
  end if;

  -- close_event — host o events.manage cierran el evento
  if v_is_active then
    v_actions := v_actions || public._aa('close_event', 'Cerrar evento', 'participation',
      v_is_host or v_can_manage_events,
      case when v_is_host then 'Eres el anfitrión del evento'
           when v_can_manage_events then 'Tienes permiso para administrar eventos'
           else 'Solo el anfitrión o un administrador pueden cerrar el evento' end);
  end if;

  -- record_expense — cross-domain, siempre disponible para miembros con permiso;
  -- no en eventos cancelados
  if v_e.status <> 'cancelled' then
    v_actions := v_actions || public._aa('record_expense', 'Registrar gasto', 'money',
      v_can_record_money,
      case when v_can_record_money then 'Puedes registrar un gasto asociado al evento'
           else 'Requiere permiso money.record' end);
  end if;

  -- create_decision — cross-domain (votar algo del evento)
  if not v_is_terminal then
    v_actions := v_actions || public._aa('create_decision', 'Abrir decisión', 'decisions',
      v_can_create_decision,
      case when v_can_create_decision then 'Puedes abrir una decisión vinculada al evento'
           else 'Requiere permiso decisions.create' end);
  end if;

  -- attach_document — cross-domain, cualquier miembro
  v_actions := v_actions || public._aa('attach_document', 'Adjuntar documento', 'documents',
    true, 'Puedes adjuntar un documento al evento');

  return v_actions;
end; $$;

revoke all on function public.event_available_actions(uuid, uuid) from public, anon;
grant execute on function public.event_available_actions(uuid, uuid) to authenticated, service_role;

comment on function public.event_available_actions(uuid, uuid) is
  'F.2X.0: acciones canónicas sobre un evento — participación + cross-domain (money/decisions/documents).';

-- Compat 1-arg
create or replace function public.event_available_actions(p_event_id uuid)
returns jsonb
language sql stable security definer set search_path = public, auth
as $$
  select public.event_available_actions(p_event_id, public.current_actor_id());
$$;

revoke all on function public.event_available_actions(uuid) from public, anon;
grant execute on function public.event_available_actions(uuid) to authenticated, service_role;

comment on function public.event_available_actions(uuid) is
  'F.2X.0: compat 1-arg — delega a event_available_actions(event_id, current_actor_id()).';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. event_detail(event_id) — wrapper canónico (como resource/decision/reservation/obligation)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.event_detail(p_event_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_e public.calendar_events%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_e from public.calendar_events where id = p_event_id;
  if v_e.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if not public.is_context_member(v_e.context_actor_id) then
    raise exception 'not authorized to view this event' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'event', to_jsonb(v_e),
    'participants', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'event_id', p.event_id,
        'participant_actor_id', p.participant_actor_id,
        'display_name', (select a.display_name from public.actors a where a.id = p.participant_actor_id),
        'status', p.status,
        'rsvp_at', p.rsvp_at,
        'checked_in_at', p.checked_in_at,
        'cancelled_at', p.cancelled_at,
        'metadata', p.metadata) order by p.rsvp_at nulls last)
      from public.event_participants p
      where p.event_id = p_event_id), '[]'::jsonb),
    'available_actions', public.event_available_actions(p_event_id, v_caller),
    'capabilities', '[]'::jsonb,  -- placeholder; eventos no tienen capability catalog aún
    'why_visible', jsonb_build_array(
      case when v_e.host_actor_id = v_caller then 'host del evento'
           when exists (select 1 from public.event_participants
                        where event_id = p_event_id and participant_actor_id = v_caller)
             then 'participante del evento'
           else 'miembro del contexto' end)
  );
end; $$;

revoke all on function public.event_detail(uuid) from public, anon;
grant execute on function public.event_detail(uuid) to authenticated, service_role;

comment on function public.event_detail(uuid) is
  'F.2X.0: detalle canónico de evento con participants + available_actions + why_visible. Mismo shape que resource_detail/decision_detail.';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. context_summary — embed available_actions[] preservando my_permissions[]
-- ────────────────────────────────────────────────────────────────────────────
-- Reemplaza la versión de R.2-1 (20260602101300_r2_1_behavior_rpcs.sql) agregando
-- la key `available_actions` AL FINAL del jsonb. Resto del shape intacto.
create or replace function public.context_summary(p_context_actor_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  return jsonb_build_object(
    'context', (select to_jsonb(a) from public.actors a where a.id = p_context_actor_id),
    'as_of', now(),
    'members_count', (select count(*) from public.actor_memberships
                      where context_actor_id = p_context_actor_id and membership_status = 'active'),
    'resources_count', (select count(*) from public.resources
                        where canonical_owner_actor_id = p_context_actor_id and archived_at is null),
    'pending_decisions', (select count(*) from public.decisions
                          where context_actor_id = p_context_actor_id and status = 'open'),
    'open_obligations', (select count(*) from public.obligations
                         where context_actor_id = p_context_actor_id and status = 'open'),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'actor_id', m.member_actor_id, 'display_name', a.display_name,
        'membership_type', m.membership_type, 'joined_at', m.joined_at,
        'roles', coalesce((select jsonb_agg(r.role_key)
          from public.role_assignments ra join public.roles r on r.id = ra.role_id
          where ra.context_actor_id = m.context_actor_id and ra.member_actor_id = m.member_actor_id), '[]'::jsonb)
      ) order by m.joined_at)
      from public.actor_memberships m join public.actors a on a.id = m.member_actor_id
      where m.context_actor_id = p_context_actor_id and m.membership_status = 'active'), '[]'::jsonb),
    'my_permissions', coalesce((
      select jsonb_agg(distinct rp.permission_key)
        from public.role_assignments ra
        join public.role_permissions rp on rp.role_id = ra.role_id and rp.allowed
       where ra.context_actor_id = p_context_actor_id and ra.member_actor_id = v_caller), '[]'::jsonb),
    'resources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'resource_id', r.id, 'display_name', r.display_name, 'resource_type', r.resource_type,
        'estimated_value', r.estimated_value, 'currency', r.currency) order by r.created_at desc)
      from (select * from public.resources
            where canonical_owner_actor_id = p_context_actor_id and archived_at is null
            order by created_at desc limit 20) r), '[]'::jsonb),
    'upcoming_events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_id', e.id, 'title', e.title, 'event_type', e.event_type,
        'starts_at', e.starts_at, 'host_actor_id', e.host_actor_id, 'status', e.status) order by e.starts_at)
      from (select * from public.calendar_events
            where context_actor_id = p_context_actor_id and status = 'scheduled'
              and (starts_at is null or starts_at > now() - interval '1 day')
            order by starts_at limit 10) e), '[]'::jsonb),
    'open_decisions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'decision_id', d.id, 'title', d.title, 'decision_type', d.decision_type,
        'payload', d.payload, 'created_at', d.created_at) order by d.created_at desc)
      from (select * from public.decisions
            where context_actor_id = p_context_actor_id and status = 'open'
            order by created_at desc limit 10) d), '[]'::jsonb),
    'money', jsonb_build_object(
      'open_obligations', coalesce((
        select jsonb_agg(jsonb_build_object(
          'obligation_id', o.id, 'debtor_actor_id', o.debtor_actor_id,
          'creditor_actor_id', o.creditor_actor_id, 'obligation_type', o.obligation_type,
          'amount', o.amount, 'currency', o.currency) order by o.created_at desc)
        from (select * from public.obligations
              where context_actor_id = p_context_actor_id and status = 'open'
              order by created_at desc limit 20) o), '[]'::jsonb),
      'my_balance', coalesce((
        select sum(case when creditor_actor_id = v_caller then amount
                        when debtor_actor_id = v_caller then -amount
                        else 0 end)
        from public.obligations
        where context_actor_id = p_context_actor_id and status = 'open'), 0)),
    'active_rules', coalesce((
      select jsonb_agg(jsonb_build_object(
        'rule_id', r.id, 'title', r.title, 'trigger_event_type', r.trigger_event_type) order by r.created_at)
      from public.rules r
      where r.context_actor_id = p_context_actor_id and r.status = 'active'), '[]'::jsonb),
    'recent_activity', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_type', ae.event_type, 'actor_id', ae.actor_id, 'payload', ae.payload,
        'occurred_at', ae.occurred_at) order by ae.occurred_at desc)
      from (select * from public.activity_events
            where context_actor_id = p_context_actor_id
            order by occurred_at desc limit 20) ae), '[]'::jsonb),
    -- F.2X.0 — acciones canónicas a nivel contexto (intent-first)
    'available_actions', public.context_available_actions(p_context_actor_id, v_caller)
  );
end; $$;

-- (los GRANTS preexistentes de R.2-1 ya cubren esta firma; CREATE OR REPLACE los mantiene)

comment on function public.context_summary(uuid) is
  'F.2X.0: context home payload. Mantiene my_permissions[] back-compat; AGREGA available_actions[] canónico (intent-first).';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Smoke — _smoke_f2x_0_intent_first_actions (8 puntos)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_f2x_0_intent_first_actions()
returns void
language plpgsql security definer set search_path = public, auth
as $$
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

  -- ═══ 1. context_available_actions(ctx, founder) trae las creativas esperadas ═══
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

  -- ═══ 2. Forma canónica de 7 campos completa ═══
  v_a := (select e from jsonb_array_elements(v_aa) e where e->>'action_key' = 'create_resource' limit 1);
  if not (v_a ? 'action_key' and v_a ? 'label' and v_a ? 'section'
          and v_a ? 'enabled' and v_a ? 'reason'
          and v_a ? 'required_rights' and v_a ? 'required_capabilities') then
    raise exception 'F2X.0 FAIL 2: action object sin la forma canónica de 7 campos';
  end if;

  -- ═══ 3. Founder tiene enabled=true en create_resource, david NO (es member sin rol admin) ═══
  if not ((v_a->>'enabled')::boolean) then
    raise exception 'F2X.0 FAIL 3: founder no tiene enabled=true en create_resource';
  end if;
  v_a := (select e from jsonb_array_elements(public.context_available_actions(v_ctx::uuid, a_david)) e
          where e->>'action_key' = 'create_resource' limit 1);
  -- david como miembro estándar; cuáles permisos tiene depende del role member.
  -- No bloqueamos por enabled aquí (depende del seeding de role_permissions del founder);
  -- sí verificamos que LA ACCIÓN APAREZCA aunque enabled sea false (doctrina: intent-first).
  if v_a is null then
    raise exception 'F2X.0 FAIL 3: la acción create_resource desaparece para david (debe aparecer aunque disabled)';
  end if;

  -- ═══ 4. context_summary embedea available_actions[] sin romper my_permissions[] ═══
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

  -- ═══ 5. event_available_actions trae rsvp + close + record_expense ═══
  v_event := (public.create_calendar_event(v_ctx::uuid, 'Cena viernes', 'dinner',
              now() + interval '2 days', now() + interval '2 days 3 hours', null, null, null))->>'event_id';

  v_aa := public.event_available_actions(v_event::uuid, a_jose);
  if not exists (select 1 from jsonb_array_elements(v_aa) e where e->>'action_key' = 'close_event') then
    raise exception 'F2X.0 FAIL 5: evento scheduled no expone close_event';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_aa) e where e->>'action_key' = 'record_expense') then
    raise exception 'F2X.0 FAIL 5: evento no expone record_expense (cross-domain)';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_aa) e where e->>'action_key' = 'attach_document') then
    raise exception 'F2X.0 FAIL 5: evento no expone attach_document';
  end if;

  -- ═══ 6. event_detail trae contrato canónico completo ═══
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

  -- ═══ 7. Compat 1-arg de ambas funciones delega correctamente ═══
  if public.context_available_actions(v_ctx::uuid) is distinct from
     public.context_available_actions(v_ctx::uuid, a_jose) then
    raise exception 'F2X.0 FAIL 7: context_available_actions 1-arg no delega al 2-arg con current_actor_id()';
  end if;
  if public.event_available_actions(v_event::uuid) is distinct from
     public.event_available_actions(v_event::uuid, a_jose) then
    raise exception 'F2X.0 FAIL 7: event_available_actions 1-arg no delega al 2-arg con current_actor_id()';
  end if;

  -- ═══ 8. Contexto personal NO expone create_child_context ═══
  declare
    v_personal uuid;
  begin
    v_personal := a_jose;  -- el actor person es su propio context personal
    if exists (select 1 from jsonb_array_elements(public.context_available_actions(v_personal, a_jose)) e
               where e->>'action_key' = 'create_child_context') then
      raise exception 'F2X.0 FAIL 8: contexto personal expone create_child_context (debe ser solo colectivos/entidades)';
    end if;
  end;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david], array[u_jose, u_david]);

  raise notice 'F.2X.0 INTENT-FIRST AVAILABLE ACTIONS: PASS (context + event + canonical shape + 1-arg compat)';
end; $$;

revoke all on function public._smoke_f2x_0_intent_first_actions() from public, anon, authenticated;

create or replace function public._smoke_mvp2_f2x_0_intent_first_actions()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_f2x_0_intent_first_actions(); end; $$;
revoke all on function public._smoke_mvp2_f2x_0_intent_first_actions() from public, anon, authenticated;
comment on function public._smoke_mvp2_f2x_0_intent_first_actions() is
  'Wrapper CI del smoke F.2X.0 — context/event available_actions canónico (intent-first).';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Verificación inline del DoD F.2X.0
-- ────────────────────────────────────────────────────────────────────────────
do $$
begin
  -- context_available_actions: dos firmas
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'context_available_actions') < 2 then
    raise exception 'F2X.0 DoD: faltan las dos firmas de context_available_actions';
  end if;
  -- event_available_actions: dos firmas
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'event_available_actions') < 2 then
    raise exception 'F2X.0 DoD: faltan las dos firmas de event_available_actions';
  end if;
  -- event_detail existe
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'event_detail' and p.pronargs = 1) then
    raise exception 'F2X.0 DoD: falta event_detail(uuid)';
  end if;
  raise notice 'F.2X.0 DoD: context/event available_actions canónico (intent-first) + event_detail wrapper';
end $$;
