-- ============================================================================
-- R.2H — MONEY / EXPENSES DoD: splits equal/custom + game result + caso exacto
-- ============================================================================
-- Caso: Cena Semanal Amigos con estado heredado de R.2D/R.2E (multas de Moisés
-- y Daniel ya existentes por reglas). David paga $1,300 (split equal entre 4,
-- Daniel excluido), José paga postre $500 (split custom), Moisés le gana $250
-- a Daniel en Catan. Todo convive sin contaminar contextos.
--
-- Gaps corregidos (solo RPCs + catálogo de permisos, cero schema):
--   1. permission_catalog: + money.record_for_others (admin lo recibe al crear
--      contexto porque _seed_context_roles lee el catálogo dinámicamente).
--   2. record_expense v2:
--      - p_paid_by_actor_id (pagar a nombre de otro = money.record_for_others)
--      - p_split_method 'equal'/'custom' + p_splits [{actor_id, amount}]
--      - p_excluded_actor_ids (rol 'excluded' con monto 0)
--      - roles de split correctos: payer / beneficiary (self) / debtor / excluded
--      - validaciones duras (currency, evento del contexto, duplicados,
--        no-miembros, suma de splits, lista vacía, excluded-como-debtor)
--      - activity: expense.recorded + split.generated + obligation.created
--   3. record_game_result (winner/loser): NUEVO overload con transaction
--      game_result, metadata.game_name, idempotencia por client_id y
--      validaciones (winner≠loser, miembros, evento del contexto).
--   4. Smoke R.2A actualizado (la firma de record_expense cambió).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Permiso money.record_for_others (data, no schema)
-- ────────────────────────────────────────────────────────────────────────────
insert into public.permission_catalog (permission_key, category, description)
values ('money.record_for_others', 'money', 'Registrar gastos a nombre de otro miembro')
on conflict (permission_key) do nothing;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. record_expense v2: paid_by + equal/custom + excluded + validaciones
-- ────────────────────────────────────────────────────────────────────────────
drop function if exists public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text);

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
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  v_payer := coalesce(p_paid_by_actor_id, v_caller);

  -- ═══ Autorización ═══
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'money.record') then
    raise exception 'not authorized to record money in context %', p_context_actor_id using errcode = '42501';
  end if;
  -- R.2H: registrar un gasto pagado por OTRO requiere money.record_for_others
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
    raise exception 'paid_by_actor_id is not a valid actor' using errcode = '22023';
  end if;
  if p_split_method not in ('equal', 'custom') then
    raise exception 'invalid split_method: %', p_split_method using errcode = '22023';
  end if;
  -- el evento debe pertenecer al contexto
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

  -- ═══ Participantes y montos según split_method ═══
  if p_split_method = 'equal' then
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
    -- el payer siempre participa
    if not v_payer = any(v_participants) then
      v_participants := v_participants || v_payer;
    end if;
    -- excluidos: no pueden estar también como participantes explícitos
    if p_excluded_actor_ids is not null then
      if p_split_with is not null and p_split_with && p_excluded_actor_ids then
        raise exception 'excluded actors cannot also be participants' using errcode = '22023';
      end if;
      v_participants := (select array_agg(x) from unnest(v_participants) x
                         where not x = any(p_excluded_actor_ids));
    end if;
    -- duplicados
    if (select count(*) from unnest(v_participants) x)
       <> (select count(distinct x) from unnest(v_participants) x) then
      raise exception 'duplicate participant in split' using errcode = '22023';
    end if;
    -- todos los participantes deben ser miembros activos del contexto
    -- (MVP: sin allow_external_participant)
    foreach v_p in array v_participants loop
      if not exists (select 1 from public.actor_memberships
                     where context_actor_id = p_context_actor_id
                       and member_actor_id = v_p and membership_status = 'active') then
        raise exception 'split participant % is not an active member of the context', v_p using errcode = '22023';
      end if;
    end loop;

    v_share := round(p_amount / array_length(v_participants, 1), 2);
    v_split_count := array_length(v_participants, 1);

  else  -- custom
    if p_splits is null or jsonb_array_length(p_splits) = 0 then
      raise exception 'custom split requires splits array' using errcode = '22023';
    end if;
    -- suma debe ser exactamente el monto
    select sum((s->>'amount')::numeric) into v_splits_sum from jsonb_array_elements(p_splits) s;
    if abs(coalesce(v_splits_sum, 0) - p_amount) > 0.01 then
      raise exception 'splits must sum to amount (% vs %)', v_splits_sum, p_amount using errcode = '22023';
    end if;
    -- duplicados
    if (select count(*) from jsonb_array_elements(p_splits) s)
       <> (select count(distinct s->>'actor_id') from jsonb_array_elements(p_splits) s) then
      raise exception 'duplicate participant in split' using errcode = '22023';
    end if;
    -- excluidos no pueden aparecer como participantes
    if p_excluded_actor_ids is not null and exists (
      select 1 from jsonb_array_elements(p_splits) s
      where (s->>'actor_id')::uuid = any(p_excluded_actor_ids)) then
      raise exception 'excluded actors cannot also be participants' using errcode = '22023';
    end if;
    -- todos miembros activos
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
  -- payer: monto completo
  insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
  values (v_txn, v_payer, 'payer', p_amount, p_currency);

  -- excluidos: rol explícito con monto 0
  if p_excluded_actor_ids is not null then
    foreach v_p in array p_excluded_actor_ids loop
      insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
      values (v_txn, v_p, 'excluded', 0, p_currency);
    end loop;
  end if;

  if p_split_method = 'equal' then
    foreach v_p in array v_participants loop
      if v_p = v_payer then
        -- la parte propia del payer
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

  return jsonb_build_object('transaction_id', v_txn,
    'share_per_person', v_share,
    'split_method', p_split_method,
    'obligations', v_obligations);
