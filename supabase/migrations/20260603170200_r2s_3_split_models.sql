-- ============================================================================
-- R.2S.6 — SPLIT MODELS
-- ============================================================================
-- No todo gasto es equal/custom. record_expense ahora acepta split_model:
--
--   equal          → en partes iguales entre participantes
--   custom         → montos explícitos por actor (legacy)
--   custom_amount   → alias explícito de custom (montos por actor)
--   percentage      → [{actor_id, percent}] suma 100
--   shares          → [{actor_id, shares}]  proporción por acciones
--   consumption     → montos explícitos documentados (diferible)
--   excluded        → vía p_excluded_actor_ids (ya existía)
--
-- percentage/shares se NORMALIZAN a montos antes de crear splits: el último
-- participante absorbe el remanente de redondeo para que la suma == amount
-- exacto (la rama custom revalida sum=amount, sin duplicados, miembros activos,
-- currency consistente, payer sin obligación contra sí mismo).
-- ============================================================================

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
  p_excluded_actor_ids uuid[] default null
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

  -- ═══ R.2S.6: normalización de split models a montos ═══
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

  else  -- custom (incl. custom_amount/percentage/shares/consumption normalizados)
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
  insert into public.money_transactions
    (context_actor_id, from_actor_id, transaction_type, amount, currency,
     event_id, metadata, client_id, created_by_actor_id)
  values
    (p_context_actor_id, v_payer, 'expense', p_amount, p_currency,
     p_event_id,
     coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
       'description', p_description, 'split_method', p_split_method),
     p_client_id, v_caller)
  returning id into v_txn;

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
          (p_context_actor_id, v_p, v_payer, 'expense_share', v_share, p_currency, p_event_id,
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
          (p_context_actor_id, v_split.actor_id, v_payer, 'expense_share', v_split.amount, p_currency, p_event_id,
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
  -- (las reglas con trigger 'money.expense_recorded' se evalúan; scope/filter
  --  se introducen en r2s_6_rule_targeting. Sin reglas money, es no-op.)
  perform public.evaluate_rules_for_event(
    p_context_actor_id, 'money.expense_recorded', v_caller,
    jsonb_build_object('amount', p_amount, 'currency', p_currency,
                       'transaction_id', v_txn, 'description', p_description), null);

  return jsonb_build_object('transaction_id', v_txn,
    'share_per_person', v_share,
    'split_method', p_split_method,
    'obligations', v_obligations);
end; $$;

revoke all on function public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[]) from public, anon;
grant execute on function public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[]) to authenticated, service_role;

comment on function public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[]) is
  'R.2S.6: gasto con split_model equal|custom|custom_amount|percentage|shares|consumption + excluded. percentage/shares se normalizan a montos exactos.';

