-- ============================================================================
-- R.9.B — MONEY: IDEMPOTENCIA (record_fine / record_game_result) + EXECUTE LOCKS
-- ============================================================================
-- Scope A — Idempotencia por p_client_id (patrón D9 de record_expense):
--   · record_fine: + p_client_id text default null. Ahora ancla una
--     money_transaction (transaction_type='other', metadata.kind='fine') con
--     client_id + created_by_actor_id, protegida por el unique index parcial
--     idx_txn_client_id (created_by_actor_id, client_id) WHERE client_id IS NOT NULL
--     (mvp2_009). Replay → mismo shape que record_expense:
--     {transaction_id, idempotent_replay: true, obligation_id}.
--   · record_game_result (variante jsonb multi-actor de mvp2_009 — la variante
--     winner/loser de R.2H YA tiene p_client_id + idempotencia y no se toca):
--     + p_client_id text default null. Ahora ancla UNA money_transaction
--     'game_result' por juego ANTES de crear splits/obligations; el replay
--     regresa temprano sin duplicar nada:
--     {transaction_id, idempotent_replay: true, obligations: [...]}.
--   · Como agregar un parámetro con default crea un OVERLOAD (ambigüedad
--     PostgREST), se aplica el patrón del repo (r2t / r4b drop legacy overload):
--     DROP de la firma vieja + CREATE de la nueva. Los callers viejos siguen
--     funcionando porque el parámetro nuevo tiene default.
--   · Consecuencia: el smoke _smoke_r2h_money_expenses_dod (última versión en
--     r5pre) verifica has_function_privilege contra la firma vieja LITERAL de
--     record_fine — con la firma vieja dropeada eso lanzaría "function does not
--     exist". Se re-crea el smoke (cuerpo idéntico a r5pre) con la firma nueva
--     en la lista de anon-block (mismo patrón que
--     r2q1_update_r2g_smoke_create_decision_signature).
--
-- Scope B — Locks de concurrencia en los caminos de ejecución:
--   · execute_decision (última definición: r4b 20260604120003) y
--     execute_governance_action (última definición: r7_c 20260608225000) YA
--     leen su fila con SELECT ... FOR UPDATE ANTES del check de idempotencia
--     por status ('executed'). R.9.B re-afirma ambos cuerpos VERBATIM como
--     definición canónica con lock — dos llamadas concurrentes se serializan y
--     la segunda ve status='executed' / regresa already_executed.
--     CREATE OR REPLACE: firmas intactas, grants preservados.
--
-- Smoke: _smoke_mvp2_r9_b_money_idempotency (CI corre todos los _smoke_mvp2_%).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. record_fine: drop firma vieja + recreate con p_client_id (idempotencia D9)
-- ────────────────────────────────────────────────────────────────────────────
drop function if exists public.record_fine(uuid, uuid, numeric, text, text);

