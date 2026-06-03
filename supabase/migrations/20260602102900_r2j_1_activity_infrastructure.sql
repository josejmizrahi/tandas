-- ============================================================================
-- R.2J-1 — ACTIVITY: taxonomía canónica + atribución de sistema + RLS + list_activity
-- ============================================================================
-- Infraestructura para R.2J (Activity / Reality Validation). Cero schema.
--
--   1. _emit_activity v2 (GATEWAY): normaliza nombres legacy a la taxonomía
--      canónica (member.* → membership.*, document.registered → document.created,
--      money.* → nombres canónicos), garantiza settlement_batch_id/item_id en
--      payloads de settlement.*, y marca payload.system en eventos automáticos.
--   2. evaluate_rules_for_event v4: emisiones automáticas con payload.system,
--      triggered_by_event_type y source_rule_id (auditoría regla → consecuencia).
--   3. detect_reservation_conflicts v3: emite reservation.conflict_detected
--      SOLO para conflictos nuevos (idempotente), con atribución de sistema.
--   4. RLS activity_select v2: miembro del contexto + actor propio + involucrado
--      en la obligation + rights sobre el recurso. Sin SELECT true.
--   5. list_activity(): RPC de lectura paginada con cap de 100.
--   6. Smoke M.3 actualizado (afirmaba sobre el nombre legacy member.joined).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 0. Timeline real: occurred_at/created_at avanzan dentro de una transacción
-- ────────────────────────────────────────────────────────────────────────────
-- R.2J.4 exige reconstruir timelines ordenadas. Con default now() (congelado por
-- transacción), toda la activity de un mismo request comparte timestamp y el
-- orden se pierde. clock_timestamp() avanza en tiempo real.
-- (ALTER de default: no es tabla nueva ni rediseño — es comportamiento.)
alter table public.activity_events alter column occurred_at set default clock_timestamp();
alter table public.activity_events alter column created_at set default clock_timestamp();

