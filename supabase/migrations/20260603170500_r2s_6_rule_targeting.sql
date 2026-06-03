-- ============================================================================
-- R.2S.5 — RULE TARGETING MODEL
-- ============================================================================
-- No todas las reglas aplican a cenas. Rule = trigger + target + condition +
-- consequence. Se agrega al modelo lógico (sin tablas nuevas):
--
--   rules.target_scope   → context | event_type | event | resource_type |
--                          resource | decision | reservation | membership |
--                          money_transaction | obligation | custom
--   rules.target_filter  → jsonb {key: value} que debe coincidir con el payload
--
-- La MISMA infraestructura (evaluate_rules_for_event + condition_tree +
-- consequences) soporta reglas para events, reservations, money, decisions,
-- memberships y obligations. El trigger_event_type encodea el dominio
-- ('event.checked_in', 'reservation.cancelled', 'money.expense_recorded', …) y
-- target_filter acota a un recurso/tipo/decisión específicos.
--
-- Hooks de disparo añadidos:
--   record_expense   → 'money.expense_recorded'   (en r2s_3_split_models)
--   cancel_reservation → 'reservation.cancelled'  (aquí)
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Columnas target_scope / target_filter
-- ────────────────────────────────────────────────────────────────────────────
alter table public.rules
  add column if not exists target_scope text not null default 'event_type',
  add column if not exists target_filter jsonb not null default '{}';

comment on column public.rules.target_scope is
  'R.2S.5: dominio al que apunta la regla (context|event_type|event|resource|resource_type|decision|reservation|membership|money_transaction|obligation|custom).';
comment on column public.rules.target_filter is
  'R.2S.5: filtro {key:value} que debe coincidir con el payload del trigger (ej. {"resource_id":"…"} o {"event_type":"dinner"}).';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. _rule_target_matches(filter, payload)
-- ────────────────────────────────────────────────────────────────────────────
-- Toda key del filtro debe igualar (como texto) el valor correspondiente del
-- payload. Filtro vacío {} → matchea todo (compatibilidad con reglas previas).
create or replace function public._rule_target_matches(p_filter jsonb, p_payload jsonb)
returns boolean
language sql immutable
as $$
  select not exists (
    select 1
      from jsonb_each_text(coalesce(p_filter, '{}'::jsonb)) f
     where coalesce(p_payload->>f.key, '__missing__') is distinct from f.value
  );
$$;

revoke all on function public._rule_target_matches(jsonb, jsonb) from public, anon;
grant execute on function public._rule_target_matches(jsonb, jsonb) to authenticated, service_role;

comment on function public._rule_target_matches(jsonb, jsonb) is
  'R.2S.5: ¿el payload del trigger satisface el target_filter de la regla? Filtro vacío matchea todo.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. create_rule overload con target_scope / target_filter
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.create_rule(
  p_context_actor_id uuid,
  p_title text,
  p_trigger_event_type text,
  p_condition_tree jsonb,
  p_consequences jsonb,
  p_target_scope text,
  p_target_filter jsonb default '{}'::jsonb,
  p_body text default null,
  p_rule_type text default 'automation',
  p_severity int default 1
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'rules.manage') then
    raise exception 'not authorized to create rules in context %', p_context_actor_id using errcode = '42501';
  end if;
  if coalesce(p_target_scope, 'event_type') not in (
    'context','event_type','event','resource_type','resource','decision',
    'reservation','membership','money_transaction','obligation','custom') then
    raise exception 'unknown target_scope %', p_target_scope using errcode = '22023';
  end if;

  insert into public.rules
    (context_actor_id, title, body, rule_type, severity, trigger_event_type,
     condition_tree, consequences, target_scope, target_filter, created_by_actor_id)
  values
    (p_context_actor_id, btrim(p_title), p_body, p_rule_type, p_severity, p_trigger_event_type,
     coalesce(p_condition_tree, '{}'::jsonb), coalesce(p_consequences, '[]'::jsonb),
     coalesce(p_target_scope, 'event_type'), coalesce(p_target_filter, '{}'::jsonb), v_caller)
  returning id into v_id;

  perform public._emit_activity(p_context_actor_id, v_caller, 'rule.created', 'rule', v_id,
    jsonb_build_object('title', btrim(p_title), 'trigger_event_type', p_trigger_event_type,
                       'target_scope', coalesce(p_target_scope, 'event_type')));

  return jsonb_build_object('rule_id', v_id,
    'rule', (select to_jsonb(r) from public.rules r where r.id = v_id));
