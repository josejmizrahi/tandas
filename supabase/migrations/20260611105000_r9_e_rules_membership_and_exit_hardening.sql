-- ═══════════════════════════════════════════════════════════════════════════
-- R.9.E — Hardening: snapshot de membresía en el rule engine + exit guard en
--         remove_member + verificación del attention inbox (no-op documentado).
--
-- 1. Rules membership snapshot (no phantom fines):
--    `_r6_eval_rules_core` (última definición: 20260608113000_r6_b_fix_rls_...)
--    ahora salta las consecuencias 'fine' / 'create_obligation' cuando el
--    subject NO tiene membresía ACTIVA en el contexto de la regla al momento
--    de evaluar. El skip queda registrado en consequences_emitted de la
--    rule_evaluation ({skipped: true, skip_reason: 'subject_not_active_member'}).
--    Los placeholders (R.5W) tienen membership_status = 'active' → siguen
--    siendo multables. `evaluate_rules_for_event` (última definición:
--    20260608111234_r6_b_auto_dispatch...) NO se redefine: es un wrapper de
--    auth que delega 100% al core, así que el guard cubre wrapper + trigger.
--
-- 2. remove_member exit guard (última definición: 20260605000000_r5_governance_engine):
--    si el miembro tiene obligaciones de dinero ABIERTAS (status='open',
--    obligation_kind='money') en el contexto como deudor o acreedor, la
--    remoción falla con 'member_has_open_obligations' (errcode 22023), salvo
--    p_force => true (override admin; misma autoridad members.manage de
--    siempre). Cuando se fuerza, el activity member.removed lleva
--    {forced: true, open_obligations_count: N}. Firma nueva → DROP de la
--    firma vieja (uuid, uuid, text) + CREATE (patrón 20260604000205) +
--    re-aplicación de grants.
--    Smoke tocado: `_smoke_r2h_money_expenses_dod` (última definición:
--    20260611101000_r9_b_money_idempotency_and_execute_locks §5) removía a
--    Daniel con la deuda de Catan ($250) abierta — se redefine aquí con el
--    cambio mínimo (p_force => true en esa línea) para que el lockout
--    post-remoción que ese smoke prueba siga verificándose. De paso se corrige
--    su check anon-block roto por R.9.C (firma 12-arg de record_expense ya
--    dropeada → 14-arg vigente). Auditados los demás call sites de
--    remove_member en smokes CI (_smoke_mvp2_r2b_membership_dod,
--    _smoke_r2d_events_dod, _smoke_r2g_decisions_dod vía 20260603164118,
--    _r2j_make_world vía 20260603015824): ninguno remueve miembros con
--    obligaciones money abiertas.
--
-- 3. attention_inbox: NO-OP verificado. La última definición
--    (20260608234500_r7_g_attention_inbox_governance_pending) YA incluye las
--    filas OPEN de rule_attention_items dirigidas al caller (sección "R.6.A:
--    rule-emitted attention items": subject_actor_id = caller, status='open',
--    kind passthrough, subject_id = rai.id → dismissible vía
--    dismiss_attention_item). Los sinks nuevos de settlement handshake/appeal
--    y host_confirm (20260610200000/220000/230000) insertan en
--    rule_attention_items con subject_actor_id → fluyen solos por esa sección.
--    governance_pending ya lo agregó R.7.G. Nada que agregar.
--
-- Smoke nuevo: _smoke_mvp2_r9_e_hardening() (corre en CI vía edge-tests).
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. _r6_eval_rules_core — copia exacta de 20260608113000 + guard de membresía
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._r6_eval_rules_core(
  p_context_actor_id uuid,
  p_trigger_event_type text,
  p_subject_actor_id uuid,
  p_payload jsonb,
  p_source_event_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to public, auth
set row_security to off
as $$
declare
  v_rule record;
  v_matched integer := 0;
  v_obligations jsonb := '[]'::jsonb;
  v_attentions jsonb := '[]'::jsonb;
  v_rule_obligations jsonb;
  v_rule_attentions jsonb;
  v_consequence jsonb;
  v_consequence_index int;
  v_obligation_id uuid;
  v_attention_id uuid;
  v_eval_id uuid;
  v_outcome text;
  v_reason text;
  v_kind text;
  v_title text;
  v_obligation_type text;
  v_existing uuid;
  v_is_new boolean;
  v_idempotency_key text;
  v_calendar_event_id uuid;
  v_subject_active boolean := false;
begin
  -- Translate p_source_event_id → calendar_event_id si existe en la tabla.
  -- Trigger path pasa activity_event.id (no calendar_event); wrapper manual pasa el real.
  if p_source_event_id is not null then
    select id into v_calendar_event_id
      from public.calendar_events where id = p_source_event_id;
  end if;

  -- R.9.E — Snapshot de membresía del subject al momento de evaluar.
  -- Sin membresía ACTIVA en el contexto de la regla, las consecuencias que
  -- crean obligaciones/multas se saltan (no phantom fines para removidos/
  -- salidos). Los placeholders SÍ tienen membership_status = 'active'
  -- (R.5W slice 1) → siguen siendo multables.
  select exists (
    select 1 from public.actor_memberships am
     where am.context_actor_id = p_context_actor_id
       and am.member_actor_id = p_subject_actor_id
       and am.membership_status = 'active'
  ) into v_subject_active;

  for v_rule in
    select * from public.rules
    where context_actor_id = p_context_actor_id
      and status = 'active'
      and trigger_event_type = p_trigger_event_type
      and public._rule_target_matches(coalesce(target_filter, '{}'::jsonb), p_payload)
  loop
    v_outcome := case when public._eval_condition(v_rule.condition_tree, p_payload)
                      then 'matched' else 'not_matched' end;
    v_rule_obligations := '[]'::jsonb;
    v_rule_attentions := '[]'::jsonb;

    v_idempotency_key := public._r6_compute_idempotency_key(
      v_rule.id, p_source_event_id, p_subject_actor_id, -1
    );

    insert into public.rule_evaluations
      (rule_id, context_actor_id, triggering_event_type, triggering_object_id,
       outcome, metadata, idempotency_key)
    values
      (v_rule.id, p_context_actor_id, p_trigger_event_type, p_source_event_id, v_outcome,
       jsonb_build_object('subject_actor_id', p_subject_actor_id, 'payload', p_payload),
       v_idempotency_key)
    on conflict (idempotency_key) do nothing
    returning id into v_eval_id;

    if v_eval_id is null then
      select id into v_eval_id from public.rule_evaluations
       where idempotency_key = v_idempotency_key
       limit 1;
      continue;
    end if;

    if v_outcome = 'matched' then
      v_matched := v_matched + 1;
      v_consequence_index := 0;

      for v_consequence in select * from jsonb_array_elements(coalesce(v_rule.consequences, '[]'::jsonb)) loop
        if v_consequence->>'type' in ('fine', 'create_obligation') then
          -- R.9.E guard: subject sin membresía activa → skip de la consecuencia,
          -- con nota en consequences_emitted de la evaluación (mismo shape que
          -- las entradas normales de 'obligations').
          if not v_subject_active then
            v_rule_obligations := v_rule_obligations || jsonb_build_object(
              'obligation_id', null,
              'rule_id', v_rule.id,
              'kind', coalesce(v_consequence->>'kind', 'money'),
              'skipped', true,
              'skip_reason', 'subject_not_active_member');
            v_consequence_index := v_consequence_index + 1;
            continue;
          end if;

          v_kind := coalesce(v_consequence->>'kind', 'money');
          v_title := coalesce(v_consequence->>'title', v_rule.title);
          v_reason := coalesce(v_consequence->>'reason', v_consequence->>'title', v_rule.title);

          select id into v_existing from public.obligations
           where source_rule_id = v_rule.id
             and source_event_id is not distinct from v_calendar_event_id
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
                 v_calendar_event_id, v_rule.id,
                 jsonb_build_object(
                   'reason', v_reason, 'participant_actor_id', p_subject_actor_id,
                   'triggering_event_type', p_trigger_event_type, 'rule_evaluation_id', v_eval_id,
                   'rule_title', v_rule.title, 'trigger', p_trigger_event_type,
                   'target_scope', v_rule.target_scope,
                   'source_activity_event_id', p_source_event_id))
              returning id into v_obligation_id;
            else
              v_obligation_type := coalesce(v_consequence->>'obligation_type', 'other');
              insert into public.obligations
                (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_kind, obligation_type,
                 title, description, due_at, source_event_id, source_rule_id, metadata)
              values
                (p_context_actor_id, p_subject_actor_id, p_context_actor_id, v_kind, v_obligation_type,
                 v_title, v_consequence->>'description',
                 nullif(v_consequence->>'due_at', '')::timestamptz,
                 v_calendar_event_id, v_rule.id,
                 jsonb_build_object(
                   'reason', v_reason, 'participant_actor_id', p_subject_actor_id,
                   'triggering_event_type', p_trigger_event_type, 'rule_evaluation_id', v_eval_id,
                   'rule_title', v_rule.title, 'trigger', p_trigger_event_type,
                   'target_scope', v_rule.target_scope,
                   'source_activity_event_id', p_source_event_id))
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

        elsif v_consequence->>'type' = 'emit_attention' then
          v_attention_id := public._r6_emit_attention(
            p_context_actor_id := p_context_actor_id,
            p_subject_actor_id := p_subject_actor_id,
            p_consequence := v_consequence,
            p_rule_id := v_rule.id,
            p_source_event_id := p_source_event_id,
            p_idempotency_key := public._r6_compute_idempotency_key(
              v_rule.id, p_source_event_id, p_subject_actor_id, v_consequence_index
            )
          );
          v_rule_attentions := v_rule_attentions || jsonb_build_object(
            'attention_id', v_attention_id,
            'kind', coalesce(v_consequence->>'kind', 'rule_violation'),
            'rule_id', v_rule.id,
            'already_existed', v_attention_id is null
          );
        end if;

        v_consequence_index := v_consequence_index + 1;
      end loop;

      update public.rule_evaluations
         set consequences_emitted = jsonb_build_object(
           'obligations', v_rule_obligations,
           'attentions',  v_rule_attentions
         )
       where id = v_eval_id;

      v_obligations := v_obligations || v_rule_obligations;
      v_attentions := v_attentions || v_rule_attentions;
    end if;

    perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'rule.evaluated',
      'rule_evaluation', v_eval_id,
      jsonb_build_object('rule_id', v_rule.id, 'rule_title', v_rule.title, 'outcome', v_outcome,
                         'triggered_by_event_type', p_trigger_event_type, 'source_rule_id', v_rule.id));
  end loop;

  return jsonb_build_object(
    'rules_matched', v_matched,
    'obligations_created', v_obligations,
    'attentions_emitted', v_attentions
  );