end; $$;

revoke all on function public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[]) from public, anon;
grant execute on function public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[]) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. record_game_result (winner/loser): NUEVO overload con transaction
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.record_game_result(
  p_context_actor_id uuid,
  p_event_id uuid,
  p_game_name text,
  p_winner_actor_id uuid,
  p_loser_actor_id uuid,
  p_amount numeric,
  p_currency text default 'MXN',
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
    raise exception 'not authorized to record money in context %', p_context_actor_id using errcode = '42501';
  end if;

  -- ═══ Validaciones duras (R.2H.7) ═══
  if p_winner_actor_id = p_loser_actor_id then
    raise exception 'winner and loser must be different actors' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive' using errcode = '22023';
  end if;
  if not exists (select 1 from public.actor_memberships
                 where context_actor_id = p_context_actor_id
                   and member_actor_id = p_winner_actor_id and membership_status = 'active') then
    raise exception 'winner is not an active member of the context' using errcode = '22023';
  end if;
  if not exists (select 1 from public.actor_memberships
                 where context_actor_id = p_context_actor_id
                   and member_actor_id = p_loser_actor_id and membership_status = 'active') then
    raise exception 'loser is not an active member of the context' using errcode = '22023';
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
        'obligation_id', (select o.id from public.obligations o
                          where (o.metadata->>'transaction_id')::uuid = v_existing limit 1));
    end if;
  end if;

  -- ═══ Transaction game_result ═══
  insert into public.money_transactions
    (context_actor_id, from_actor_id, to_actor_id, transaction_type, amount, currency,
     event_id, metadata, client_id, created_by_actor_id)
  values
    (p_context_actor_id, p_loser_actor_id, p_winner_actor_id, 'game_result', p_amount, p_currency,
     p_event_id, jsonb_build_object('game_name', p_game_name), p_client_id, v_caller)
  returning id into v_txn;

  -- splits: perdedor debtor, ganador creditor
  insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
  values (v_txn, p_loser_actor_id, 'debtor', p_amount, p_currency),
         (v_txn, p_winner_actor_id, 'creditor', p_amount, p_currency);

  -- ═══ Obligation game_debt ═══
  insert into public.obligations
    (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type,
     amount, currency, source_event_id, metadata)
  values
    (p_context_actor_id, p_loser_actor_id, p_winner_actor_id, 'game_debt', p_amount, p_currency,
     p_event_id, jsonb_build_object('game_name', p_game_name, 'transaction_id', v_txn, 'recorded_by', v_caller))
  returning id into v_ob;

  -- ═══ Activity ═══
  perform public._emit_activity(p_context_actor_id, v_caller, 'game_result.recorded', 'money_transaction', v_txn,
    jsonb_build_object('game_name', p_game_name, 'winner', p_winner_actor_id, 'loser', p_loser_actor_id,
                       'amount', p_amount, 'currency', p_currency));
  perform public._emit_activity(p_context_actor_id, p_loser_actor_id, 'obligation.created', 'obligation', v_ob,
    jsonb_build_object('transaction_id', v_txn, 'amount', p_amount, 'obligation_type', 'game_debt',
                       'game_name', p_game_name),
    p_obligation_id := v_ob);

  return jsonb_build_object('transaction_id', v_txn, 'obligation_id', v_ob);
