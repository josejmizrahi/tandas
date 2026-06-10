-- ============================================================================
-- R.9.C — EVENT WEIGHTED SPLIT (backend = autoridad)
-- ============================================================================
-- Hoy el split ponderado de un gasto atado a un evento (peso por actor =
-- 1 + plus_count + count_share de sus invitados vivos) se calcula en iOS
-- (RecordExpenseView / EventScope) — viola la doctrina "backend = autoridad".
-- Esta migración mueve el cómputo al backend:
--
--   1. _event_split_weights(event)        → helper interno: peso por participant
--   2. preview_event_split(event, monto)  → RPC read-only para la UI (mismo
--                                            redondeo determinista que el write)
--   3. record_expense(... p_source_event_id, p_split_basis)
--                                          → nueva base 'event_weights' que
--                                            computa los splits server-side
--   4. Gate de governance para gasto grande (expense.large) — PULL, opt-in
--      explícito por contexto (ver comentario en §4 dentro del cuerpo)
--
-- Semántica de pesos (réplica exacta de iOS EventScope, R.5Z.fix.EVENT.SPLIT):
--   peso(actor) = 1
--               + coalesce(event_participants.metadata->>'plus_count', 0)
--               + sum(event_guests.count_share) de los guests vivos
--                 (removed_at is null) invitados POR ese actor.
--   Solo cuentan participants confirmados: status in ('going','attended','late')
--   — equivalente backend de "going / checked-in" del cliente ('attended' y
--   'late' son los estados reales post check-in; invited/maybe/declined/
--   cancelled/no_show quedan fuera). Guests invitados por un actor que NO
--   cuenta se descartan automáticamente (el founder dropea el evento → su
--   esposa también sale).
--
-- Redondeo determinista (idéntico en preview y record):
--   monto(actor) = round(total * peso / total_peso, 2); el remanente de
--   centavos se asigna al actor de MAYOR peso (tiebreak: menor actor_id)
--   para que la suma == total exacto.
--
-- Smoke: _smoke_mvp2_r9_c_event_weighted_split()
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- §1 — Helper interno: pesos por participant de un evento
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._event_split_weights(p_event_id uuid)
returns table(actor_id uuid, weight int)
language sql stable security definer set search_path = public
as $$
  select ep.participant_actor_id as actor_id,
         (1
          + coalesce((ep.metadata->>'plus_count')::int, 0)
          + coalesce((
              select sum(g.count_share)
                from public.event_guests g
               where g.event_id = ep.event_id
                 and g.invited_by_actor_id = ep.participant_actor_id
                 and g.removed_at is null
            ), 0)
         )::int as weight
    from public.event_participants ep
   where ep.event_id = p_event_id
     and ep.status in ('going', 'attended', 'late');
$$;

-- Interno: sin grant a clientes (lo consumen preview_event_split / record_expense,
-- ambos SECURITY DEFINER del mismo owner).
revoke all on function public._event_split_weights(uuid) from public, anon, authenticated;

comment on function public._event_split_weights(uuid) is
  'R.9.C — peso por participant confirmado (going/attended/late) de un evento: 1 + plus_count (metadata) + sum(count_share) de event_guests vivos invitados por él. Interno, sin grant a clientes.';