end;
$$;
-- ─────────────────────────────────────────────────────────────────────────────
-- 2. remove_member — copia exacta de 20260605000000 + exit guard + p_force.
--    Firma nueva (4 args) → DROP de la vieja para no dejar overload ambiguo
--    en PostgREST (patrón 20260604000205).
-- ─────────────────────────────────────────────────────────────────────────────

drop function if exists public.remove_member(uuid, uuid, text);

create or replace function public.remove_member(
  p_context_actor_id uuid,
  p_member_actor_id uuid,
  p_reason text default null,
  p_force boolean default false
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ga uuid;
  v_open_obligations integer := 0;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'members.manage') then
    raise exception 'not authorized to remove members' using errcode = '42501';
  end if;
  if p_member_actor_id = v_caller then
    raise exception 'use leave_context to remove yourself' using errcode = '22023';
  end if;

  -- R.9.E exit guard: obligaciones de dinero ABIERTAS (como deudor o acreedor)
  -- bloquean la remoción, salvo override admin explícito con p_force => true.
  select count(*) into v_open_obligations
    from public.obligations o
   where o.context_actor_id = p_context_actor_id
     and o.status = 'open'
     and o.obligation_kind = 'money'
     and (o.debtor_actor_id = p_member_actor_id or o.creditor_actor_id = p_member_actor_id);

  if v_open_obligations > 0 and not p_force then
    raise exception 'member_has_open_obligations: el miembro tiene % obligación(es) de dinero abiertas en este contexto', v_open_obligations
      using errcode = '22023',
      hint = 'liquida, perdona o disputa las obligaciones primero, o repite con p_force => true (override admin)';
  end if;

  if public.governance_policy(p_context_actor_id, 'member_ban_requires_vote') = 'true'::jsonb then
    v_ga := public._governance_action_approved(p_context_actor_id, 'member_ban', p_member_actor_id);
    if v_ga is null then
      raise exception 'governance_required: removing a member requires an approved decision in this context'
        using errcode = '42501',
        hint = 'call request_governed_action(context, ''member_ban'', ''actor'', member_id) and get it approved first';
    end if;
  end if;

  update public.actor_memberships
     set membership_status = 'removed', left_at = now(),
         metadata = metadata || jsonb_strip_nulls(jsonb_build_object('removed_by', v_caller, 'reason', p_reason))
   where context_actor_id = p_context_actor_id and member_actor_id = p_member_actor_id
     and membership_status in ('active', 'invited', 'paused');

  update public.role_assignments set ends_at = now()
   where context_actor_id = p_context_actor_id and member_actor_id = p_member_actor_id and ends_at is null;

  if v_ga is not null then
    update public.governance_actions
       set status = 'executed', executed_by_actor_id = v_caller, executed_at = now()
     where id = v_ga;
  end if;

  perform public._emit_activity(p_context_actor_id, v_caller, 'member.removed', 'actor', p_member_actor_id,
    jsonb_strip_nulls(jsonb_build_object('reason', p_reason, 'governance_action_id', v_ga))
    || case when p_force and v_open_obligations > 0
            then jsonb_build_object('forced', true, 'open_obligations_count', v_open_obligations)
            else '{}'::jsonb end);

  return jsonb_build_object('removed', true, 'governance_action_id', v_ga);