end; $$;

revoke all on function public.create_rule(uuid, text, text, jsonb, jsonb, text, jsonb, text, text, int) from public, anon;
grant execute on function public.create_rule(uuid, text, text, jsonb, jsonb, text, jsonb, text, text, int) to authenticated, service_role;

comment on function public.create_rule(uuid, text, text, jsonb, jsonb, text, jsonb, text, text, int) is
  'R.2S.5: crea una regla con target_scope + target_filter (overload del create_rule clásico).';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. evaluate_rules_for_event v5 — filtra por target_filter
-- ────────────────────────────────────────────────────────────────────────────
-- Idéntico a R.2J salvo: además de trigger_event_type, la regla debe satisfacer
-- su target_filter contra el payload. Reglas con filtro vacío (todo lo previo)
-- siguen comportándose igual.
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
  v_kind text;
  v_title text;
  v_obligation_type text;
  v_existing uuid;
  v_is_new boolean;
begin
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
      and public._rule_target_matches(coalesce(target_filter, '{}'::jsonb), p_payload)  -- R.2S.5
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
          -- R.2R: kind determina money vs action ('fine'/create_obligation sin kind → money)
          v_kind := coalesce(v_consequence->>'kind', 'money');
          v_title := coalesce(v_consequence->>'title', v_rule.title);
          v_reason := coalesce(v_consequence->>'reason', v_consequence->>'title', v_rule.title);

          select id into v_existing from public.obligations
           where source_rule_id = v_rule.id
             and source_event_id is not distinct from p_source_event_id
             and debtor_actor_id = p_subject_actor_id
             and metadata->>'reason' is not distinct from v_reason
             and status <> 'cancelled'
           limit 1;

          v_is_new := v_existing is null;
          if v_is_new then
            if v_kind = 'money' then
              v_obligation_type := coalesce(v_consequence->>'obligation_type', 'fine');
              insert into public.obligations
                (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_kind, obligation_type,
                 amount, currency, source_event_id, source_rule_id, metadata)
              values
                (p_context_actor_id, p_subject_actor_id, p_context_actor_id, 'money', v_obligation_type,
                 (v_consequence->>'amount')::numeric, coalesce(v_consequence->>'currency', 'MXN'),
                 p_source_event_id, v_rule.id,
                 jsonb_build_object(
                   'reason', v_reason, 'participant_actor_id', p_subject_actor_id,
                   'triggering_event_type', p_trigger_event_type, 'rule_evaluation_id', v_eval_id,
                   'rule_title', v_rule.title, 'trigger', p_trigger_event_type,
                   'target_scope', v_rule.target_scope))
              returning id into v_obligation_id;
            else
              -- R.2R: action obligation generada por regla (sin dinero)
              v_obligation_type := coalesce(v_consequence->>'obligation_type', 'other');
              insert into public.obligations
                (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_kind, obligation_type,
                 title, description, due_at, source_event_id, source_rule_id, metadata)
              values
                (p_context_actor_id, p_subject_actor_id, p_context_actor_id, v_kind, v_obligation_type,
                 v_title, v_consequence->>'description',
                 nullif(v_consequence->>'due_at', '')::timestamptz,
                 p_source_event_id, v_rule.id,
                 jsonb_build_object(
                   'reason', v_reason, 'participant_actor_id', p_subject_actor_id,
                   'triggering_event_type', p_trigger_event_type, 'rule_evaluation_id', v_eval_id,
                   'rule_title', v_rule.title, 'trigger', p_trigger_event_type,
                   'target_scope', v_rule.target_scope))
              returning id into v_obligation_id;
            end if;

            perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'obligation.created',
              'obligation', v_obligation_id,
              jsonb_build_object('rule_title', v_rule.title, 'kind', v_kind, 'title', v_title,
                                 'amount', (v_consequence->>'amount')::numeric,
                                 'obligation_type', v_obligation_type, 'reason', v_reason,
                                 'system', true, 'triggered_by_event_type', p_trigger_event_type,
                                 'source_rule_id', v_rule.id),
              p_obligation_id := v_obligation_id);

            if v_kind = 'money' and v_obligation_type = 'fine' then
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
            'obligation_id', v_obligation_id, 'rule_id', v_rule.id, 'kind', v_kind,
            'amount', (v_consequence->>'amount')::numeric, 'already_existed', not v_is_new);
        end if;
      end loop;

      update public.rule_evaluations
         set consequences_emitted = jsonb_build_object('obligations', v_rule_obligations)
       where id = v_eval_id;

      v_obligations := v_obligations || v_rule_obligations;
    end if;

    perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'rule.evaluated',
      'rule_evaluation', v_eval_id,
      jsonb_build_object('rule_id', v_rule.id, 'rule_title', v_rule.title, 'outcome', v_outcome,
                         'triggered_by_event_type', p_trigger_event_type, 'source_rule_id', v_rule.id));
  end loop;

  return jsonb_build_object('rules_matched', v_matched, 'obligations_created', v_obligations);