create or replace function public.record_fine(
  p_context_actor_id uuid,
  p_debtor_actor_id uuid,
  p_amount numeric,
  p_currency text,
  p_reason text default null,
  p_client_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_txn uuid;
  v_existing uuid;
  v_ob uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'money.record') then
    raise exception 'not authorized to record money' using errcode = '42501';
  end if;
  if p_debtor_actor_id <> v_caller
     and not public.has_actor_authority(p_context_actor_id, v_caller, 'members.manage') then
    raise exception 'fining others requires members.manage' using errcode = '42501';
  end if;
  -- R.9.B: la transaction ancla exige amount > 0 y currency (CHECKs de
  -- money_transactions); validación limpia estilo record_expense.
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive' using errcode = '22023';
  end if;
  if p_currency is null or btrim(p_currency) = '' then
    raise exception 'currency is required' using errcode = '22023';
  end if;

  -- ═══ Idempotencia por client_id (patrón D9 de record_expense) ═══
  if p_client_id is not null then
    select id into v_existing from public.money_transactions
     where created_by_actor_id = v_caller and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('transaction_id', v_existing, 'idempotent_replay', true,
        'obligation_id', (select o.id from public.obligations o
                          where (o.metadata->>'transaction_id')::uuid = v_existing limit 1));
    end if;
  end if;

  -- ═══ Transaction ancla de la multa (idempotency key vive aquí) ═══
  insert into public.money_transactions
    (context_actor_id, from_actor_id, to_actor_id, transaction_type, amount, currency,
     metadata, client_id, created_by_actor_id)
  values
    (p_context_actor_id, p_debtor_actor_id, p_context_actor_id, 'other', p_amount, p_currency,
     jsonb_build_object('kind', 'fine', 'reason', p_reason, 'issued_by', v_caller),
     p_client_id, v_caller)
  returning id into v_txn;

  -- splits: deudor debtor, contexto creditor
  insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
  values (v_txn, p_debtor_actor_id, 'debtor', p_amount, p_currency),
         (v_txn, p_context_actor_id, 'creditor', p_amount, p_currency);

  insert into public.obligations
    (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type, amount, currency, metadata)
  values
    (p_context_actor_id, p_debtor_actor_id, p_context_actor_id, 'fine', p_amount, p_currency,
     jsonb_build_object('reason', p_reason, 'issued_by', v_caller, 'transaction_id', v_txn))
  returning id into v_ob;

  update public.money_transactions set obligation_id = v_ob where id = v_txn;

  perform public._emit_activity(p_context_actor_id, v_caller, 'money.fine_recorded', 'obligation', v_ob,
    jsonb_build_object('debtor', p_debtor_actor_id, 'amount', p_amount, 'reason', p_reason),
    p_obligation_id := v_ob);

  return jsonb_build_object('obligation_id', v_ob, 'transaction_id', v_txn);
end; $$;

revoke all on function public.record_fine(uuid, uuid, numeric, text, text, text) from public, anon;
grant execute on function public.record_fine(uuid, uuid, numeric, text, text, text) to authenticated, service_role;

comment on function public.record_fine(uuid, uuid, numeric, text, text, text) is
  'R.9.B: multa manual con idempotencia por p_client_id (ancla money_transaction tipo other, patrón D9 de record_expense).';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. record_game_result (variante jsonb): drop firma vieja + recreate con
--    p_client_id. UNA transaction game_result ancla TODO el juego — el replay
--    regresa temprano antes de crear splits/obligations (cero duplicados).
--    (La variante winner/loser de R.2H ya era idempotente; intacta.)
-- ────────────────────────────────────────────────────────────────────────────
drop function if exists public.record_game_result(uuid, jsonb, uuid, text);