end;
$$;
revoke all on function public.remove_member(uuid, uuid, text, boolean) from public, anon;
grant execute on function public.remove_member(uuid, uuid, text, boolean) to authenticated, service_role;

comment on function public.remove_member(uuid, uuid, text, boolean) is
  'R.9.E — Remueve un miembro del contexto (members.manage). Bloquea con
member_has_open_obligations (22023) si el miembro tiene obligaciones money
abiertas como deudor o acreedor, salvo p_force => true (override admin; el
activity member.removed lleva forced + open_obligations_count). Conserva el
gate de gobernanza member_ban_requires_vote de R.5.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2b. _smoke_r2h_money_expenses_dod — redefinición con cambios mínimos:
--     a) Daniel llega a la remoción con la deuda de Catan ($250 game_debt, open)
--        → el nuevo guard la bloquearía y rompería CI. El smoke prueba el lockout
--        post-remoción (miembro removido no puede registrar gastos), no la
--        política de salida → p_force => true preserva la intención original.
--     b) El check anon-block referenciaba la firma 12-arg de record_expense que
--        R.9.C (20260611102000) dropeó al crear la 14-arg → se actualiza a la
--        firma vigente (has_function_privilege con firma inexistente = 42883).
--     Cuerpo = copia exacta de la última definición
--     (20260611101000_r9_b_money_idempotency_and_execute_locks, §5)
--     salvo esas dos líneas.
-- ─────────────────────────────────────────────────────────────────────────────

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
  v_ctx := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group'))->>'context_actor_id';
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
end; $function$
;



-- ─────────────────────────────────────────────────────────────────────────────
-- 3. attention_inbox — sin cambios (ver header, punto 3): la versión vigente
--    de R.7.G ya surfacea rule_attention_items OPEN del caller, que es el sink
--    que usan settlement handshake/appeal y host_confirm. No se inventa trabajo.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Smoke R.9.E
-- ─────────────────────────────────────────────────────────────────────────────

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
  v_ctx := (public.create_context('R9E Hardening', 'collective', 'friend_group'))->>'context_actor_id';
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

revoke all on function public._smoke_mvp2_r9_e_hardening() from public, anon, authenticated;

comment on function public._smoke_mvp2_r9_e_hardening() is
  'Smoke R.9.E: (1) el rule engine multa a miembros activos pero salta a removidos
(snapshot de membresía, skip_reason=subject_not_active_member); (2) remove_member
bloquea con member_has_open_obligations cuando hay obligaciones money abiertas,
procede con p_force => true (activity con forced + open_obligations_count) y
normal cuando no hay deudas.';