-- ────────────────────────────────────────────────────────────────────────────
-- 1. _emit_activity v2 — gateway de taxonomía canónica
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._emit_activity(
  p_context_actor_id uuid,
  p_actor_id uuid,
  p_event_type text,
  p_subject_type text default null,
  p_subject_id uuid default null,
  p_payload jsonb default '{}'::jsonb,
  p_resource_id uuid default null,
  p_decision_id uuid default null,
  p_obligation_id uuid default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_type text;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
begin
  -- R.2J: taxonomía canónica — los nombres legacy se normalizan en el gateway
  v_type := case p_event_type
    when 'member.joined'              then 'membership.joined'
    when 'member.invited'             then 'membership.invited'
    when 'member.removed'             then 'membership.removed'
    when 'member.left'                then 'membership.left'
    when 'document.registered'        then 'document.created'
    when 'money.expense_recorded'     then 'expense.recorded'
    when 'money.fine_recorded'        then 'fine.created'
    when 'money.game_result_recorded' then 'game_result.recorded'
    when 'money.settlement_generated' then 'settlement.generated'
    when 'money.settlement_paid'      then 'settlement.paid'
    when 'event.rsvp'                 then 'event.rsvp_updated'
    else p_event_type
  end;

  -- R.2J.2.9: settlement.* siempre lleva batch/item en el payload
  if v_type like 'settlement.%' then
    if p_subject_type = 'settlement_batch' and p_subject_id is not null then
      v_payload := v_payload || jsonb_build_object('settlement_batch_id', p_subject_id);
    elsif p_subject_type = 'settlement_item' and p_subject_id is not null then
      v_payload := v_payload || jsonb_build_object('settlement_item_id', p_subject_id);
    end if;
    -- normalizar la key legacy batch_id → settlement_batch_id
    if v_payload ? 'batch_id' and not v_payload ? 'settlement_batch_id' then
      v_payload := v_payload || jsonb_build_object('settlement_batch_id', v_payload->'batch_id');
    end if;
  end if;

  -- R.2J.6: los eventos inherentemente automáticos quedan marcados como sistema
  if v_type in ('rule.evaluated', 'reservation.conflict_detected', 'settlement.item_created') then
    v_payload := v_payload || '{"system": true}'::jsonb;
  end if;

  insert into public.activity_events
    (context_actor_id, actor_id, event_type, subject_type, subject_id, payload,
     resource_id, decision_id, obligation_id)
  values
    (p_context_actor_id, coalesce(p_actor_id, public.system_actor_id()), v_type,
     p_subject_type, p_subject_id, v_payload,
     p_resource_id, p_decision_id, p_obligation_id)
  returning id into v_id;
  return v_id;
end; $$;

revoke all on function public._emit_activity(uuid, uuid, text, text, uuid, jsonb, uuid, uuid, uuid) from public, anon, authenticated;

comment on function public._emit_activity(uuid, uuid, text, text, uuid, jsonb, uuid, uuid, uuid) is
  'R.2J: gateway de activity. Normaliza taxonomía canónica, agrega settlement ids al payload y marca eventos automáticos con payload.system.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. evaluate_rules_for_event v4 — auditoría regla → consecuencia
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.evaluate_rules_for_event(
  p_context_actor_id uuid,
  p_trigger_event_type text,
  p_subject_actor_id uuid,
  p_payload jsonb,
  p_source_event_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_rule record;
  v_matched integer := 0;
  v_obligations jsonb := '[]'::jsonb;
  v_rule_obligations jsonb;
  v_consequence jsonb;
  v_obligation_id uuid;
  v_eval_id uuid;
  v_outcome text;
  v_reason text;
  v_obligation_type text;
  v_existing uuid;
  v_is_new boolean;
begin
  -- R.2E gate: ejecución directa solo para self, host del evento, o rules.manage
  if v_caller is not null
     and v_caller <> p_subject_actor_id
     and not exists (
       select 1 from public.calendar_events e
       where e.id = p_source_event_id and e.host_actor_id = v_caller)
     and not public.has_actor_authority(p_context_actor_id, v_caller, 'rules.manage') then
    raise exception 'not authorized to evaluate rules for other actors' using errcode = '42501';
  end if;

  for v_rule in
    select * from public.rules
    where context_actor_id = p_context_actor_id
      and status = 'active'
      and trigger_event_type = p_trigger_event_type
  loop
    v_outcome := case when public._eval_condition(v_rule.condition_tree, p_payload)
                      then 'matched' else 'not_matched' end;
    v_rule_obligations := '[]'::jsonb;

    insert into public.rule_evaluations
      (rule_id, context_actor_id, triggering_event_type, triggering_object_id, outcome, metadata)
    values
      (v_rule.id, p_context_actor_id, p_trigger_event_type, p_source_event_id, v_outcome,
       jsonb_build_object('subject_actor_id', p_subject_actor_id, 'payload', p_payload))
    returning id into v_eval_id;

    if v_outcome = 'matched' then
      v_matched := v_matched + 1;

      for v_consequence in select * from jsonb_array_elements(coalesce(v_rule.consequences, '[]'::jsonb)) loop
        if v_consequence->>'type' in ('fine', 'create_obligation') then
          v_obligation_type := coalesce(v_consequence->>'obligation_type', 'fine');
          v_reason := coalesce(v_consequence->>'reason', v_rule.title);

          select id into v_existing from public.obligations
           where source_rule_id = v_rule.id
             and source_event_id is not distinct from p_source_event_id
             and debtor_actor_id = p_subject_actor_id
             and metadata->>'reason' is not distinct from v_reason
             and status <> 'cancelled'
           limit 1;

          v_is_new := v_existing is null;
          if v_is_new then
            insert into public.obligations
              (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type,
               amount, currency, source_event_id, source_rule_id, metadata)
            values
              (p_context_actor_id, p_subject_actor_id, p_context_actor_id, v_obligation_type,
               (v_consequence->>'amount')::numeric, coalesce(v_consequence->>'currency', 'MXN'),
               p_source_event_id, v_rule.id,
               jsonb_build_object(
                 'reason', v_reason, 'participant_actor_id', p_subject_actor_id,
                 'triggering_event_type', p_trigger_event_type, 'rule_evaluation_id', v_eval_id,
                 'rule_title', v_rule.title, 'trigger', p_trigger_event_type))
            returning id into v_obligation_id;

            -- R.2J.6: consecuencias automáticas auditables — sistema + regla de origen
            perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'obligation.created',
              'obligation', v_obligation_id,
              jsonb_build_object('rule_title', v_rule.title, 'amount', (v_consequence->>'amount')::numeric,
                                 'obligation_type', v_obligation_type, 'reason', v_reason,
                                 'system', true, 'triggered_by_event_type', p_trigger_event_type,
                                 'source_rule_id', v_rule.id),
              p_obligation_id := v_obligation_id);

            if v_obligation_type = 'fine' then
              perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'fine.created',
                'obligation', v_obligation_id,
                jsonb_build_object('rule_title', v_rule.title, 'amount', (v_consequence->>'amount')::numeric,
                                   'reason', v_reason,
                                   'system', true, 'triggered_by_event_type', p_trigger_event_type,
                                   'source_rule_id', v_rule.id),
                p_obligation_id := v_obligation_id);
            end if;
          else
            v_obligation_id := v_existing;
          end if;

          v_rule_obligations := v_rule_obligations || jsonb_build_object(
            'obligation_id', v_obligation_id, 'rule_id', v_rule.id,
            'amount', (v_consequence->>'amount')::numeric, 'already_existed', not v_is_new);
        end if;
      end loop;

      update public.rule_evaluations
         set consequences_emitted = jsonb_build_object('obligations', v_rule_obligations)
       where id = v_eval_id;

      v_obligations := v_obligations || v_rule_obligations;
    end if;

    -- R.2J.6: cada evaluación auditada con su regla y trigger de origen
    perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'rule.evaluated',
      'rule_evaluation', v_eval_id,
      jsonb_build_object('rule_id', v_rule.id, 'rule_title', v_rule.title, 'outcome', v_outcome,
                         'triggered_by_event_type', p_trigger_event_type, 'source_rule_id', v_rule.id));
  end loop;

  return jsonb_build_object('rules_matched', v_matched, 'obligations_created', v_obligations);