create or replace function public.record_game_result(
  p_context_actor_id uuid,
  p_results jsonb,
  p_event_id uuid default null,
  p_currency text default 'MXN',
  p_client_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_total_won numeric := 0;
  v_total_lost numeric := 0;
  v_loser record;
  v_winner record;
  v_split record;
  v_txn uuid;
  v_existing uuid;
  v_ob uuid;
  v_obligations jsonb := '[]'::jsonb;
  v_share numeric;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'money.record') then
    raise exception 'not authorized to record money' using errcode = '42501';
  end if;

  select coalesce(sum((r->>'amount')::numeric) filter (where (r->>'amount')::numeric > 0), 0),
         coalesce(abs(sum((r->>'amount')::numeric) filter (where (r->>'amount')::numeric < 0)), 0)
    into v_total_won, v_total_lost
    from jsonb_array_elements(p_results) r;

  if v_total_won = 0 or v_total_lost = 0 then
    raise exception 'game results must have winners and losers' using errcode = '22023';
  end if;

  -- ═══ Idempotencia por client_id (patrón D9 de record_expense): si la
  -- transaction ancla ya existe, regresar temprano SIN crear splits ni
  -- obligations — el juego completo no se duplica. ═══
  if p_client_id is not null then
    select id into v_existing from public.money_transactions
     where created_by_actor_id = v_caller and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('transaction_id', v_existing, 'idempotent_replay', true,
        'obligations', coalesce((
          select jsonb_agg(jsonb_build_object('obligation_id', o.id, 'debtor', o.debtor_actor_id,
                                              'creditor', o.creditor_actor_id, 'amount', o.amount))
          from public.obligations o
          where (o.metadata->>'transaction_id')::uuid = v_existing), '[]'::jsonb));
    end if;
  end if;

  -- ═══ Transaction game_result: UNA por juego (idempotency key vive aquí) ═══
  insert into public.money_transactions
    (context_actor_id, transaction_type, amount, currency, event_id,
     metadata, client_id, created_by_actor_id)
  values
    (p_context_actor_id, 'game_result', v_total_lost, p_currency, p_event_id,
     jsonb_build_object('results', p_results, 'recorded_by', v_caller),
     p_client_id, v_caller)
  returning id into v_txn;

  -- splits: perdedores debtor / ganadores creditor
  for v_split in
    select (r->>'actor_id')::uuid as actor_id, (r->>'amount')::numeric as amount
      from jsonb_array_elements(p_results) r
     where (r->>'amount')::numeric <> 0
  loop
    insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
    values (v_txn, v_split.actor_id,
            case when v_split.amount < 0 then 'debtor' else 'creditor' end,
            abs(v_split.amount), p_currency);
  end loop;

  -- cada perdedor le debe a cada ganador proporcionalmente
  for v_loser in
    select (r->>'actor_id')::uuid as actor_id, abs((r->>'amount')::numeric) as lost
      from jsonb_array_elements(p_results) r where (r->>'amount')::numeric < 0
  loop
    for v_winner in
      select (r->>'actor_id')::uuid as actor_id, (r->>'amount')::numeric as won
        from jsonb_array_elements(p_results) r where (r->>'amount')::numeric > 0
    loop
      v_share := round(v_loser.lost * (v_winner.won / v_total_won), 2);
      if v_share > 0 then
        insert into public.obligations
          (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type,
           amount, currency, source_event_id, metadata)
        values
          (p_context_actor_id, v_loser.actor_id, v_winner.actor_id, 'game_debt',
           v_share, p_currency, p_event_id,
           jsonb_build_object('recorded_by', v_caller, 'transaction_id', v_txn))
        returning id into v_ob;
        v_obligations := v_obligations || jsonb_build_object(
          'obligation_id', v_ob, 'debtor', v_loser.actor_id, 'creditor', v_winner.actor_id, 'amount', v_share);
      end if;
    end loop;
  end loop;

  perform public._emit_activity(p_context_actor_id, v_caller, 'money.game_result_recorded', 'calendar_event', p_event_id,
    jsonb_build_object('results', p_results, 'obligations_created', jsonb_array_length(v_obligations)));

  return jsonb_build_object('transaction_id', v_txn, 'obligations', v_obligations);
end; $$;

revoke all on function public.record_game_result(uuid, jsonb, uuid, text, text) from public, anon;
grant execute on function public.record_game_result(uuid, jsonb, uuid, text, text) to authenticated, service_role;

comment on function public.record_game_result(uuid, jsonb, uuid, text, text) is
  'R.9.B: resultados multi-actor [{actor_id, amount}] con idempotencia por p_client_id — una transaction game_result ancla el juego completo; el replay no duplica splits/obligations.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. execute_decision — lock de concurrencia (Scope B)