-- ────────────────────────────────────────────────────────────────────────────
-- Smoke — _smoke_r2s_split_models
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2s_split_models()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  v_ctx uuid;
  v_res jsonb;
  v_txn uuid;
  v_sum numeric;
  v_david_amt numeric;
  v_isaac_amt numeric;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2S-split', '+5210000071');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2S-split', '+5210000072');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2S-split', '+5210000073');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Viaje R2S split', 'collective', 'trip'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform public.invite_member(v_ctx::uuid, a_isaac);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);

  -- José paga 1000, repartido por porcentaje: David 30%, Isaac 70% (José excluido del consumo)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  -- ═══ 1. percentage ═══
  v_res := public.record_expense(
    v_ctx::uuid, 1000, 'MXN', 'Hotel viaje',
    p_split_method := 'percentage',
    p_splits := jsonb_build_array(
      jsonb_build_object('actor_id', a_david, 'percent', 30),
      jsonb_build_object('actor_id', a_isaac, 'percent', 70)));
  v_txn := (v_res->>'transaction_id')::uuid;

  -- la suma de splits == amount exacto
  select sum(amount) into v_sum from public.money_splits
   where transaction_id = v_txn and split_role in ('debtor','beneficiary');
  if v_sum <> 1000 then
    raise exception 'R2S.6 FAIL 1: percentage no suma 1000 (got %)', v_sum;
  end if;
  select amount into v_david_amt from public.money_splits where transaction_id = v_txn and actor_id = a_david;
  select amount into v_isaac_amt from public.money_splits where transaction_id = v_txn and actor_id = a_isaac;
  if v_david_amt <> 300 or v_isaac_amt <> 700 then
    raise exception 'R2S.6 FAIL 1: percentage mal repartido (david=% isaac=%)', v_david_amt, v_isaac_amt;
  end if;

  -- ═══ 2. shares: David 1 acción, Isaac 3 acciones sobre 1000 → 250 / 750 ═══
  v_res := public.record_expense(
    v_ctx::uuid, 1000, 'MXN', 'Renta cabaña',
    p_split_method := 'shares',
    p_splits := jsonb_build_array(
      jsonb_build_object('actor_id', a_david, 'shares', 1),
      jsonb_build_object('actor_id', a_isaac, 'shares', 3)));
  v_txn := (v_res->>'transaction_id')::uuid;
  select sum(amount) into v_sum from public.money_splits
   where transaction_id = v_txn and split_role in ('debtor','beneficiary');
  if v_sum <> 1000 then
    raise exception 'R2S.6 FAIL 2: shares no suma 1000 (got %)', v_sum;
  end if;
  select amount into v_david_amt from public.money_splits where transaction_id = v_txn and actor_id = a_david;
  select amount into v_isaac_amt from public.money_splits where transaction_id = v_txn and actor_id = a_isaac;
  if v_david_amt <> 250 or v_isaac_amt <> 750 then
    raise exception 'R2S.6 FAIL 2: shares mal repartido (david=% isaac=%)', v_david_amt, v_isaac_amt;
  end if;

  -- ═══ 3. percentage con remanente de redondeo: 100 entre 3 al 33.33/33.33/33.34 ═══
  v_res := public.record_expense(
    v_ctx::uuid, 100, 'MXN', 'Gasolina',
    p_split_method := 'percentage',
    p_splits := jsonb_build_array(
      jsonb_build_object('actor_id', a_jose,  'percent', 33.33),
      jsonb_build_object('actor_id', a_david, 'percent', 33.33),
      jsonb_build_object('actor_id', a_isaac, 'percent', 33.34)));
  v_txn := (v_res->>'transaction_id')::uuid;
  select sum(amount) into v_sum from public.money_splits
   where transaction_id = v_txn and split_role in ('debtor','beneficiary');
  if v_sum <> 100 then
    raise exception 'R2S.6 FAIL 3: el remanente de redondeo no cierra en 100 (got %)', v_sum;
  end if;

  -- ═══ 4. percentage que no suma 100 → error ═══
  begin
    perform public.record_expense(
      v_ctx::uuid, 100, 'MXN', 'Mal split',
      p_split_method := 'percentage',
      p_splits := jsonb_build_array(
        jsonb_build_object('actor_id', a_david, 'percent', 40),
        jsonb_build_object('actor_id', a_isaac, 'percent', 40)));
    raise exception 'R2S.6 FAIL 4: percentage 80%% no fue rechazado';
  exception when sqlstate '22023' then null;
  end;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david, a_isaac], array[u_jose, u_david, u_isaac]);

  raise notice 'R.2S.6 SPLIT MODELS: PASS (percentage 30/70, shares 250/750, remanente de redondeo cierra, validación de suma)';
end; $$;

revoke all on function public._smoke_r2s_split_models() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2s_split_models()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_r2s_split_models(); end; $$;
revoke all on function public._smoke_mvp2_r2s_split_models() from public, anon, authenticated;
comment on function public._smoke_mvp2_r2s_split_models() is 'Wrapper CI del smoke R.2S.6 split models.';