end; $$;

revoke all on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) from public, anon;
grant execute on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. detect_reservation_conflicts v3 — emite conflict_detected (solo nuevos)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.detect_reservation_conflicts(p_resource_id uuid)
returns setof public.reservation_conflicts
language plpgsql security definer set search_path = public
as $$
declare
  v_new_ids uuid[];
  v_c public.reservation_conflicts%rowtype;
  v_cid uuid;
begin
  with ins as (
    insert into public.reservation_conflicts
      (resource_id, reservation_a_id, reservation_b_id, conflict_type, recommended_winner_actor_id, metadata)
    select p_resource_id,
           least(a.id, b.id), greatest(a.id, b.id), 'overlap',
           case when coalesce(a.priority_score, 0) <= coalesce(b.priority_score, 0)
                then a.reserved_for_actor_id
                else b.reserved_for_actor_id
           end,
           jsonb_build_object('detected_at', now(),
                              'priority_rule', 'least_recent_use_wins',
                              'scores', jsonb_build_object(
                                a.reserved_for_actor_id::text, coalesce(a.priority_score, 0),
                                b.reserved_for_actor_id::text, coalesce(b.priority_score, 0)))
      from public.resource_reservations a
      join public.resource_reservations b
        on b.resource_id = a.resource_id
       and b.id > a.id
       and tstzrange(a.starts_at, a.ends_at) && tstzrange(b.starts_at, b.ends_at)
     where a.resource_id = p_resource_id
       and a.status in ('requested', 'approved', 'confirmed')
       and b.status in ('requested', 'approved', 'confirmed')
    on conflict (reservation_a_id, reservation_b_id) do nothing
    returning id
  )
  select array_agg(id) into v_new_ids from ins;

  -- R.2J: conflicto detectado = acción automática del sistema, auditada
  -- (solo para conflictos NUEVOS — repetir detect no re-emite)
  if v_new_ids is not null then
    foreach v_cid in array v_new_ids loop
      select * into v_c from public.reservation_conflicts where id = v_cid;
      perform public._emit_activity(
        (select context_actor_id from public.resource_reservations where id = v_c.reservation_a_id),
        null,  -- system actor
        'reservation.conflict_detected', 'reservation_conflict', v_c.id,
        jsonb_build_object('system', true,
                           'triggered_by_event_type', 'reservation.requested',
                           'source_reservation_id', v_c.reservation_a_id,
                           'conflict_id', v_c.id,
                           'reservation_a_id', v_c.reservation_a_id,
                           'reservation_b_id', v_c.reservation_b_id,
                           'recommended_winner_actor_id', v_c.recommended_winner_actor_id),
        p_resource_id := p_resource_id);
    end loop;
  end if;

  return query
    select * from public.reservation_conflicts
    where resource_id = p_resource_id and resolution_status = 'open';