-- ────────────────────────────────────────────────────────────────────────────
-- Cuerpo VERBATIM de la última definición (r4b 20260604120003). El SELECT
-- inicial ya hace FOR UPDATE ANTES del check status='executed': dos llamadas
-- concurrentes se serializan y la segunda ve 'executed' → already_executed.
-- R.9.B lo re-afirma como definición canónica con lock (firma intacta).
create or replace function public.execute_decision(p_decision_id uuid, p_result jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_template public.decision_templates_catalog%rowtype;
  v_winner_option text;
  v_winner_option_id uuid;
  v_opt public.decision_options%rowtype;
  v_action text;
  v_winner_res uuid;
  v_loser_res uuid;
  v_conflict_id uuid;
  v_conflict public.reservation_conflicts%rowtype;
  v_effects jsonb := '[]'::jsonb;
  v_resource_id uuid;
  v_rule_id uuid;
  v_holder uuid;
  v_right_kind text;
  v_right_id uuid;
  v_archived_count int;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  -- R.9.B: FOR UPDATE antes del idempotency check — serializa ejecuciones concurrentes.
  select * into v_d from public.decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.execute') then
    raise exception 'not authorized to execute decisions' using errcode = '42501';
  end if;

  if v_d.status = 'executed' then
    return jsonb_build_object('decision_id', p_decision_id, 'status', 'executed', 'already_executed', true);
  end if;
  if v_d.status <> 'approved' then
    raise exception 'only approved decisions can be executed (status: %)', v_d.status using errcode = '22023';
  end if;

  if v_d.template_key is not null then
    select * into v_template from public.decision_templates_catalog
     where template_key = v_d.template_key;

    if v_template.execution_kind = 'noop' then
      v_effects := jsonb_build_array(jsonb_build_object('type', 'noop'));

    elsif v_template.execution_kind = 'archive_resource' then
      v_resource_id := (v_d.payload->>'resource_id')::uuid;
      if v_resource_id is null then
        raise exception 'archive_resource template needs payload.resource_id' using errcode = '22023';
      end if;
      update public.resources
         set archived_at = now()
       where id = v_resource_id and archived_at is null;
      get diagnostics v_archived_count = row_count;
      v_effects := jsonb_build_array(jsonb_build_object(
        'type', 'resource_archived', 'resource_id', v_resource_id,
        'already_archived', v_archived_count = 0));
      perform public._emit_activity(v_d.context_actor_id, v_caller, 'resource.archived',
        'resource', v_resource_id,
        jsonb_build_object('by_decision', p_decision_id),
        p_resource_id := v_resource_id, p_decision_id := p_decision_id);

    elsif v_template.execution_kind = 'archive_rule' then
      v_rule_id := (v_d.payload->>'rule_id')::uuid;
      if v_rule_id is null then
        raise exception 'archive_rule template needs payload.rule_id' using errcode = '22023';
      end if;
      update public.rules
         set status = 'archived', archived_at = now()
       where id = v_rule_id and status <> 'archived';
      v_effects := jsonb_build_array(jsonb_build_object(
        'type', 'rule_archived', 'rule_id', v_rule_id));
      perform public._emit_activity(v_d.context_actor_id, v_caller, 'rule.archived',
        'rule', v_rule_id,
        jsonb_build_object('by_decision', p_decision_id),
        p_decision_id := p_decision_id);

    elsif v_template.execution_kind = 'grant_resource_right' then
      v_resource_id := (v_d.payload->>'resource_id')::uuid;
      v_holder      := (v_d.payload->>'holder_actor_id')::uuid;
      v_right_kind  := v_d.payload->>'right_kind';
      if v_resource_id is null or v_holder is null or v_right_kind is null then
        raise exception 'grant_resource_right template needs payload.resource_id, holder_actor_id, right_kind'
          using errcode = '22023';
      end if;
      -- Partial unique index requires ON CONFLICT (cols) WHERE, not ON CONSTRAINT.
      insert into public.resource_rights
        (resource_id, holder_actor_id, right_kind, scope, percent,
         granted_by_actor_id, source_decision_id, starts_at, metadata)
      values
        (v_resource_id, v_holder, v_right_kind,
         v_d.payload->>'scope',
         nullif(v_d.payload->>'percent','')::numeric,
         v_caller, p_decision_id, now(),
         jsonb_build_object('granted_by_decision', p_decision_id))
      on conflict (resource_id, holder_actor_id, right_kind, coalesce(scope, ''))
        where (revoked_at is null and expired_at is null)
        do nothing
      returning id into v_right_id;

      v_effects := jsonb_build_array(jsonb_build_object(
        'type', 'right_granted',
        'resource_id', v_resource_id,
        'holder_actor_id', v_holder,
        'right_kind', v_right_kind,
        'right_id', v_right_id));
      perform public._emit_activity(v_d.context_actor_id, v_caller, 'resource.right_granted',
        'resource_right', v_right_id,
        jsonb_build_object('by_decision', p_decision_id, 'right_kind', v_right_kind),
        p_resource_id := v_resource_id, p_decision_id := p_decision_id);

    elsif v_template.execution_kind = 'reservation_award' then
      null;

    else
      raise exception 'decision template % (execution_kind %) not yet implemented',
        v_d.template_key, v_template.execution_kind
        using errcode = '0A000';
    end if;
  end if;

  v_winner_option := v_d.result->>'winning_option';
  v_winner_option_id := (v_d.result->>'winning_option_id')::uuid;

  if v_winner_option_id is null and v_winner_option is not null then
    select id into v_winner_option_id from public.decision_options
     where decision_id = p_decision_id and option_key = v_winner_option;
  end if;

  if v_effects = '[]'::jsonb and v_winner_option_id is not null then
    select * into v_opt from public.decision_options where id = v_winner_option_id;
    v_action := v_opt.payload->>'action';

    if v_action = 'reservation_award' then
      v_winner_res := (v_opt.payload->>'winner_reservation_id')::uuid;
      v_conflict_id := (v_opt.payload->>'conflict_id')::uuid;
      if v_conflict_id is not null then
        select * into v_conflict from public.reservation_conflicts where id = v_conflict_id for update;
      end if;
      if v_conflict.id is not null and v_conflict.resolution_status = 'open' then
        v_loser_res := case when v_winner_res = v_conflict.reservation_a_id
                            then v_conflict.reservation_b_id else v_conflict.reservation_a_id end;
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

    elsif v_action = 'split_reservation' then
      v_conflict_id := (v_opt.payload->>'conflict_id')::uuid;
      if v_conflict_id is not null then
        select * into v_conflict from public.reservation_conflicts where id = v_conflict_id for update;
      end if;
      if v_conflict.id is not null and v_conflict.resolution_status = 'open' then
        update public.resource_reservations
           set status = 'approved', source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('split_by_decision', p_decision_id)
         where id in (v_conflict.reservation_a_id, v_conflict.reservation_b_id)
           and status = 'requested';
        update public.reservation_conflicts
           set resolution_status = 'resolved', resolved_at = now(), source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('resolved_by_decision', p_decision_id, 'resolution', 'split')
         where id = v_conflict.id;
        v_effects := jsonb_build_array(
          jsonb_build_object('type', 'conflict_resolved', 'conflict_id', v_conflict.id, 'resolution', 'split'));
      end if;

    elsif v_action = 'cancel_reservations' then
      v_conflict_id := (v_opt.payload->>'conflict_id')::uuid;
      if v_conflict_id is not null then
        select * into v_conflict from public.reservation_conflicts where id = v_conflict_id for update;
      end if;
      if v_conflict.id is not null and v_conflict.resolution_status = 'open' then
        update public.resource_reservations
           set status = 'cancelled', source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('cancelled_by_decision', p_decision_id)
         where id in (v_conflict.reservation_a_id, v_conflict.reservation_b_id)
           and status in ('requested', 'approved');
        update public.reservation_conflicts
           set resolution_status = 'resolved', resolved_at = now(), source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('resolved_by_decision', p_decision_id, 'resolution', 'cancelled')
         where id = v_conflict.id;
        v_effects := jsonb_build_array(
          jsonb_build_object('type', 'conflict_resolved', 'conflict_id', v_conflict.id, 'resolution', 'cancelled'));
      end if;
    end if;
  end if;

  if v_effects = '[]'::jsonb
     and v_d.decision_type = 'reservation_dispute'
     and v_d.payload ? 'reservation_conflict_id'
     and v_winner_option is not null
     and v_d.payload ? 'option_reservations'
     and v_d.payload->'option_reservations' ? v_winner_option then
    select * into v_conflict from public.reservation_conflicts
     where id = (v_d.payload->>'reservation_conflict_id')::uuid for update;
    if v_conflict.id is not null and v_conflict.resolution_status = 'open' then
      v_winner_res := (v_d.payload->'option_reservations'->>v_winner_option)::uuid;
      v_loser_res := case when v_winner_res = v_conflict.reservation_a_id
                          then v_conflict.reservation_b_id else v_conflict.reservation_a_id end;
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
             metadata = metadata || jsonb_build_object('resolved_by_decision', p_decision_id, 'winner_reservation_id', v_winner_res)
       where id = v_conflict.id;
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
    jsonb_build_object('effects', v_effects, 'template_key', v_d.template_key), p_decision_id := p_decision_id);

  return jsonb_build_object('decision_id', p_decision_id, 'status', 'executed', 'effects', v_effects);