-- ────────────────────────────────────────────────────────────────────────────
-- §2 — preview_event_split: la UI consulta el split SIN escribir nada
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.preview_event_split(
  p_event_id uuid,
  p_amount numeric,
  p_currency text default 'MXN'
)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ctx uuid;
  v_total_weight int;
  v_remainder numeric;
  v_splits jsonb := '[]'::jsonb;
  v_rec record;
  v_amt numeric;
  v_first boolean := true;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive' using errcode = '22023';
  end if;

  select context_actor_id into v_ctx from public.calendar_events where id = p_event_id;
  if v_ctx is null then
    raise exception 'event not found' using errcode = 'P0002';
  end if;
  -- CONVENCION: is_context_member(context) evalúa al caller actual
  if not public.is_context_member(v_ctx) then
    raise exception 'not authorized to preview splits in context %', v_ctx using errcode = '42501';
  end if;

  select sum(w.weight)::int into v_total_weight
    from public._event_split_weights(p_event_id) w;
  if coalesce(v_total_weight, 0) = 0 then
    raise exception 'event has no participants that count for the split' using errcode = '22023';
  end if;

  -- Remanente de redondeo: total - sum(round(parte, 2)). Puede ser negativo.
  select round(p_amount - coalesce(sum(round(p_amount * w.weight / v_total_weight, 2)), 0), 2)
    into v_remainder
    from public._event_split_weights(p_event_id) w;

  -- Orden determinista: mayor peso primero, tiebreak menor actor_id.
  -- El PRIMER actor de ese orden absorbe el remanente → suma == total exacto.
  for v_rec in
    select w.actor_id, w.weight
      from public._event_split_weights(p_event_id) w
     order by w.weight desc, w.actor_id asc
  loop
    v_amt := round(p_amount * v_rec.weight / v_total_weight, 2);
    if v_first then
      v_amt := v_amt + v_remainder;
      v_first := false;
    end if;
    v_splits := v_splits || jsonb_build_object(
      'actor_id', v_rec.actor_id,
      'weight', v_rec.weight,
      'amount', v_amt);
  end loop;

  return jsonb_build_object(
    'event_id', p_event_id,
    'amount', p_amount,
    'currency', p_currency,
    'total_weight', v_total_weight,
    'splits', v_splits);
end; $$;

revoke all on function public.preview_event_split(uuid, numeric, text) from public, anon;
grant execute on function public.preview_event_split(uuid, numeric, text) to authenticated, service_role;

comment on function public.preview_event_split(uuid, numeric, text) is
  'R.9.C — preview read-only del split ponderado de un evento: {event_id, amount, currency, total_weight, splits:[{actor_id, weight, amount}]}. Mismo redondeo determinista que record_expense(split_basis=event_weights): el actor de mayor peso (tiebreak menor actor_id) absorbe el remanente de centavos.';

-- ────────────────────────────────────────────────────────────────────────────
-- §3 + §4 — record_expense: nueva firma con p_source_event_id + p_split_basis
-- ────────────────────────────────────────────────────────────────────────────
-- Patrón repo para overloads legacy (r2t): DROP de la firma 12-arg de R.2S.6
-- para que PostgREST resuelva siempre la nueva 14-arg (los 2 params nuevos son
-- trailing con default → todos los callers existentes siguen resolviendo).
drop function if exists public.record_expense(
  uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[]
);