end; $$;

revoke all on function public.record_game_result(uuid, uuid, text, uuid, uuid, numeric, text, text) from public, anon;
grant execute on function public.record_game_result(uuid, uuid, text, uuid, uuid, numeric, text, text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Smoke R.2A actualizado: la firma de record_expense cambió
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_r2a_authority_dod()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_admin uuid; a_admin uuid;
  u_member uuid; a_member uuid;
  u_outsider uuid; a_outsider uuid;
  v_ctx uuid;
  v_result jsonb;
  v_caught boolean;
  v_tbl text;
  v_fn text;
begin
  select auth_id, actor_id into u_admin, a_admin from public._r2_make_person('R2A Admin', '+5210000020');
  select auth_id, actor_id into u_member, a_member from public._r2_make_person('R2A Member', '+5210000021');
  select auth_id, actor_id into u_outsider, a_outsider from public._r2_make_person('R2A Outsider', '+5210000022');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  v_ctx := (public.create_context('R2A Authority Test', 'collective', 'friend_group'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_member);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_member::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);

  -- DoD 1: Un usuario puede ver sus contextos
  v_result := public.context_candidates();
  if not exists (
    select 1 from jsonb_array_elements(v_result->'contexts') c
    where (c->>'context_actor_id')::uuid = v_ctx::uuid
  ) then
    raise exception 'R2A DoD 1 FAIL: el usuario no ve su contexto en context_candidates';
  end if;
  if (v_result->'personal_context'->>'id')::uuid is distinct from a_member then
    raise exception 'R2A DoD 1 FAIL: personal_context incorrecto';
  end if;

  -- DoD 2: Un miembro activo puede ver un contexto
  v_result := public.context_summary(v_ctx::uuid);
  if (v_result->>'members_count')::integer <> 2 then
    raise exception 'R2A DoD 2 FAIL: miembro activo no puede ver context_summary';
  end if;
  if public.current_actor_id() is distinct from a_member then
    raise exception 'R2A DoD 2 FAIL: current_actor_id() incorrecto';
  end if;

  -- DoD 3: Un no-miembro NO puede verlo
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_outsider::text)::text, true);
  v_caught := false;
  begin
    v_result := public.context_summary(v_ctx::uuid);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2A DoD 3 FAIL: no-miembro pudo ver context_summary'; end if;
  v_result := public.context_candidates();
  if exists (
    select 1 from jsonb_array_elements(v_result->'contexts') c
    where (c->>'context_actor_id')::uuid = v_ctx::uuid
  ) then
    raise exception 'R2A DoD 3 FAIL: contexto ajeno aparece en candidates de no-miembro';
  end if;
  if public.has_actor_authority(v_ctx::uuid, a_outsider, 'context.view') then
    raise exception 'R2A DoD 3 FAIL: no-miembro tiene autoridad';
  end if;

  -- DoD 4: Un rol CON permiso permite acción
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  if not public.has_actor_authority(v_ctx::uuid, a_admin, 'rules.manage') then
    raise exception 'R2A DoD 4 FAIL: has_actor_authority niega permiso que el rol admin tiene';
  end if;
  v_result := public.create_rule(v_ctx::uuid, 'R2A regla de prueba',
    p_trigger_event_type := 'event.checked_in',
    p_consequences := '[{"type": "fine", "amount": 50, "currency": "MXN"}]'::jsonb);
  if (v_result->>'rule_id') is null then
    raise exception 'R2A DoD 4 FAIL: rol con permiso no pudo ejecutar la acción';
  end if;

  -- DoD 5: Un rol SIN permiso bloquea acción
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_member::text)::text, true);
  if public.has_actor_authority(v_ctx::uuid, a_member, 'rules.manage') then
    raise exception 'R2A DoD 5 FAIL: has_actor_authority concede permiso que el rol member no tiene';
  end if;
  v_caught := false;
  begin
    perform public.create_rule(v_ctx::uuid, 'R2A hack', p_trigger_event_type := 'x');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2A DoD 5 FAIL: rol sin permiso ejecutó la acción'; end if;
  if not public.has_actor_authority(v_ctx::uuid, a_member, 'events.view') then
    raise exception 'R2A DoD 5 FAIL: member perdió sus permisos básicos';
  end if;

  -- DoD 6: anon no puede leer tablas ni ejecutar RPCs sensibles
  for v_tbl in select tablename from pg_tables where schemaname = 'public' loop
    if has_table_privilege('anon', 'public.' || v_tbl, 'SELECT') then
      raise exception 'R2A DoD 6 FAIL: anon tiene SELECT en %', v_tbl;
    end if;
  end loop;
  -- R.2H: firma actualizada de record_expense
  foreach v_fn in array array[
    'public.has_actor_authority(uuid, uuid, text)',
    'public.current_actor_id()',
    'public.context_candidates()',
    'public.context_summary(uuid)',
    'public.create_context(text, text, text, text, jsonb)',
    'public.invite_member(uuid, uuid, text)',
    'public.accept_invitation(uuid)',
    'public.create_rule(uuid, text, text, jsonb, jsonb, text, text, int)',
    'public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[])',
    'public.generate_settlement_batch(uuid, text)'
  ] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'R2A DoD 6 FAIL: anon puede ejecutar %', v_fn;
    end if;
  end loop;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_admin, a_member, a_outsider],
    array[u_admin, u_member, u_outsider]);

  raise notice 'R.2A AUTHORITY LAYER DoD: 6/6 PASS';