end;
$function$;

revoke all on function public.execute_decision(uuid, jsonb) from anon;
grant execute on function public.execute_decision(uuid, jsonb) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. execute_governance_action — lock de concurrencia (Scope B)
-- ────────────────────────────────────────────────────────────────────────────
-- Cuerpo VERBATIM de la última definición (r7_c 20260608225000). El SELECT
-- inicial ya hace FOR UPDATE ANTES del check status='executed'. R.9.B lo
-- re-afirma como definición canónica con lock (firma intacta, grants preservados).
create or replace function public.execute_governance_action(
  p_governance_action_id uuid
) returns jsonb
language plpgsql security definer set search_path to public, auth as $$
declare
  v_row public.governance_actions%rowtype;
  v_catalog public.governance_action_catalog%rowtype;
  v_canonical_key text;
  v_result jsonb;
  v_caller uuid := public.current_actor_id();
  v_err text;
begin
  -- R.9.B: FOR UPDATE antes del idempotency check — serializa ejecuciones concurrentes.
  select * into v_row from public.governance_actions where id = p_governance_action_id for update;
  if v_row.id is null then
    return jsonb_build_object('governance_action_id', p_governance_action_id, 'status','not_found');
  end if;

  -- Idempotency: status='executed' → noop
  if v_row.status = 'executed' then
    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status','executed', 'noop', true, 'idempotent_replay', true
    );
  end if;

  -- Solo aprobados son ejecutables (not_required no entra PUSH path)
  if v_row.status <> 'approved' then
    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status', v_row.status, 'noop', true,
      'reason', 'status_not_approved'
    );
  end if;

  v_canonical_key := public._governance_action_resolve(v_row.action_key);
  select * into v_catalog from public.governance_action_catalog where action_key = v_canonical_key;

  if v_catalog.action_key is null then
    update public.governance_actions
       set status='failed',
           error_message=format('action_key %s not in catalog', v_canonical_key)
     where id = p_governance_action_id;
    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status','failed','reason','catalog_missing'
    );
  end if;

  if not v_catalog.push_supported then
    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status', v_row.status, 'noop', true,
      'reason', 'pull_only', 'push_supported', false
    );
  end if;

  if v_catalog.execution_rpc is null then
    update public.governance_actions
       set status='failed',
           error_message='catalog.execution_rpc is null'
     where id = p_governance_action_id;
    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status','failed','reason','execution_rpc_missing'
    );
  end if;

  -- Dispatch con error handling (NO re-raise: returns jsonb status para que trigger no rollback close_decision)
  begin
    v_result := public._governance_action_dispatch(v_row, v_catalog);

    update public.governance_actions
       set status='executed',
           executed_at = now(),
           executed_by_actor_id = v_caller,
           result = v_result
     where id = p_governance_action_id;

    perform public._emit_activity(
      v_row.context_actor_id, v_caller, 'governance.executed',
      'governance_action', p_governance_action_id,
      jsonb_build_object('action_key', v_canonical_key, 'result', v_result),
      p_decision_id := v_row.decision_id
    );

    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status','executed',
      'result', v_result
    );

  exception when others then
    v_err := SQLERRM;
    update public.governance_actions
       set status='failed',
           error_message = v_err
     where id = p_governance_action_id;

    perform public._emit_activity(
      v_row.context_actor_id, v_caller, 'governance.failed',
      'governance_action', p_governance_action_id,
      jsonb_build_object('action_key', v_canonical_key, 'error', v_err),
      p_decision_id := v_row.decision_id
    );

    return jsonb_build_object(
      'governance_action_id', p_governance_action_id,
      'status','failed',
      'error', v_err
    );
  end;