create or replace function public.record_expense(
  p_context_actor_id uuid,
  p_amount numeric,
  p_currency text,
  p_description text,
  p_split_with uuid[] default null,
  p_event_id uuid default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null,
  p_paid_by_actor_id uuid default null,
  p_split_method text default 'equal',
  p_splits jsonb default null,
  p_excluded_actor_ids uuid[] default null,
  p_source_event_id uuid default null,
  p_split_basis text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_payer uuid;
  v_txn uuid;
  v_existing uuid;
  v_participants uuid[];
  v_share numeric;
  v_p uuid;
  v_split record;
  v_splits_sum numeric;
  v_obligations jsonb := '[]'::jsonb;
  v_ob uuid;
  v_split_count integer;
  -- R.2S.6
  v_method text := p_split_method;          -- método efectivo (equal|custom)
  v_norm jsonb := '[]'::jsonb;
  v_total numeric;
  v_running numeric := 0;
  v_cnt integer;
  v_idx integer := 0;
  v_amt numeric;
  v_rec record;
  -- R.9.C
  v_preview jsonb;
  v_weights_meta jsonb;
  v_event_effective uuid;
  v_gov_pol jsonb;
  v_gov_threshold numeric;
  v_gov_ga uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  v_payer := coalesce(p_paid_by_actor_id, v_caller);

  -- ═══ Autorización ═══
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'money.record') then
    raise exception 'not authorized to record money in context %', p_context_actor_id using errcode = '42501';
  end if;
  if v_payer <> v_caller
     and not public.has_actor_authority(p_context_actor_id, v_caller, 'money.record_for_others') then
    raise exception 'recording expenses paid by others requires money.record_for_others' using errcode = '42501';
  end if;

  -- ═══ Validaciones duras (R.2H.7) ═══
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive' using errcode = '22023';
  end if;
  if p_currency is null or btrim(p_currency) = '' then
    raise exception 'currency is required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.actors where id = v_payer) then
    raise exception 'payer actor does not exist' using errcode = '22023';
  end if;
  if p_split_method not in ('equal', 'custom', 'custom_amount', 'percentage', 'shares', 'consumption') then
    raise exception 'unknown split_model %', p_split_method using errcode = '22023';
  end if;
  -- R.9.C: split_basis es una capa ortogonal a split_model
  if p_split_basis is not null
     and p_split_basis not in ('equal', 'explicit', 'event_weights') then
    raise exception 'unknown split_basis %', p_split_basis using errcode = '22023';
  end if;

  if p_event_id is not null and not exists (
    select 1 from public.calendar_events
    where id = p_event_id and context_actor_id = p_context_actor_id) then
    raise exception 'event does not belong to context' using errcode = '22023';
  end if;

  -- ═══ Idempotencia por client_id ═══
  if p_client_id is not null then
    select id into v_existing from public.money_transactions
     where created_by_actor_id = v_caller and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('transaction_id', v_existing, 'idempotent_replay', true,
        'obligations', coalesce((
          select jsonb_agg(jsonb_build_object('obligation_id', o.id, 'debtor', o.debtor_actor_id, 'amount', o.amount))
          from public.obligations o
          where (o.metadata->>'transaction_id')::uuid = v_existing), '[]'::jsonb));
    end if;
  end if;

  -- ═══ R.9.C §4 — Gate de governance para gasto grande (PULL, opt-in explícito) ═══
  -- Catálogo: action_key 'expense.large' (alias legacy 'large_expense'),
  -- policy_key 'large_expense_requires_vote', default_requires_decision = TRUE.
  -- ELECCIÓN R.9.C: como el default del catálogo es TRUE, si aplicáramos el
  -- patrón completo r7_x_2 (pol = 'true' OR (pol IS NULL AND catalog_default))
  -- TODO record_expense >= umbral en contextos SIN policy explícita empezaría a
  -- exigir decision aprobada → regresión sobre los smokes existentes
  -- (_smoke_r2s_split_models registra 1000 MXN, etc.) y sobre el flujo del
  -- founder. Por eso gateamos SOLO cuando el contexto habilitó la policy
  -- explícitamente (governance_policies.large_expense_requires_vote = 'true').
  -- Sin policy → comportamiento actual intacto.
  -- Umbral: governance_action_catalog['expense.large'].metadata->>'threshold'
  -- si existe; hoy el seed R.7.A no trae threshold → default documentado 5000.
  -- (Va después del replay de idempotencia: un replay no re-gatea un gasto ya
  -- registrado.)
  v_gov_pol := public.governance_policy(p_context_actor_id, 'large_expense_requires_vote');
  if v_gov_pol = 'true'::jsonb then
    select coalesce((gac.metadata->>'threshold')::numeric, 5000)
      into v_gov_threshold
      from public.governance_action_catalog gac
     where gac.action_key = 'expense.large';
    v_gov_threshold := coalesce(v_gov_threshold, 5000);
    if p_amount >= v_gov_threshold then
      v_gov_ga := public._governance_action_approved(p_context_actor_id, 'expense.large', null);
      if v_gov_ga is null then
        raise exception 'governance_required: expense.large (amount >= %) requires an approved decision in this context', v_gov_threshold
          using errcode = '42501',
          hint = 'call request_governance_action(context, ''expense.large'', null, null, jsonb_build_object(''amount'', amount)) and get it approved first';
      end if;
    end if;
  end if;

  -- ═══ R.9.C §3 — routing por split_basis ═══
  -- null / 'equal'  → flujo R.2S.6 intacto (cero regresión)
  -- 'explicit'      → mecanismo explícito actual: p_splits [{actor_id, amount}]
  -- 'event_weights' → splits server-side desde _event_split_weights
  if p_split_basis = 'event_weights' then
    if p_source_event_id is null then
      raise exception 'split_basis event_weights requires p_source_event_id' using errcode = '22023';
    end if;
    if not exists (
      select 1 from public.calendar_events
      where id = p_source_event_id and context_actor_id = p_context_actor_id) then
      raise exception 'source event does not belong to context' using errcode = '22023';
    end if;
    -- Mismo cómputo + redondeo que el preview (paridad garantizada por
    -- construcción: es la misma función).
    v_preview := public.preview_event_split(p_source_event_id, p_amount, p_currency);
    v_weights_meta := v_preview->'splits';
    select jsonb_agg(jsonb_build_object(
             'actor_id', s->>'actor_id',
             'amount', (s->>'amount')::numeric))
      into p_splits
      from jsonb_array_elements(v_weights_meta) s;
    v_method := 'custom';   -- reusa la rama custom: splits exactos + obligations
  elsif p_split_basis = 'explicit' then
    v_method := 'custom';   -- preserva el mecanismo explícito vigente (p_splits)
  else
    -- ═══ R.2S.6: normalización de split models a montos (verbatim) ═══
    -- custom_amount / consumption: ya vienen montos explícitos → tratar como custom
    if p_split_method in ('custom', 'custom_amount', 'consumption') then
      v_method := 'custom';
    elsif p_split_method in ('percentage', 'shares') then
      if p_splits is null or jsonb_array_length(p_splits) = 0 then
        raise exception 'split_model % requires splits array', p_split_method using errcode = '22023';
      end if;

      if p_split_method = 'percentage' then
        select coalesce(sum((s->>'percent')::numeric), 0) into v_total
          from jsonb_array_elements(p_splits) s;
        if v_total is null or abs(v_total - 100) > 0.01 then
          raise exception 'percentages must sum to 100 (got %)', v_total using errcode = '22023';
        end if;
      else  -- shares
        select coalesce(sum((s->>'shares')::numeric), 0) into v_total
          from jsonb_array_elements(p_splits) s;
        if v_total is null or v_total <= 0 then
          raise exception 'shares must sum to a positive total' using errcode = '22023';
        end if;
      end if;

      select count(*) into v_cnt from jsonb_array_elements(p_splits) s;
      for v_rec in
        select (s->>'actor_id') as actor_id,
               case when p_split_method = 'percentage' then (s->>'percent')::numeric
                    else (s->>'shares')::numeric end as weight
          from jsonb_array_elements(p_splits) s
      loop
        v_idx := v_idx + 1;
        if v_idx = v_cnt then
          v_amt := round(p_amount - v_running, 2);  -- el último absorbe el remanente
        else
          v_amt := round(p_amount * v_rec.weight / (case when p_split_method = 'percentage' then 100 else v_total end), 2);
          v_running := v_running + v_amt;
        end if;
        v_norm := v_norm || jsonb_build_object('actor_id', v_rec.actor_id, 'amount', v_amt);
      end loop;

      p_splits := v_norm;   -- la rama custom revalida sum=amount exacto
      v_method := 'custom';
    end if;
  end if;

  -- ═══ Participantes y montos según método efectivo ═══
  if v_method = 'equal' then
    if p_split_with is not null then
      if coalesce(array_length(p_split_with, 1), 0) = 0 then
        raise exception 'participant list cannot be empty' using errcode = '22023';
      end if;
      v_participants := p_split_with;
    else
      select array_agg(member_actor_id) into v_participants
        from public.actor_memberships
       where context_actor_id = p_context_actor_id and membership_status = 'active';
    end if;
    if not v_payer = any(v_participants) then
      v_participants := v_participants || v_payer;
    end if;
    if p_excluded_actor_ids is not null then
      if p_split_with is not null and p_split_with && p_excluded_actor_ids then
        raise exception 'excluded actors cannot also be participants' using errcode = '22023';
      end if;
      v_participants := (select array_agg(x) from unnest(v_participants) x
                         where not x = any(p_excluded_actor_ids));
    end if;
    if (select count(*) from unnest(v_participants) x)
       <> (select count(distinct x) from unnest(v_participants) x) then
      raise exception 'duplicate participant in split' using errcode = '22023';
    end if;
    foreach v_p in array v_participants loop
      if not exists (select 1 from public.actor_memberships
                     where context_actor_id = p_context_actor_id
                       and member_actor_id = v_p and membership_status = 'active') then
        raise exception 'split participant % is not an active member of the context', v_p using errcode = '22023';
      end if;
    end loop;

    v_share := round(p_amount / array_length(v_participants, 1), 2);
    v_split_count := array_length(v_participants, 1);

  else  -- custom (incl. custom_amount/percentage/shares/consumption/event_weights normalizados)
    if p_splits is null or jsonb_array_length(p_splits) = 0 then
      raise exception 'custom split requires splits array' using errcode = '22023';
    end if;
    select sum((s->>'amount')::numeric) into v_splits_sum from jsonb_array_elements(p_splits) s;
    if abs(coalesce(v_splits_sum, 0) - p_amount) > 0.01 then
      raise exception 'splits must sum to amount (% vs %)', v_splits_sum, p_amount using errcode = '22023';
    end if;
    if (select count(*) from jsonb_array_elements(p_splits) s)
       <> (select count(distinct s->>'actor_id') from jsonb_array_elements(p_splits) s) then
      raise exception 'duplicate participant in split' using errcode = '22023';
    end if;
    if p_excluded_actor_ids is not null and exists (
      select 1 from jsonb_array_elements(p_splits) s
      where (s->>'actor_id')::uuid = any(p_excluded_actor_ids)) then
      raise exception 'excluded actors cannot also be participants' using errcode = '22023';
    end if;
    for v_split in select (s->>'actor_id')::uuid as actor_id from jsonb_array_elements(p_splits) s loop
      if not exists (select 1 from public.actor_memberships
                     where context_actor_id = p_context_actor_id
                       and member_actor_id = v_split.actor_id and membership_status = 'active') then
        raise exception 'split participant % is not an active member of the context', v_split.actor_id using errcode = '22023';
      end if;
    end loop;
    v_split_count := jsonb_array_length(p_splits);
  end if;

  -- ═══ Transaction ═══
  -- R.9.C: money_transactions ya tiene event_id (FK a calendar_events) — es la
  -- columna "source event". Con event_weights el gasto queda atado al evento
  -- aunque el caller no haya pasado p_event_id.
  v_event_effective := coalesce(
    p_event_id,
    case when p_split_basis = 'event_weights' then p_source_event_id end);

  insert into public.money_transactions
    (context_actor_id, from_actor_id, transaction_type, amount, currency,
     event_id, metadata, client_id, created_by_actor_id)
  values
    (p_context_actor_id, v_payer, 'expense', p_amount, p_currency,
     v_event_effective,
     coalesce(p_metadata, '{}'::jsonb)
       || jsonb_build_object('description', p_description, 'split_method', p_split_method)
       || case when p_split_basis is not null
            then jsonb_build_object('split_basis', p_split_basis)
            else '{}'::jsonb end
       || case when p_split_basis = 'event_weights'
            then jsonb_build_object(
                   'source_event_id', p_source_event_id,
                   'event_split_weights', v_weights_meta)
            else '{}'::jsonb end,
     p_client_id, v_caller)
  returning id into v_txn;

  -- Marca la governance action consumida (mismo patrón que set_membership_state)
  if v_gov_ga is not null then
    update public.governance_actions
       set status = 'executed', executed_by_actor_id = v_caller, executed_at = now()
     where id = v_gov_ga;
  end if;

  -- ═══ Splits + obligations ═══
  insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
  values (v_txn, v_payer, 'payer', p_amount, p_currency);

  if p_excluded_actor_ids is not null then
    foreach v_p in array p_excluded_actor_ids loop
      insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
      values (v_txn, v_p, 'excluded', 0, p_currency);
    end loop;
  end if;

  if v_method = 'equal' then
    foreach v_p in array v_participants loop
      if v_p = v_payer then
        insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
        values (v_txn, v_p, 'beneficiary', v_share, p_currency);
      else
        insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
        values (v_txn, v_p, 'debtor', v_share, p_currency);

        insert into public.obligations
          (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type,
           amount, currency, source_event_id, metadata)
        values
          (p_context_actor_id, v_p, v_payer, 'expense_share', v_share, p_currency, v_event_effective,
           jsonb_build_object('transaction_id', v_txn, 'description', p_description))
        returning id into v_ob;
        v_obligations := v_obligations || jsonb_build_object('obligation_id', v_ob, 'debtor', v_p, 'amount', v_share);

        perform public._emit_activity(p_context_actor_id, v_p, 'obligation.created', 'obligation', v_ob,
          jsonb_build_object('transaction_id', v_txn, 'amount', v_share, 'obligation_type', 'expense_share'),
          p_obligation_id := v_ob);
      end if;
    end loop;
  else
    for v_split in
      select (s->>'actor_id')::uuid as actor_id, (s->>'amount')::numeric as amount
        from jsonb_array_elements(p_splits) s
    loop
      -- el payer no genera obligación contra sí mismo
      if v_split.actor_id = v_payer then
        insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
        values (v_txn, v_split.actor_id, 'beneficiary', v_split.amount, p_currency);
      else
        insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
        values (v_txn, v_split.actor_id, 'debtor', v_split.amount, p_currency);

        insert into public.obligations
          (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type,
           amount, currency, source_event_id, metadata)
        values
          (p_context_actor_id, v_split.actor_id, v_payer, 'expense_share', v_split.amount, p_currency, v_event_effective,
           jsonb_build_object('transaction_id', v_txn, 'description', p_description))
        returning id into v_ob;
        v_obligations := v_obligations || jsonb_build_object('obligation_id', v_ob, 'debtor', v_split.actor_id, 'amount', v_split.amount);

        perform public._emit_activity(p_context_actor_id, v_split.actor_id, 'obligation.created', 'obligation', v_ob,
          jsonb_build_object('transaction_id', v_txn, 'amount', v_split.amount, 'obligation_type', 'expense_share'),
          p_obligation_id := v_ob);
      end if;
    end loop;
  end if;

  -- ═══ Activity ═══
  perform public._emit_activity(p_context_actor_id, v_caller, 'expense.recorded', 'money_transaction', v_txn,
    jsonb_build_object('amount', p_amount, 'currency', p_currency, 'description', p_description,
                       'paid_by', v_payer, 'split_method', p_split_method));
  perform public._emit_activity(p_context_actor_id, v_caller, 'split.generated', 'money_transaction', v_txn,
    jsonb_build_object('split_method', p_split_method, 'participants', v_split_count,
                       'obligations_created', jsonb_array_length(v_obligations)));

  -- ═══ R.2S.5: la misma infraestructura de reglas aplica al dominio money ═══
  perform public.evaluate_rules_for_event(
    p_context_actor_id, 'money.expense_recorded', v_caller,
    jsonb_build_object('amount', p_amount, 'currency', p_currency,
                       'transaction_id', v_txn, 'description', p_description), null);

  return jsonb_build_object('transaction_id', v_txn,
    'share_per_person', v_share,
    'split_method', p_split_method,
    'obligations', v_obligations);
