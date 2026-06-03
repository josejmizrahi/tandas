-- ============================================================================
-- R.2I — SETTLEMENT ENGINE DoD: neteo greedy + multimoneda + aislamiento + caso exacto
-- ============================================================================
-- Caso: las 8 obligations de R.2H (2 multas + 3 cena + 2 postre + 1 juego) se
-- netean en un batch MXN. Netos correctos: José +75, David +775, Isaac -525,
-- Moisés -175, Daniel -550, Grupo +400 → total a liquidar $1,250.
--
-- NOTA sobre el spec: el "Cálculo neto esperado" del spec dice José = -125 y
-- total = 1,175, pero omite que Isaac → José $200 (postre) — obligación que el
-- propio spec lista. El neto correcto de José es +75 y el total $1,250 (la
-- suma cierra en 0, como el spec exige). El smoke valida los netos correctos.
--
-- Gaps corregidos (solo RPCs, cero schema, firmas intactas):
--   1. generate_settlement_batch:
--      - IDEMPOTENCIA: si ya existe un batch draft para (contexto, moneda) se
--        devuelve ese mismo batch (no duplica batches ni items).
--      - VALIDACIONES: currency null, sin obligations abiertas → falla,
--        obligations con amount null → falla, debtor = creditor → falla.
--      - METADATA: total_debtors, total_creditors, settlement_semantics
--        (documenta que el settlement liquida netos y las obligations se
--        cierran al finalizar el batch completo — opción elegida de R.2I.4).
--      - ACTIVITY: settlement.generated + settlement.item_created por item.
--   2. mark_settlement_paid:
--      - item cancelado → falla. Activity: settlement.paid.
--      - (already_paid no-op + cierre por batch de R.2-3 se conservan)
--   3. Smoke R.2A: sweep DINÁMICO de anon sobre todas las funciones de la app
--      (sin firmas hardcodeadas — no vuelve a romperse con cambios de firma).
--
-- Nota de diseño: los parámetros client_id/paid_at del spec se omiten para no
-- cambiar las firmas (cambiarlas rompe en cascada los smokes que las
-- referencian). La idempotencia observable que el spec exige se garantiza por
-- reuso de batch draft y por el no-op de item ya pagado.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. generate_settlement_batch v3
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.generate_settlement_batch(
  p_context_actor_id uuid,
  p_currency text
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_batch uuid;
  v_existing public.settlement_batches%rowtype;
  v_items jsonb := '[]'::jsonb;
  v_amount numeric;
  v_obligation_ids uuid[];
  v_total_debtors integer;
  v_total_creditors integer;
  v_item_id uuid;
  v_net_debtors uuid[];  v_net_debtor_amounts numeric[];
  v_net_creditors uuid[]; v_net_creditor_amounts numeric[];
  i integer; j integer;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'money.settle') then
    raise exception 'not authorized to settle in context %', p_context_actor_id using errcode = '42501';
  end if;

  -- ═══ R.2I.8 validaciones duras ═══
  if p_currency is null or btrim(p_currency) = '' then
    raise exception 'currency is required' using errcode = '22023';
  end if;

  -- ═══ R.2I.2 idempotencia: reusar batch draft existente para (contexto, moneda) ═══
  select * into v_existing from public.settlement_batches
   where context_actor_id = p_context_actor_id and currency = p_currency and status = 'draft'
   order by created_at desc limit 1;
  if v_existing.id is not null then
    return jsonb_build_object(
      'batch_id', v_existing.id,
      'idempotent_replay', true,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object('from', si.from_actor_id, 'to', si.to_actor_id, 'amount', si.amount))
        from public.settlement_items si where si.settlement_batch_id = v_existing.id), '[]'::jsonb),
      'obligations_netted', jsonb_array_length(coalesce(v_existing.metadata->'obligation_ids', '[]'::jsonb)));
  end if;

  -- obligations abiertas del contexto en esa moneda
  select array_agg(id) into v_obligation_ids
    from public.obligations
   where context_actor_id = p_context_actor_id and status = 'open' and currency = p_currency;

  -- R.2I.8: sin obligations abiertas → falla (antes devolvía mensaje)
  if v_obligation_ids is null then
    raise exception 'no open obligations to settle for context % in %', p_context_actor_id, p_currency
      using errcode = '22023';
  end if;
  -- R.2I.8: obligations con amount null → falla
  if exists (select 1 from public.obligations where id = any(v_obligation_ids) and amount is null) then
    raise exception 'cannot settle: obligations with null amount exist' using errcode = '22023';
  end if;
  -- R.2I.8: obligations con debtor = creditor → falla
  if exists (select 1 from public.obligations where id = any(v_obligation_ids)
             and debtor_actor_id = creditor_actor_id) then
    raise exception 'cannot settle: obligations with debtor = creditor exist' using errcode = '22023';
  end if;

  drop table if exists _net;
  create temp table _net on commit drop as
  select actor_id, sum(net) as net from (
    select creditor_actor_id as actor_id, sum(amount) as net
      from public.obligations
     where id = any(v_obligation_ids)
     group by creditor_actor_id
    union all
    select debtor_actor_id, -sum(amount)
      from public.obligations
     where id = any(v_obligation_ids)
     group by debtor_actor_id
  ) x group by actor_id having abs(sum(net)) > 0.01;

  if not exists (select 1 from _net) then
    -- todo se cancela mutuamente: cerrar las obligations directamente
    update public.obligations set status = 'settled',
      metadata = metadata || '{"settled_reason": "mutual_netting_zero"}'::jsonb
     where id = any(v_obligation_ids);
    return jsonb_build_object('batch_id', null, 'items', '[]'::jsonb,
      'message', 'all obligations net to zero — settled directly',
      'obligations_settled', array_length(v_obligation_ids, 1));
  end if;

  select count(*) filter (where net < 0), count(*) filter (where net > 0)
    into v_total_debtors, v_total_creditors from _net;

  -- R.2I.4 (opción elegida): el settlement liquida NETOS; las obligations se
  -- cierran cuando el batch completo queda pagado, no por pagos individuales.
  insert into public.settlement_batches (context_actor_id, currency, created_by_actor_id, metadata)
  values (p_context_actor_id, p_currency, v_caller,
          jsonb_build_object(
            'obligation_ids', to_jsonb(v_obligation_ids),
            'total_debtors', v_total_debtors,
            'total_creditors', v_total_creditors,
            'settlement_semantics', 'net_batch_closure',
            'settlement_semantics_note',
              'Los items liquidan saldos netos, no obligations individuales. Las obligations neteadas se cierran atómicamente cuando todos los items del batch quedan pagados.'))
  returning id into v_batch;

  select array_agg(actor_id order by net), array_agg(-net order by net)
    into v_net_debtors, v_net_debtor_amounts
    from _net where net < 0;
  select array_agg(actor_id order by net desc), array_agg(net order by net desc)
    into v_net_creditors, v_net_creditor_amounts
    from _net where net > 0;

  i := 1; j := 1;
  while i <= coalesce(array_length(v_net_debtors, 1), 0)
    and j <= coalesce(array_length(v_net_creditors, 1), 0) loop
    v_amount := least(v_net_debtor_amounts[i], v_net_creditor_amounts[j]);
    if v_amount > 0.01 then
      insert into public.settlement_items
        (settlement_batch_id, from_actor_id, to_actor_id, amount, currency)
      values (v_batch, v_net_debtors[i], v_net_creditors[j], round(v_amount, 2), p_currency)
      returning id into v_item_id;
      v_items := v_items || jsonb_build_object(
        'item_id', v_item_id,
        'from', v_net_debtors[i], 'to', v_net_creditors[j], 'amount', round(v_amount, 2));

      -- R.2I activity: cada item de liquidación queda auditado
      perform public._emit_activity(p_context_actor_id, v_caller, 'settlement.item_created', 'settlement_item', v_item_id,
        jsonb_build_object('batch_id', v_batch, 'from', v_net_debtors[i], 'to', v_net_creditors[j],
                           'amount', round(v_amount, 2), 'currency', p_currency));
    end if;
    v_net_debtor_amounts[i] := v_net_debtor_amounts[i] - v_amount;
    v_net_creditor_amounts[j] := v_net_creditor_amounts[j] - v_amount;
    if v_net_debtor_amounts[i] <= 0.01 then i := i + 1; end if;
    if v_net_creditor_amounts[j] <= 0.01 then j := j + 1; end if;
  end loop;

  perform public._emit_activity(p_context_actor_id, v_caller, 'settlement.generated', 'settlement_batch', v_batch,
    jsonb_build_object('currency', p_currency, 'items', jsonb_array_length(v_items),
                       'obligations_netted', array_length(v_obligation_ids, 1),
                       'total_debtors', v_total_debtors, 'total_creditors', v_total_creditors));

  return jsonb_build_object('batch_id', v_batch, 'items', v_items,
    'obligations_netted', array_length(v_obligation_ids, 1));