end; $$;

revoke all on function public._smoke_mvp2_r2a_authority_dod() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Smoke R.2H — caso exacto del founder
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2h_money_expenses_dod()
returns void
language plpgsql security definer set search_path = public, auth
as $$
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
    p_starts_at := v_starts, p_ends_at := v_starts + interval '3 hours',
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
    p_starts_at := now() + interval '1 day'))->>'event_id';
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

  -- (4) anon bloqueado
  foreach v_fn in array array[
    'public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text, uuid, text, jsonb, uuid[])',
    'public.record_game_result(uuid, uuid, text, uuid, uuid, numeric, text, text)',
    'public.record_fine(uuid, uuid, numeric, text, text)',
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
end; $$;

revoke all on function public._smoke_r2h_money_expenses_dod() from public, anon, authenticated;

comment on function public._smoke_r2h_money_expenses_dod() is
  'R.2H DoD exacto: expense equal split ($1300/4, Daniel excluido) + custom split ($500) + game result (Catan $250) + coexistencia con multas (8 obligations) + idempotencia + permisos + validaciones duras.';

-- Wrapper para CI (descubre funciones _smoke_mvp2_%)
create or replace function public._smoke_mvp2_r2h_money_expenses_dod()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._smoke_r2h_money_expenses_dod();
end; $$;

revoke all on function public._smoke_mvp2_r2h_money_expenses_dod() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2h_money_expenses_dod() is
  'Wrapper CI del smoke R.2H (_smoke_r2h_money_expenses_dod).';