end;
$$;

grant execute on function public.execute_governance_action(uuid) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Re-crear _smoke_r2h_money_expenses_dod con la firma nueva de record_fine
--    en la lista de anon-block (cuerpo idéntico a la última versión, r5pre;
--    has_function_privilege contra la firma vieja dropeada lanzaría 42883).
-- ────────────────────────────────────────────────────────────────────────────
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
  perform public.remove_member(v_ctx::uuid, a_daniel, 'prueba R2H');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_caught := false;
  begin perform public.record_expense(v_ctx::uuid, 100, 'MXN', 'hack removido');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2H.6 FAIL: miembro removido registró gasto'; end if;

  -- (4) anon bloqueado (R.9.B: firma nueva de record_fine con p_client_id)
  foreach v_fn in array array[
    'public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[])',
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

revoke all on function public._smoke_r2h_money_expenses_dod() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Smoke R.9.B — idempotencia de record_fine / record_game_result
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_r9_b_money_idempotency()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid();
  u_b uuid := gen_random_uuid();
  a_a uuid; a_b uuid;
  v_ctx uuid; v_code text;
  v_r1 jsonb; v_r2 jsonb;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R9B Admin', '+520000000910', null);
  a_b := public._create_person_actor_for_auth_user(u_b, 'R9B Member', '+520000000911', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r9b Money', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);

  -- ═══ Caso 1: record_fine con el mismo p_client_id dos veces ═══
  v_r1 := public.record_fine(v_ctx, a_b, 150, 'MXN', 'r9b multa', 'r9b-fine-001');
  if (v_r1->>'transaction_id') is null or (v_r1->>'obligation_id') is null then
    raise exception 'r9_b fine: primer call no devolvió transaction_id + obligation_id';
  end if;
  if coalesce((v_r1->>'idempotent_replay')::boolean, false) then
    raise exception 'r9_b fine: primer call marcado como replay';
  end if;
  v_r2 := public.record_fine(v_ctx, a_b, 150, 'MXN', 'r9b multa', 'r9b-fine-001');
  if not coalesce((v_r2->>'idempotent_replay')::boolean, false) then
    raise exception 'r9_b fine: segundo call no fue idempotent_replay';
  end if;
  if (v_r2->>'transaction_id')::uuid <> (v_r1->>'transaction_id')::uuid
     or (v_r2->>'obligation_id')::uuid <> (v_r1->>'obligation_id')::uuid then
    raise exception 'r9_b fine: replay devolvió ids distintos';
  end if;
  if (select count(*) from public.money_transactions
      where context_actor_id = v_ctx and client_id = 'r9b-fine-001') <> 1 then
    raise exception 'r9_b fine: money_transaction duplicada';
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx and obligation_type = 'fine' and amount = 150) <> 1 then
    raise exception 'r9_b fine: obligation duplicada';
  end if;

  -- ═══ Caso 2: record_game_result (variante jsonb) con el mismo p_client_id ═══
  v_r1 := public.record_game_result(v_ctx,
    jsonb_build_array(
      jsonb_build_object('actor_id', a_a, 'amount', 200),
      jsonb_build_object('actor_id', a_b, 'amount', -200)),
    null, 'MXN', 'r9b-game-001');
  if (v_r1->>'transaction_id') is null or jsonb_array_length(v_r1->'obligations') <> 1 then
    raise exception 'r9_b game: primer call incorrecto (sin transaction_id o sin obligation)';
  end if;
  v_r2 := public.record_game_result(v_ctx,
    jsonb_build_array(
      jsonb_build_object('actor_id', a_a, 'amount', 200),
      jsonb_build_object('actor_id', a_b, 'amount', -200)),
    null, 'MXN', 'r9b-game-001');
  if not coalesce((v_r2->>'idempotent_replay')::boolean, false) then
    raise exception 'r9_b game: segundo call no fue idempotent_replay';
  end if;
  if (v_r2->>'transaction_id')::uuid <> (v_r1->>'transaction_id')::uuid then
    raise exception 'r9_b game: replay devolvió otra transaction';
  end if;
  if jsonb_array_length(v_r2->'obligations') <> 1 then
    raise exception 'r9_b game: replay no reconstruyó las obligations';
  end if;
  if (select count(*) from public.money_transactions
      where context_actor_id = v_ctx and transaction_type = 'game_result' and amount = 200) <> 1 then
    raise exception 'r9_b game: money_transaction duplicada';
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx and obligation_type = 'game_debt' and amount = 200) <> 1 then
    raise exception 'r9_b game: obligation game_debt duplicada';
  end if;
  if (select count(*) from public.money_splits
      where transaction_id = (v_r1->>'transaction_id')::uuid) <> 2 then
    raise exception 'r9_b game: splits duplicados o incompletos';
  end if;

  -- ═══ Caso 3: client_id NULL dos veces → dos filas (default intacto) ═══
  v_r1 := public.record_fine(v_ctx, a_b, 50, 'MXN', 'r9b multa nula');
  v_r2 := public.record_fine(v_ctx, a_b, 50, 'MXN', 'r9b multa nula');
  if coalesce((v_r2->>'idempotent_replay')::boolean, false) then
    raise exception 'r9_b fine null: client_id null no debe disparar idempotencia';
  end if;
  if (v_r1->>'obligation_id')::uuid = (v_r2->>'obligation_id')::uuid then
    raise exception 'r9_b fine null: dos calls sin client_id devolvieron la misma obligation';
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx and obligation_type = 'fine' and amount = 50) <> 2 then
    raise exception 'r9_b fine null: esperaba 2 multas con client_id null';
  end if;
  if (select count(*) from public.money_transactions
      where context_actor_id = v_ctx and transaction_type = 'other'
        and amount = 50 and client_id is null) <> 2 then
    raise exception 'r9_b fine null: esperaba 2 transactions con client_id null';
  end if;

  v_r1 := public.record_game_result(v_ctx,
    jsonb_build_array(
      jsonb_build_object('actor_id', a_a, 'amount', 80),
      jsonb_build_object('actor_id', a_b, 'amount', -80)));
  v_r2 := public.record_game_result(v_ctx,
    jsonb_build_array(
      jsonb_build_object('actor_id', a_a, 'amount', 80),
      jsonb_build_object('actor_id', a_b, 'amount', -80)));
  if coalesce((v_r2->>'idempotent_replay')::boolean, false) then
    raise exception 'r9_b game null: client_id null no debe disparar idempotencia';
  end if;
  if (v_r1->>'transaction_id')::uuid = (v_r2->>'transaction_id')::uuid then
    raise exception 'r9_b game null: dos calls sin client_id devolvieron la misma transaction';
  end if;
  if (select count(*) from public.money_transactions
      where context_actor_id = v_ctx and transaction_type = 'game_result' and amount = 80) <> 2 then
    raise exception 'r9_b game null: esperaba 2 transactions game_result';
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx and obligation_type = 'game_debt' and amount = 80) <> 2 then
    raise exception 'r9_b game null: esperaba 2 game_debt obligations';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_a, a_b], array[u_a, u_b]);

  raise notice '_smoke_mvp2_r9_b_money_idempotency passed (fine + game result, con y sin client_id)';
end; $$;

revoke all on function public._smoke_mvp2_r9_b_money_idempotency() from public, anon, authenticated;

comment on function public._smoke_mvp2_r9_b_money_idempotency() is
  'R.9.B: idempotencia por p_client_id en record_fine y record_game_result (variante jsonb) — replay no duplica transactions/splits/obligations; client_id null conserva el comportamiento previo.';