end; $$;

revoke all on function public.detect_reservation_conflicts(uuid) from public, anon;
grant execute on function public.detect_reservation_conflicts(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 3b. resolve_reservation_conflict v3 — emite también approved/rejected
-- ────────────────────────────────────────────────────────────────────────────
-- R.2J: "cada mutación importante genera activity" — resolver un conflicto
-- cambia el status de DOS reservaciones; ambas mutaciones quedan auditadas.
create or replace function public.resolve_reservation_conflict(
  p_conflict_id uuid,
  p_winner_reservation_id uuid
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_c public.reservation_conflicts%rowtype;
  v_loser uuid;
  v_ctx uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_c from public.reservation_conflicts where id = p_conflict_id for update;
  if v_c.id is null then raise exception 'conflict not found' using errcode = 'P0002'; end if;
  if p_winner_reservation_id not in (v_c.reservation_a_id, v_c.reservation_b_id) then
    raise exception 'winner must be one of the conflicting reservations' using errcode = '22023';
  end if;

  select context_actor_id into v_ctx from public.resource_reservations where id = p_winner_reservation_id;

  if not public._can_manage_reservations(v_caller, v_c.resource_id, v_ctx) then
    raise exception 'not authorized to resolve conflicts' using errcode = '42501';
  end if;
  if v_c.resolution_status <> 'open' then
    return jsonb_build_object('conflict_id', p_conflict_id, 'no_op', true);
  end if;

  v_loser := case when p_winner_reservation_id = v_c.reservation_a_id
                  then v_c.reservation_b_id else v_c.reservation_a_id end;

  -- perdedor rejected ANTES de aprobar al ganador (libera el rango para el EXCLUDE)
  update public.resource_reservations set status = 'rejected',
         metadata = metadata || jsonb_build_object('rejected_by_conflict', p_conflict_id)
   where id = v_loser and status in ('requested', 'approved');

  update public.resource_reservations set status = 'approved'
   where id = p_winner_reservation_id and status = 'requested';

  update public.reservation_conflicts
     set resolution_status = 'resolved', resolved_at = now(),
         metadata = metadata || jsonb_build_object('winner', p_winner_reservation_id, 'resolved_by', v_caller)
   where id = p_conflict_id;

  perform public._emit_activity(v_ctx, v_caller, 'reservation.conflict_resolved', 'reservation_conflict', p_conflict_id,
    jsonb_build_object('winner', p_winner_reservation_id, 'loser', v_loser),
    p_resource_id := v_c.resource_id);
  -- R.2J: las dos reservaciones mutadas quedan auditadas
  perform public._emit_activity(v_ctx, v_caller, 'reservation.approved', 'reservation', p_winner_reservation_id,
    jsonb_build_object('by_conflict_resolution', p_conflict_id),
    p_resource_id := v_c.resource_id);
  perform public._emit_activity(v_ctx, v_caller, 'reservation.rejected', 'reservation', v_loser,
    jsonb_build_object('by_conflict_resolution', p_conflict_id),
    p_resource_id := v_c.resource_id);

  return jsonb_build_object('conflict_id', p_conflict_id, 'winner', p_winner_reservation_id, 'loser', v_loser);
end; $$;

revoke all on function public.resolve_reservation_conflict(uuid, uuid) from public, anon;
grant execute on function public.resolve_reservation_conflict(uuid, uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. RLS activity_select v2 — visibilidad por contexto, actor, obligation y rights
-- ────────────────────────────────────────────────────────────────────────────
drop policy if exists activity_select on public.activity_events;
create policy activity_select on public.activity_events
  for select to authenticated
  using (
    -- el actor que ejecutó la acción
    actor_id = public.current_actor_id()
    -- miembro activo del contexto
    or (context_actor_id is not null and public.is_context_member(context_actor_id))
    -- involucrado en la obligation (deudor o acreedor)
    or (obligation_id is not null and exists (
      select 1 from public.obligations o
      where o.id = activity_events.obligation_id
        and public.current_actor_id() in (o.debtor_actor_id, o.creditor_actor_id)))
    -- rights sobre el recurso
    or (resource_id is not null and exists (
      select 1 from public.resource_rights rr
      where rr.resource_id = activity_events.resource_id
        and rr.holder_actor_id = public.current_actor_id()
        and rr.right_kind in ('VIEW', 'USE', 'MANAGE', 'OWN', 'BENEFICIARY')
        and rr.revoked_at is null and rr.expired_at is null))
  );

-- escrituras directas bloqueadas: solo el gateway _emit_activity (security definer) inserta
revoke insert, update, delete on public.activity_events from authenticated, anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. list_activity — RPC de lectura paginada
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.list_activity(
  p_context_actor_id uuid,
  p_limit int default 50,
  p_before timestamptz default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_limit int;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  -- autoridad de lectura: miembro activo del contexto
  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  -- cap duro de 100
  v_limit := least(greatest(coalesce(p_limit, 50), 1), 100);

  return jsonb_build_object(
    'context_actor_id', p_context_actor_id,
    'limit', v_limit,
    'activity', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', ae.id,
        'event_type', ae.event_type,
        'actor_id', ae.actor_id,
        'subject_type', ae.subject_type,
        'subject_id', ae.subject_id,
        'payload', ae.payload,
        'resource_id', ae.resource_id,
        'decision_id', ae.decision_id,
        'obligation_id', ae.obligation_id,
        'occurred_at', ae.occurred_at) order by ae.occurred_at desc, ae.created_at desc)
      from (
        select * from public.activity_events
        where context_actor_id = p_context_actor_id
          and (p_before is null or occurred_at < p_before)
        order by occurred_at desc, created_at desc
        limit v_limit
      ) ae), '[]'::jsonb));