end; $$;

revoke all on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) from public, anon;
grant execute on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) to authenticated, service_role;

comment on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) is
  'R.2S.5: evaluador universal de reglas. Filtra por trigger_event_type + target_filter; soporta cualquier dominio.';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. cancel_reservation v2 — dispara reglas del dominio reservation
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.cancel_reservation(p_reservation_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_r public.resource_reservations%rowtype;
  v_hours_before numeric;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_r from public.resource_reservations where id = p_reservation_id for update;
  if v_r.id is null then raise exception 'reservation not found' using errcode = 'P0002'; end if;
  if v_r.status in ('cancelled', 'completed', 'rejected') then
    return jsonb_build_object('reservation_id', p_reservation_id, 'status', v_r.status, 'no_op', true);
  end if;

  if not (
    v_r.requested_by_actor_id = v_caller
    or v_r.reserved_for_actor_id = v_caller
    or public.has_actor_authority(v_r.context_actor_id, v_caller, 'reservations.manage')
  ) then
    raise exception 'not authorized to cancel reservation %', p_reservation_id using errcode = '42501';
  end if;

  update public.resource_reservations set status = 'cancelled' where id = p_reservation_id;

  update public.reservation_conflicts
     set resolution_status = 'dismissed', resolved_at = now(),
         metadata = metadata || jsonb_build_object('dismissed_reason', 'reservation_cancelled')
   where (reservation_a_id = p_reservation_id or reservation_b_id = p_reservation_id)
     and resolution_status = 'open';

  perform public._emit_activity(v_r.context_actor_id, v_caller, 'reservation.cancelled', 'reservation', p_reservation_id,
    '{}'::jsonb, p_resource_id := v_r.resource_id);

  -- ═══ R.2S.5: la misma infraestructura de reglas aplica al dominio reservation ═══
  -- payload con resource_id (para target_filter por recurso) + horas de anticipación
  v_hours_before := round(extract(epoch from (v_r.starts_at - now())) / 3600.0, 2);
  perform public.evaluate_rules_for_event(
    v_r.context_actor_id, 'reservation.cancelled',
    coalesce(v_r.reserved_for_actor_id, v_caller),
    jsonb_build_object('resource_id', v_r.resource_id::text, 'hours_before', v_hours_before,
                       'reservation_id', p_reservation_id::text, 'starts_at', v_r.starts_at),
    null);

  return jsonb_build_object('reservation_id', p_reservation_id, 'status', 'cancelled');
end; $$;

revoke all on function public.cancel_reservation(uuid) from public, anon;
grant execute on function public.cancel_reservation(uuid) to authenticated, service_role;

comment on function public.cancel_reservation(uuid) is
  'R.2S.5: cancela una reservación y dispara reglas del dominio reservation (reservation.cancelled).';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Smoke — _smoke_r2s_rule_targeting
-- ────────────────────────────────────────────────────────────────────────────
-- Una MISMA infraestructura: regla para reservation (cancelación tardía) y
-- regla para money (gasto grande), no solo events.
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
                now() + interval '24 hours', now() + interval '26 hours'))->>'reservation_id';

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
                now() + interval '24 hours', now() + interval '26 hours'))->>'reservation_id';
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

revoke all on function public._smoke_r2s_rule_targeting() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2s_rule_targeting()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_r2s_rule_targeting(); end; $$;
revoke all on function public._smoke_mvp2_r2s_rule_targeting() from public, anon, authenticated;
comment on function public._smoke_mvp2_r2s_rule_targeting() is 'Wrapper CI del smoke R.2S.5 rule targeting.';