end; $$;

revoke all on function public.generate_settlement_batch(uuid, text) from public, anon;
grant execute on function public.generate_settlement_batch(uuid, text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. mark_settlement_paid v3
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.mark_settlement_paid(p_settlement_item_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_item public.settlement_items%rowtype;
  v_batch public.settlement_batches%rowtype;
  v_txn uuid;
  v_closed integer := 0;
  v_batch_finalized boolean := false;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_item from public.settlement_items where id = p_settlement_item_id for update;
  if v_item.id is null then raise exception 'settlement item not found' using errcode = 'P0002'; end if;
  -- R.2I idempotencia: item ya pagado → no-op seguro
  if v_item.status = 'paid' then
    return jsonb_build_object('item_id', p_settlement_item_id, 'already_paid', true,
      'transaction_id', v_item.settled_transaction_id);
  end if;
  -- R.2I.8: item cancelado → falla
  if v_item.status = 'cancelled' then
    raise exception 'cannot pay a cancelled settlement item' using errcode = '22023';
  end if;

  select * into v_batch from public.settlement_batches where id = v_item.settlement_batch_id for update;

  -- R.2I.7: solo el deudor del item, o quien tenga money.settle (admin)
  if v_item.from_actor_id <> v_caller
     and not public.has_actor_authority(v_batch.context_actor_id, v_caller, 'money.settle') then
    raise exception 'not authorized to mark this settlement as paid' using errcode = '42501';
  end if;

  -- transacción de settlement
  insert into public.money_transactions
    (context_actor_id, from_actor_id, to_actor_id, transaction_type, amount, currency, created_by_actor_id, metadata)
  values
    (v_batch.context_actor_id, v_item.from_actor_id, v_item.to_actor_id, 'settlement',
     v_item.amount, v_item.currency, v_caller,
     jsonb_build_object('settlement_item_id', p_settlement_item_id, 'settlement_batch_id', v_batch.id))
  returning id into v_txn;

  update public.settlement_items
     set status = 'paid', settled_transaction_id = v_txn
   where id = p_settlement_item_id;

  -- R.2-3 / R.2I.4: cuando TODOS los items del batch están pagados → finalized +
  -- cerrar TODAS las obligations neteadas (semántica de acuerdo de neteo)
  if not exists (select 1 from public.settlement_items
                 where settlement_batch_id = v_batch.id and status = 'pending') then
    update public.settlement_batches set status = 'finalized', finalized_at = now()
     where id = v_batch.id;
    v_batch_finalized := true;

    update public.obligations
       set status = 'settled',
           metadata = metadata || jsonb_build_object('settled_by_batch', v_batch.id)
     where id in (select (jsonb_array_elements_text(v_batch.metadata->'obligation_ids'))::uuid)
       and status = 'open';
    get diagnostics v_closed = row_count;
  end if;

  -- R.2I activity: settlement.paid
  perform public._emit_activity(v_batch.context_actor_id, v_caller, 'settlement.paid', 'settlement_item', p_settlement_item_id,
    jsonb_build_object('amount', v_item.amount, 'currency', v_item.currency, 'transaction_id', v_txn,
                       'batch_finalized', v_batch_finalized, 'obligations_closed', v_closed));

  return jsonb_build_object('item_id', p_settlement_item_id, 'transaction_id', v_txn,
    'batch_finalized', v_batch_finalized, 'obligations_closed', v_closed);
end; $$;

revoke all on function public.mark_settlement_paid(uuid) from public, anon;
grant execute on function public.mark_settlement_paid(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Helper: sweep dinámico de anon (sin firmas hardcodeadas)
-- ────────────────────────────────────────────────────────────────────────────
-- Verifica que anon no pueda ejecutar NINGUNA función de la app en public.
-- (Excluye funciones de extensiones como btree_gist — internals de índices.)
create or replace function public._assert_anon_has_no_function_access()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_fn text;
begin
  for v_fn in
    select p.oid::regprocedure::text
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
       and has_function_privilege('anon', p.oid, 'EXECUTE')
  loop
    raise exception 'anon puede ejecutar la función %', v_fn;
  end loop;
end; $$;

revoke all on function public._assert_anon_has_no_function_access() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Smoke R.2A: DoD 6 con sweep dinámico (no vuelve a romperse con firmas)
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

  -- DoD 6: anon no puede leer NINGUNA tabla ni ejecutar NINGUNA función de la app
  for v_tbl in select tablename from pg_tables where schemaname = 'public' loop
    if has_table_privilege('anon', 'public.' || v_tbl, 'SELECT') then
      raise exception 'R2A DoD 6 FAIL: anon tiene SELECT en %', v_tbl;
    end if;
  end loop;
  -- R.2I: sweep dinámico — cubre todas las funciones presentes y futuras
  perform public._assert_anon_has_no_function_access();

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_admin, a_member, a_outsider],
    array[u_admin, u_member, u_outsider]);

  raise notice 'R.2A AUTHORITY LAYER DoD: 6/6 PASS';
end; $$;

revoke all on function public._smoke_mvp2_r2a_authority_dod() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Smoke R.2I — caso exacto del founder (con netos corregidos)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2i_settlement_engine_dod()
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
  v_ctx uuid; v_ctx2 uuid; v_code text;
  v_result jsonb;
  v_batch uuid; v_batch_usd uuid; v_batch2 uuid;
  v_item record;
  v_net numeric;
  v_bad_ob uuid;
  v_paid_item uuid; v_paid_txn uuid;
  v_caught boolean;
  r record;
begin
  -- ═══ Setup: Cena Semanal Amigos + las 8 obligations de R.2H (fixture exacto) ═══
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2I', '+5210000090');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2I', '+5210000091');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2I', '+5210000092');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés R2I', '+5210000093');
  select auth_id, actor_id into u_daniel, a_daniel from public._r2_make_person('Daniel R2I', '+5210000094');
  select auth_id, actor_id into u_out, a_out from public._r2_make_person('Outsider R2I', '+5210000095');

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

  -- Las 8 obligations heredadas de R.2H (estado de entrada del spec)
  insert into public.obligations (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type, amount, currency, status, metadata) values
    (v_ctx::uuid, a_moises, v_ctx::uuid, 'fine',          100, 'MXN', 'open', '{"reason": "late_arrival"}'),
    (v_ctx::uuid, a_daniel, v_ctx::uuid, 'fine',          300, 'MXN', 'open', '{"reason": "same_day_cancellation"}'),
    (v_ctx::uuid, a_jose,   a_david,     'expense_share', 325, 'MXN', 'open', '{"description": "cena"}'),
    (v_ctx::uuid, a_isaac,  a_david,     'expense_share', 325, 'MXN', 'open', '{"description": "cena"}'),
    (v_ctx::uuid, a_moises, a_david,     'expense_share', 325, 'MXN', 'open', '{"description": "cena"}'),
    (v_ctx::uuid, a_david,  a_jose,      'expense_share', 200, 'MXN', 'open', '{"description": "postre"}'),
    (v_ctx::uuid, a_isaac,  a_jose,      'expense_share', 200, 'MXN', 'open', '{"description": "postre"}'),
    (v_ctx::uuid, a_daniel, a_moises,    'game_debt',     250, 'MXN', 'open', '{"game_name": "Catan"}');

  -- ═══ R.2I.7 — Permisos (antes de generar) ═══
  -- (2) miembro normal sin money.settle NO puede generar settlement
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin perform public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2I.7 FAIL: member sin money.settle generó settlement'; end if;
  -- (3) no-miembro NO puede
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin perform public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2I.7 FAIL: no-miembro generó settlement'; end if;

  -- ═══ Generar el batch MXN (José, founder/admin con money.settle) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  if v_batch is null then raise exception 'R2I FAIL: batch no generado'; end if;

  -- ═══ R.2I.1 — Validación del batch ═══
  -- 1-3. batch correcto
  if not exists (select 1 from public.settlement_batches
                 where id = v_batch and context_actor_id = v_ctx::uuid and currency = 'MXN' and status = 'draft') then
    raise exception 'R2I.1 FAIL: batch con contexto/moneda/status incorrectos';
  end if;
  -- 2-5. solo las 8 obligations open MXN del contexto
  if jsonb_array_length((select metadata->'obligation_ids' from public.settlement_batches where id = v_batch)) <> 8 then
    raise exception 'R2I.1 FAIL: el batch no neteó exactamente las 8 obligations';
  end if;
  -- metadata: 3 deudores netos (Isaac, Moisés, Daniel) y 3 acreedores (David, José, Grupo)
  -- (el spec decía 4/2 por el error aritmético en el neto de José — ver header)
  if (select (metadata->>'total_debtors')::integer from public.settlement_batches where id = v_batch) <> 3
     or (select (metadata->>'total_creditors')::integer from public.settlement_batches where id = v_batch) <> 3 then
    raise exception 'R2I.1 FAIL: total_debtors/total_creditors incorrectos';
  end if;
  -- semántica documentada (R.2I.4 opción elegida)
  if (select metadata->>'settlement_semantics' from public.settlement_batches where id = v_batch) <> 'net_batch_closure' then
    raise exception 'R2I.1 FAIL: settlement_semantics no documentada en metadata';
  end if;

  -- 6-7. los items balancean EXACTAMENTE los netos correctos:
  --   José +75, David +775, Isaac -525, Moisés -175, Daniel -550, Grupo +400
  for r in
    select * from (values
      (a_jose, 75::numeric), (a_david, 775::numeric), (a_isaac, -525::numeric),
      (a_moises, -175::numeric), (a_daniel, -550::numeric)) t(actor_id, expected_net)
    union all select v_ctx::uuid, 400::numeric
  loop
    select coalesce(sum(amount) filter (where to_actor_id = r.actor_id), 0)
         - coalesce(sum(amount) filter (where from_actor_id = r.actor_id), 0)
      into v_net
      from public.settlement_items where settlement_batch_id = v_batch;
    if v_net <> r.expected_net then
      raise exception 'R2I.1 FAIL: neto de % = % (esperaba %)', r.actor_id, v_net, r.expected_net;
    end if;
  end loop;
  -- total liquidado = 1250 (suma de netos positivos = suma de negativos)
  if (select sum(amount) from public.settlement_items where settlement_batch_id = v_batch) <> 1250 then
    raise exception 'R2I.1 FAIL: total liquidado = % (esperaba 1250)',
      (select sum(amount) from public.settlement_items where settlement_batch_id = v_batch);
  end if;
  -- 8. ningún item con amount <= 0
  if exists (select 1 from public.settlement_items where settlement_batch_id = v_batch and amount <= 0) then
    raise exception 'R2I.1 FAIL: hay items con amount <= 0';
  end if;
  -- 9. ningún item from = to
  if exists (select 1 from public.settlement_items where settlement_batch_id = v_batch
             and from_actor_id = to_actor_id) then
    raise exception 'R2I.1 FAIL: hay items actor → mismo actor';
  end if;
  -- 10. todos los actors de items están involucrados en las obligations
  if exists (
    select 1 from public.settlement_items si
    where si.settlement_batch_id = v_batch
      and (not exists (select 1 from public.obligations o where o.context_actor_id = v_ctx::uuid
                       and (o.debtor_actor_id = si.from_actor_id or o.creditor_actor_id = si.from_actor_id))
        or not exists (select 1 from public.obligations o where o.context_actor_id = v_ctx::uuid
                       and (o.debtor_actor_id = si.to_actor_id or o.creditor_actor_id = si.to_actor_id)))
  ) then
    raise exception 'R2I.1 FAIL: items con actors ajenos a las obligations';
  end if;
  -- número de pagos razonable (greedy: máx deudores + acreedores - 1 = 5)
  if (select count(*) from public.settlement_items where settlement_batch_id = v_batch) > 5 then
    raise exception 'R2I.1 FAIL: el neteo no es mínimo/razonable (% items)',
      (select count(*) from public.settlement_items where settlement_batch_id = v_batch);
  end if;

  -- ═══ R.2I.2 — Idempotencia de generate ═══
  v_result := public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  if (v_result->>'batch_id')::uuid is distinct from v_batch
     or not coalesce((v_result->>'idempotent_replay')::boolean, false) then
    raise exception 'R2I.2 FAIL: re-generar no devolvió el mismo batch';
  end if;
  if (select count(*) from public.settlement_batches
      where context_actor_id = v_ctx::uuid and currency = 'MXN') <> 1 then
    raise exception 'R2I.2 FAIL: se duplicó el batch';
  end if;

  -- ═══ R.2I.5 — Multimoneda ═══
  insert into public.obligations (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type, amount, currency, status)
  values (v_ctx::uuid, a_jose, a_david, 'iou', 50, 'USD', 'open');

  v_result := public.generate_settlement_batch(v_ctx::uuid, 'USD');
  v_batch_usd := (v_result->>'batch_id')::uuid;
  -- el batch USD solo incluye la obligation USD
  if jsonb_array_length((select metadata->'obligation_ids' from public.settlement_batches where id = v_batch_usd)) <> 1 then
    raise exception 'R2I.5 FAIL: el batch USD no neteó solo la obligation USD';
  end if;
  if exists (select 1 from public.settlement_items where settlement_batch_id = v_batch_usd and currency <> 'USD') then
    raise exception 'R2I.5 FAIL: el batch USD tiene items en otra moneda';
  end if;
  -- el batch MXN no cambió
  if (select count(*) from public.settlement_items where settlement_batch_id = v_batch and currency <> 'MXN') <> 0 then
    raise exception 'R2I.5 FAIL: el batch MXN incluye monedas ajenas';
  end if;

  -- ═══ R.2I.6 + R.2I.8 — Otro contexto (Viaje Japón) + validaciones duras ═══
  v_ctx2 := (public.create_context('Viaje Japón', 'collective', 'trip'))->>'context_actor_id';
  -- obligation válida del viaje
  insert into public.obligations (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type, amount, currency, status)
  values (v_ctx2::uuid, a_david, a_jose, 'trip_share', 10000, 'MXN', 'open');

  -- R.2I.8: obligation con amount null → generate falla
  insert into public.obligations (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type, amount, currency, status)
  values (v_ctx2::uuid, a_david, a_jose, 'iou', null, 'MXN', 'open')
  returning id into v_bad_ob;
  v_caught := false;
  begin perform public.generate_settlement_batch(v_ctx2::uuid, 'MXN');
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2I.8 FAIL: obligations con amount null no hicieron fallar'; end if;
  delete from public.obligations where id = v_bad_ob;

  -- R.2I.8: obligation con debtor = creditor → generate falla
  insert into public.obligations (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type, amount, currency, status)
  values (v_ctx2::uuid, a_david, a_david, 'iou', 99, 'MXN', 'open')
  returning id into v_bad_ob;
  v_caught := false;
  begin perform public.generate_settlement_batch(v_ctx2::uuid, 'MXN');
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2I.8 FAIL: obligations debtor=creditor no hicieron fallar'; end if;
  delete from public.obligations where id = v_bad_ob;

  -- R.2I.6: el settlement del Viaje solo incluye lo del Viaje
  v_result := public.generate_settlement_batch(v_ctx2::uuid, 'MXN');
  v_batch2 := (v_result->>'batch_id')::uuid;
  if jsonb_array_length((select metadata->'obligation_ids' from public.settlement_batches where id = v_batch2)) <> 1 then
    raise exception 'R2I.6 FAIL: el batch del Viaje no incluye solo su obligation';
  end if;
  -- y el batch de la Cena nunca incluyó nada del Viaje (sus 8 ids son del contexto Cena)
  if exists (
    select 1 from jsonb_array_elements_text(
      (select metadata->'obligation_ids' from public.settlement_batches where id = v_batch)) oid
    join public.obligations o on o.id = oid::uuid
    where o.context_actor_id <> v_ctx::uuid
  ) then
    raise exception 'R2I.6 FAIL: el batch de la Cena incluye obligations de otro contexto';
  end if;

  -- ═══ R.2I.3 — mark_settlement_paid ═══
  -- Daniel paga su item (el más grande, a David)
  select id, from_actor_id, to_actor_id, amount into v_item from public.settlement_items
   where settlement_batch_id = v_batch and from_actor_id = a_daniel limit 1;
  if v_item.id is null then raise exception 'R2I.3 FAIL: no existe item de Daniel'; end if;

  -- permiso negativo: Moisés (no es el deudor ni admin) no puede pagar el item de Daniel
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  v_caught := false;
  begin perform public.mark_settlement_paid(v_item.id);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2I.7 FAIL: actor no involucrado marcó pago ajeno'; end if;

  -- Daniel (el deudor) paga
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_result := public.mark_settlement_paid(v_item.id);
  v_paid_txn := (v_result->>'transaction_id')::uuid;
  v_paid_item := v_item.id;

  if (select status from public.settlement_items where id = v_paid_item) <> 'paid' then
    raise exception 'R2I.3 FAIL: el item no quedó paid';
  end if;
  if not exists (
    select 1 from public.money_transactions
    where id = v_paid_txn and transaction_type = 'settlement' and status = 'posted'
      and from_actor_id = v_item.from_actor_id and to_actor_id = v_item.to_actor_id
      and amount = v_item.amount and currency = 'MXN'
  ) then
    raise exception 'R2I.3 FAIL: la money_transaction del settlement es incorrecta';
  end if;
  if (select settled_transaction_id from public.settlement_items where id = v_paid_item) is distinct from v_paid_txn then
    raise exception 'R2I.3 FAIL: settled_transaction_id no apunta a la transaction';
  end if;

  -- Idempotencia: re-pagar el mismo item → no-op, no duplica transaction
  v_result := public.mark_settlement_paid(v_paid_item);
  if not coalesce((v_result->>'already_paid')::boolean, false) then
    raise exception 'R2I.3 FAIL: re-pagar no fue no-op';
  end if;
  if (select count(*) from public.money_transactions
      where transaction_type = 'settlement' and (metadata->>'settlement_item_id')::uuid = v_paid_item) <> 1 then
    raise exception 'R2I.3 FAIL: se duplicó la transaction del pago';
  end if;

  -- ═══ R.2I.4 — Cierre por batch (opción elegida y documentada) ═══
  -- Tras el pago PARCIAL: las 8 obligations MXN siguen open (el settlement liquida netos)
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and currency = 'MXN' and status = 'open') <> 8 then
    raise exception 'R2I.4 FAIL: un pago parcial cerró obligations individuales';
  end if;

  -- José (admin con money.settle) paga todos los items restantes → batch finalized → las 8 se cierran
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  for v_item in select id from public.settlement_items
                 where settlement_batch_id = v_batch and status = 'pending' loop
    perform public.mark_settlement_paid(v_item.id);
  end loop;

  if (select status from public.settlement_batches where id = v_batch) <> 'finalized' then
    raise exception 'R2I.4 FAIL: el batch no quedó finalized al pagar todo';
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and currency = 'MXN' and status = 'open') <> 0 then
    raise exception 'R2I.4 FAIL: quedaron obligations MXN abiertas tras finalizar el batch';
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and currency = 'MXN' and status = 'settled'
        and metadata ? 'settled_by_batch') <> 8 then
    raise exception 'R2I.4 FAIL: las 8 obligations no quedaron settled con provenance del batch';
  end if;
  -- la obligation USD sigue abierta (no era parte del batch MXN)
  if (select status from public.obligations
      where context_actor_id = v_ctx::uuid and currency = 'USD') <> 'open' then
    raise exception 'R2I.4 FAIL: la obligation USD se cerró con el batch MXN';
  end if;

  -- ═══ R.2I.8 — Validaciones duras restantes ═══
  -- currency null
  v_caught := false;
  begin perform public.generate_settlement_batch(v_ctx::uuid, null);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2I.8 FAIL: currency null no falló'; end if;
  -- contexto inválido (uuid aleatorio)
  v_caught := false;
  begin perform public.generate_settlement_batch(gen_random_uuid(), 'MXN');
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2I.8 FAIL: contexto inválido no falló'; end if;
  -- sin obligations abiertas (las MXN de la Cena ya quedaron settled)
  v_caught := false;
  begin perform public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2I.8 FAIL: generate sin obligations abiertas no falló'; end if;
  -- mark_settlement_paid: item inexistente
  v_caught := false;
  begin perform public.mark_settlement_paid(gen_random_uuid());
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2I.8 FAIL: item inexistente no falló'; end if;
  -- mark_settlement_paid: item cancelado
  update public.settlement_items set status = 'cancelled'
   where settlement_batch_id = v_batch_usd;
  v_caught := false;
  begin
    perform public.mark_settlement_paid((select id from public.settlement_items
                                          where settlement_batch_id = v_batch_usd limit 1));
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2I.8 FAIL: item cancelado no falló'; end if;

  -- ═══ Activity events ═══
  -- settlement.generated: Cena MXN + Cena USD = 2 (en el contexto Cena)
  if (select count(*) from public.activity_events where context_actor_id = v_ctx::uuid
      and event_type = 'settlement.generated') <> 2 then
    raise exception 'R2I FAIL activity: settlement.generated debe ser 2 (MXN + USD)';
  end if;
  -- settlement.item_created: items del batch MXN + items del batch USD
  if (select count(*) from public.activity_events where context_actor_id = v_ctx::uuid
      and event_type = 'settlement.item_created')
     <> (select count(*) from public.settlement_items where settlement_batch_id in (v_batch, v_batch_usd)) then
    raise exception 'R2I FAIL activity: settlement.item_created no coincide con los items creados';
  end if;
  -- settlement.paid: todos los items pagados del batch MXN
  if (select count(*) from public.activity_events where context_actor_id = v_ctx::uuid
      and event_type = 'settlement.paid')
     <> (select count(*) from public.settlement_items where settlement_batch_id = v_batch and status = 'paid') then
    raise exception 'R2I FAIL activity: settlement.paid no coincide con los pagos';
  end if;

  -- ═══ Anon bloqueado (sweep dinámico de todas las funciones de la app) ═══
  perform public._assert_anon_has_no_function_access();

  -- ═══ Cleanup (ambos contextos) ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx2::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_jose, a_david, a_isaac, a_moises, a_daniel, a_out],
    array[u_jose, u_david, u_isaac, u_moises, u_daniel, u_out]);

  raise notice 'R.2I SETTLEMENT ENGINE DoD: PASS (neteo $1250, 3 deudores/3 acreedores, multimoneda, aislamiento, cierre por batch, permisos)';
end; $$;

revoke all on function public._smoke_r2i_settlement_engine_dod() from public, anon, authenticated;

comment on function public._smoke_r2i_settlement_engine_dod() is
  'R.2I DoD: las 8 obligations de R.2H → batch MXN con netos correctos (José +75, David +775, Isaac -525, Moisés -175, Daniel -550, Grupo +400 = $1,250) → idempotencia → multimoneda → aislamiento de contextos → pago + cierre por batch → permisos → validaciones duras.';

-- Wrapper para CI (descubre funciones _smoke_mvp2_%)
create or replace function public._smoke_mvp2_r2i_settlement_engine_dod()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._smoke_r2i_settlement_engine_dod();
end; $$;

revoke all on function public._smoke_mvp2_r2i_settlement_engine_dod() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2i_settlement_engine_dod() is
  'Wrapper CI del smoke R.2I (_smoke_r2i_settlement_engine_dod).';