end; $$;

revoke all on function public.list_activity(uuid, int, timestamptz) from public, anon;
grant execute on function public.list_activity(uuid, int, timestamptz) to authenticated, service_role;

comment on function public.list_activity(uuid, int, timestamptz) is
  'R.2J: lista la activity de un contexto (miembros activos), orden occurred_at desc, cap 100, paginación con p_before.';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Smoke M.3 actualizado: la taxonomía canónica renombró member.joined
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_m3_contexts()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_ctx uuid;
  v_result jsonb; v_code text; v_invite_id uuid;
  v_caught boolean;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M3A', '+520000000004', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M3B', '+520000000005', null);

  -- Caso 1: create_context crea actor + founder membership + admin role
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_context('_smoke_m3 Cena Semanal', 'collective', 'friend_group');
  v_ctx := (v_result->>'context_actor_id')::uuid;
  if v_ctx is null then raise exception 'mvp2_m3 Caso1: create_context failed'; end if;
  if not public.has_actor_authority(v_ctx, v_a, 'context.manage') then
    raise exception 'mvp2_m3 Caso1: founder sin context.manage';
  end if;

  -- Caso 2: create_invite por founder
  v_result := public.create_invite(v_ctx, p_max_uses := 5);
  v_code := v_result->>'code';
  v_invite_id := (v_result->>'invite_id')::uuid;
  if v_code is null or length(v_code) <> 8 then
    raise exception 'mvp2_m3 Caso2: invite code inválido: %', v_code;
  end if;

  -- Caso 3: B sin autoridad NO puede crear invite
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_caught := false;
  begin
    perform public.create_invite(v_ctx);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'mvp2_m3 Caso3: no-member pudo crear invite'; end if;

  -- Caso 4: B se une con el código → miembro activo con role member
  v_result := public.join_by_invite_code(v_code);
  if (v_result->>'context_actor_id')::uuid is distinct from v_ctx then
    raise exception 'mvp2_m3 Caso4: join failed';
  end if;
  if not public.has_actor_authority(v_ctx, v_b, 'events.view') then
    raise exception 'mvp2_m3 Caso4: B sin permissions de member';
  end if;

  -- Caso 5: join idempotente (no duplica membership)
  v_result := public.join_by_invite_code(v_code);
  if (select count(*) from public.actor_memberships
      where context_actor_id = v_ctx and member_actor_id = v_b) <> 1 then
    raise exception 'mvp2_m3 Caso5: membership duplicada';
  end if;

  -- Caso 6: context_candidates de B incluye el contexto
  v_result := public.context_candidates();
  if not exists (
    select 1 from jsonb_array_elements(v_result->'contexts') c
    where (c->>'context_actor_id')::uuid = v_ctx
  ) then
    raise exception 'mvp2_m3 Caso6: contexto no aparece en candidates de B';
  end if;

  -- Caso 7: context_summary para member + actividad registrada
  -- (R.2J: taxonomía canónica — membership.joined en vez de member.joined)
  v_result := public.context_summary(v_ctx);
  if jsonb_array_length(v_result->'members') < 2 then
    raise exception 'mvp2_m3 Caso7: members incompletos';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_result->'recent_activity') e
    where e->>'event_type' = 'membership.joined'
  ) then
    raise exception 'mvp2_m3 Caso7: activity membership.joined no registrada';
  end if;

  -- Caso 8: invite revocado rechaza joins
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.revoke_invite(v_invite_id);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_caught := false;
  begin
    perform public.join_by_invite_code(v_code);
  exception when no_data_found or sqlstate 'P0002' then v_caught := true;
  end;
  if not v_caught then raise exception 'mvp2_m3 Caso8: invite revocado aceptó join'; end if;

  -- Caso 9: no-member NO puede ver context_summary
  perform set_config('request.jwt.claims', null, true);
  declare
    v_auth_c uuid := gen_random_uuid();
    v_c uuid;
  begin
    v_c := public._create_person_actor_for_auth_user(v_auth_c, 'Smoke M3C', '+520000000006', null);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
    v_caught := false;
    begin
      perform public.context_summary(v_ctx);
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m3 Caso9: no-member vio context_summary'; end if;
    perform set_config('request.jwt.claims', null, true);
    delete from public.person_profiles where actor_id = v_c;
    delete from public.actors where id = v_c;
    delete from auth.users where id = v_auth_c;
  end;

  -- Cleanup (activity_events es append-only — sus rows quedan como residuo aceptado)
  perform set_config('request.jwt.claims', null, true);
  delete from public.context_invites where context_actor_id = v_ctx;
  delete from public.role_assignments where context_actor_id = v_ctx;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx;
  delete from public.roles where context_actor_id = v_ctx;
  delete from public.actor_memberships where context_actor_id = v_ctx;
  delete from public.actors where id = v_ctx;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_m3_contexts passed (9 casos)';
end; $$;

revoke all on function public._smoke_mvp2_m3_contexts() from public, anon, authenticated;

comment on function public._smoke_mvp2_m3_contexts() is 'Smoke MVP2 M.3: contextos, invites, joins, candidates, summary (taxonomía canónica R.2J).';