end; $$;

-- Re-aplicar grants tras DROP+CREATE (firma nueva 14-arg)
revoke all on function public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[], uuid, text) from public, anon;
grant execute on function public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[], uuid, text) to authenticated, service_role;

comment on function public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[], uuid, text) is
  'R.9.C sobre R.2S.6: gasto con split_model equal|custom|custom_amount|percentage|shares|consumption + excluded, más split_basis equal|explicit|event_weights. event_weights computa los splits server-side desde _event_split_weights (1 + plus_count + guest shares) con redondeo determinista idéntico a preview_event_split. Gate opt-in expense.large vía governance_policies.';

-- ────────────────────────────────────────────────────────────────────────────
-- §5 — Smoke: _smoke_mvp2_r9_c_event_weighted_split
-- ────────────────────────────────────────────────────────────────────────────
-- Mundo: contexto con 4 miembros (A paga, B plus_count=2, C invita guest
-- count_share=1, D simple) + evento con todos confirmados.
-- Pesos esperados: A=1, B=3, C=2, D=1 → total 7. Con 900 MXN:
--   round(900*1/7,2)=128.57 · round(900*3/7,2)=385.71 · round(900*2/7,2)=257.14
--   suma=899.99 → remanente 0.01 al de MAYOR peso (B) → B=385.72, total=900.00
create or replace function public._smoke_mvp2_r9_c_event_weighted_split()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid(); a_a uuid;
  u_b uuid := gen_random_uuid(); a_b uuid;
  u_c uuid := gen_random_uuid(); a_c uuid;
  u_d uuid := gen_random_uuid(); a_d uuid;
  v_ctx uuid;
  v_code text;
  v_event uuid;
  v_prev jsonb;
  v_res jsonb;
  v_txn uuid;
  v_sum numeric;
  v_amt numeric;
  v_cnt integer;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, '_smoke_r9c A', '+520000000980', null);
  a_b := public._create_person_actor_for_auth_user(u_b, '_smoke_r9c B', '+520000000981', null);
  a_c := public._create_person_actor_for_auth_user(u_c, '_smoke_r9c C', '+520000000982', null);
  a_d := public._create_person_actor_for_auth_user(u_d, '_smoke_r9c D', '+520000000983', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r9c Asado', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_d::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- A crea el evento (auto-invita a todos los miembros como 'invited' —
  -- p_invite_all_members default true NO marca al creador 'going', r5v3a) y
  -- confirma explícitamente para contar en el split. [2026-06-10 replay doctor:
  -- el smoke asumía A='going' automático → total_weight daba 6, no 7.]
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_event := ((public.create_calendar_event(
    v_ctx, '_smoke_r9c Carne asada', 'dinner', now() + interval '1 day'))->>'event_id')::uuid;
  perform public.rsvp_event(v_event, 'going');

  -- B confirma +2; C confirma e invita guest (count_share=1); D confirma simple
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.rsvp_event(v_event, 'going');
  perform public.set_event_participant_plus_count(v_event, a_b, 2);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  perform public.rsvp_event(v_event, 'going');
  perform public.add_event_guest(v_event, '_smoke_r9c Invitada de C', 1);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_d::text)::text, true);
  perform public.rsvp_event(v_event, 'going');

  -- ═══ 1. preview_event_split(900): pesos A=1 B=3 C=2 D=1, total 7 ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_prev := public.preview_event_split(v_event, 900, 'MXN');
  if (v_prev->>'total_weight')::int <> 7 then
    raise exception 'r9_c FAIL 1: total_weight % <> 7', v_prev->>'total_weight';
  end if;
  select sum((s->>'amount')::numeric) into v_sum from jsonb_array_elements(v_prev->'splits') s;
  if v_sum <> 900.00 then
    raise exception 'r9_c FAIL 1: preview no suma 900.00 exacto (got %)', v_sum;
  end if;
  select (s->>'amount')::numeric into v_amt
    from jsonb_array_elements(v_prev->'splits') s where (s->>'actor_id')::uuid = a_b;
  if v_amt is distinct from 385.72 then
    raise exception 'r9_c FAIL 1: B esperaba 385.72 (round(900*3/7,2)=385.71 + remanente 0.01), got %', v_amt;
  end if;
  select (s->>'amount')::numeric into v_amt
    from jsonb_array_elements(v_prev->'splits') s where (s->>'actor_id')::uuid = a_c;
  if v_amt is distinct from 257.14 then
    raise exception 'r9_c FAIL 1: C esperaba 257.14, got %', v_amt;
  end if;
  select (s->>'amount')::numeric into v_amt
    from jsonb_array_elements(v_prev->'splits') s where (s->>'actor_id')::uuid = a_a;
  if v_amt is distinct from 128.57 then
    raise exception 'r9_c FAIL 1: A esperaba 128.57, got %', v_amt;
  end if;
  select (s->>'amount')::numeric into v_amt
    from jsonb_array_elements(v_prev->'splits') s where (s->>'actor_id')::uuid = a_d;
  if v_amt is distinct from 128.57 then
    raise exception 'r9_c FAIL 1: D esperaba 128.57, got %', v_amt;
  end if;

  -- ═══ 2. record_expense split_basis=event_weights: splits == preview ═══
  v_res := public.record_expense(
    v_ctx, 900, 'MXN', '_smoke_r9c Carne',
    p_source_event_id := v_event,
    p_split_basis := 'event_weights');
  v_txn := (v_res->>'transaction_id')::uuid;

  if (select amount from public.money_splits
       where transaction_id = v_txn and actor_id = a_b and split_role = 'debtor')
     is distinct from 385.72 then
    raise exception 'r9_c FAIL 2: split debtor B <> 385.72';
  end if;
  if (select amount from public.money_splits
       where transaction_id = v_txn and actor_id = a_c and split_role = 'debtor')
     is distinct from 257.14 then
    raise exception 'r9_c FAIL 2: split debtor C <> 257.14';
  end if;
  if (select amount from public.money_splits
       where transaction_id = v_txn and actor_id = a_d and split_role = 'debtor')
     is distinct from 128.57 then
    raise exception 'r9_c FAIL 2: split debtor D <> 128.57';
  end if;
  if (select amount from public.money_splits
       where transaction_id = v_txn and actor_id = a_a and split_role = 'beneficiary')
     is distinct from 128.57 then
    raise exception 'r9_c FAIL 2: split beneficiary A (payer) <> 128.57';
  end if;
  select sum(amount) into v_sum from public.money_splits
   where transaction_id = v_txn and split_role in ('debtor', 'beneficiary');
  if v_sum <> 900.00 then
    raise exception 'r9_c FAIL 2: splits no suman 900.00 exacto (got %)', v_sum;
  end if;

  -- obligations B/C/D → A con los montos del preview
  select count(*) into v_cnt from public.obligations
   where (metadata->>'transaction_id')::uuid = v_txn
     and creditor_actor_id = a_a and obligation_type = 'expense_share';
  if v_cnt <> 3 then
    raise exception 'r9_c FAIL 2: esperaba 3 obligations hacia A, got %', v_cnt;
  end if;
  if (select amount from public.obligations
       where (metadata->>'transaction_id')::uuid = v_txn and debtor_actor_id = a_b)
     is distinct from 385.72 then
    raise exception 'r9_c FAIL 2: obligation B <> 385.72';
  end if;
  if (select amount from public.obligations
       where (metadata->>'transaction_id')::uuid = v_txn and debtor_actor_id = a_c)
     is distinct from 257.14 then
    raise exception 'r9_c FAIL 2: obligation C <> 257.14';
  end if;
  if (select amount from public.obligations
       where (metadata->>'transaction_id')::uuid = v_txn and debtor_actor_id = a_d)
     is distinct from 128.57 then
    raise exception 'r9_c FAIL 2: obligation D <> 128.57';
  end if;

  -- metadata + vínculo al evento
  if (select metadata->>'split_basis' from public.money_transactions where id = v_txn)
     is distinct from 'event_weights' then
    raise exception 'r9_c FAIL 2: metadata.split_basis <> event_weights';
  end if;
  if (select (metadata->>'source_event_id')::uuid from public.money_transactions where id = v_txn)
     is distinct from v_event then
    raise exception 'r9_c FAIL 2: metadata.source_event_id <> event';
  end if;
  if (select metadata->'event_split_weights' from public.money_transactions where id = v_txn) is null then
    raise exception 'r9_c FAIL 2: metadata.event_split_weights ausente';
  end if;
  if (select event_id from public.money_transactions where id = v_txn)
     is distinct from v_event then
    raise exception 'r9_c FAIL 2: money_transactions.event_id no quedó atado al evento';
  end if;

  -- ═══ 3. llamada legacy (sin params nuevos) sigue repartiendo equal ═══
  v_res := public.record_expense(v_ctx, 400, 'MXN', '_smoke_r9c Pizza legacy');
  v_txn := (v_res->>'transaction_id')::uuid;
  if (v_res->>'share_per_person')::numeric is distinct from 100 then
    raise exception 'r9_c FAIL 3: legacy equal share_per_person <> 100 (got %)', v_res->>'share_per_person';
  end if;
  select count(*) into v_cnt from public.money_splits
   where transaction_id = v_txn and split_role = 'debtor';
  if v_cnt <> 3 then
    raise exception 'r9_c FAIL 3: legacy equal esperaba 3 debtors, got %', v_cnt;
  end if;
  if exists (select 1 from public.money_splits
              where transaction_id = v_txn and split_role = 'debtor' and amount <> 100) then
    raise exception 'r9_c FAIL 3: legacy equal con montos <> 100';
  end if;
  if (select metadata ? 'split_basis' from public.money_transactions where id = v_txn) then
    raise exception 'r9_c FAIL 3: llamada legacy no debe persistir split_basis';
  end if;

  -- ═══ 4. split_basis inválido → 22023 ═══
  begin
    perform public.record_expense(v_ctx, 100, 'MXN', '_smoke_r9c bad',
      p_split_basis := 'bogus');
    raise exception 'r9_c FAIL 4: split_basis inválido no fue rechazado';
  exception when sqlstate '22023' then null;
  end;

  -- Cleanup (calendar_events cascade → event_guests antes de borrar actors)
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_a, a_b, a_c, a_d], array[u_a, u_b, u_c, u_d]);

  raise notice 'R.9.C EVENT WEIGHTED SPLIT: PASS (preview 7 pesos suma 900 exacto con remanente en B, record event_weights == preview + obligations, legacy equal intacto, split_basis inválido rechazado)';
end; $$;

revoke all on function public._smoke_mvp2_r9_c_event_weighted_split() from public, anon, authenticated;

comment on function public._smoke_mvp2_r9_c_event_weighted_split() is
  'Smoke R.9.C: split ponderado por evento (plus_count + guests) calculado en backend — preview + record + legacy + validación.';
