-- ============================================================================
-- AUDIT.9 — void_transaction(): reversa segura de transacciones (2026-06-11)
-- ============================================================================
-- Fase 2 ítem 4 del SupabaseCleanupMigrationPlan. money_transactions.status
-- contemplaba 'voided' desde mvp2_009 pero ningún RPC lo exponía: no había
-- forma de corregir un gasto/multa mal registrado sin tocar la base a mano.
--
-- Semántica (deliberadamente estrecha — todo lo demás raise exception):
--   · Solo transacciones 'posted'. Replay sobre 'voided' = idempotente.
--   · Solo el creador o un actor con money.settle en el contexto.
--   · transaction_type = 'settlement' NUNCA se anula por aquí (el handshake
--     2-vías r5z + appeal es el flujo correcto).
--   · Si settlement_items.settled_transaction_id la referencia → rechazo.
--   · Obligaciones vinculadas (metadata->>'transaction_id' del flujo
--     record_expense/record_game_result, o money_transactions.obligation_id
--     del flujo record_fine): si alguna salió del estado 'open' (settled /
--     netted_into_batch por la novación R.2N, in_progress, etc.) → rechazo:
--     anular reescribiría historia de settlement. Las 'open' se cancelan con
--     provenance en metadata.
--   · Ledger: por cada entrada de la txn se inserta la entrada espejo
--     (debit↔credit, mismo monto) marcada reversal=true → los balances de
--     actor_money_balances quedan netos sin tocar historia (append-only).
--   · Actividad: 'transaction.voided' (catalogada aquí mismo).
-- Rollback: drop function + delete del catálogo (las reversas emitidas son
-- historia legítima y no se borran).
-- ============================================================================

insert into public.activity_event_catalog
  (event_type, domain, description, expected_subject_type, is_system_generated)
values
  ('transaction.voided', 'money', 'Transacción anulada con reversa de ledger y cancelación de obligaciones abiertas vinculadas', 'money_transaction', false)
on conflict (event_type) do nothing;

create or replace function public.void_transaction(
  p_transaction_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_txn public.money_transactions%rowtype;
  v_blocked int;
  v_cancelled uuid[] := '{}';
  v_ob record;
  v_entry record;
  v_reversals int := 0;
begin
  if v_caller is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  select * into v_txn from public.money_transactions
   where id = p_transaction_id
   for update;
  if not found then
    raise exception 'transaction % not found', p_transaction_id using errcode = '22023';
  end if;

  -- Idempotencia: re-void es no-op
  if v_txn.status = 'voided' then
    return jsonb_build_object('transaction_id', v_txn.id, 'status', 'voided',
                              'idempotent_replay', true);
  end if;
  if v_txn.status <> 'posted' then
    raise exception 'only posted transactions can be voided (status %)', v_txn.status
      using errcode = '22023';
  end if;

  -- Autoridad: creador, o money.settle en el contexto de la transacción
  if v_txn.created_by_actor_id is distinct from v_caller
     and not (v_txn.context_actor_id is not null
              and public.has_actor_authority(v_txn.context_actor_id, v_caller, 'money.settle')) then
    raise exception 'voiding requires being the creator or money.settle authority'
      using errcode = '42501';
  end if;

  if v_txn.transaction_type = 'settlement' then
    raise exception 'settlement transactions cannot be voided; use the confirm/reject/appeal handshake'
      using errcode = '22023';
  end if;
  if exists (select 1 from public.settlement_items si
              where si.settled_transaction_id = v_txn.id) then
    raise exception 'transaction is referenced by a settlement item and cannot be voided'
      using errcode = '22023';
  end if;

  -- Obligaciones vinculadas fuera de 'open' bloquean el void
  select count(*) into v_blocked
  from public.obligations o
  where ((o.metadata->>'transaction_id')::uuid = v_txn.id or o.id = v_txn.obligation_id)
    and o.status not in ('open', 'cancelled');
  if v_blocked > 0 then
    raise exception 'transaction has % linked obligation(s) beyond open state; voiding would rewrite settlement history', v_blocked
      using errcode = '22023';
  end if;

  -- Cancelar las obligaciones 'open' vinculadas, con provenance
  for v_ob in
    select o.id from public.obligations o
    where ((o.metadata->>'transaction_id')::uuid = v_txn.id or o.id = v_txn.obligation_id)
      and o.status = 'open'
    for update
  loop
    update public.obligations
       set status = 'cancelled',
           metadata = metadata || jsonb_build_object(
             'cancelled_reason', 'transaction_voided',
             'voided_transaction_id', v_txn.id,
             'voided_by_actor_id', v_caller)
     where id = v_ob.id;
    v_cancelled := v_cancelled || v_ob.id;
  end loop;

  -- Reversa de ledger: entrada espejo por cada entrada original (append-only)
  for v_entry in
    select * from public.ledger_entries
     where transaction_id = v_txn.id
       and coalesce(metadata->>'reversal', 'false') <> 'true'
  loop
    insert into public.ledger_entries
      (context_actor_id, transaction_id, actor_id, entry_type, amount, currency,
       occurred_at, metadata)
    values
      (v_entry.context_actor_id, v_txn.id, v_entry.actor_id,
       case v_entry.entry_type when 'debit' then 'credit' else 'debit' end,
       v_entry.amount, v_entry.currency, now(),
       jsonb_build_object('reversal', true,
                          'reversal_of_entry', v_entry.id,
                          'voided_by_actor_id', v_caller));
    v_reversals := v_reversals + 1;
  end loop;

  update public.money_transactions
     set status = 'voided',
         metadata = metadata || jsonb_build_object(
           'voided_at', now(),
           'voided_by_actor_id', v_caller,
           'void_reason', p_reason)
   where id = v_txn.id;

  perform public._emit_activity(
    v_txn.context_actor_id, v_caller, 'transaction.voided',
    'money_transaction', v_txn.id,
    jsonb_build_object(
      'transaction_type', v_txn.transaction_type,
      'amount', v_txn.amount,
      'currency', v_txn.currency,
      'reason', p_reason,
      'cancelled_obligations', to_jsonb(v_cancelled),
      'reversed_ledger_entries', v_reversals));

  return jsonb_build_object(
    'transaction_id', v_txn.id,
    'status', 'voided',
    'cancelled_obligations', to_jsonb(v_cancelled),
    'reversed_ledger_entries', v_reversals);
end;
$$;

revoke all on function public.void_transaction(uuid, text) from public, anon;
grant execute on function public.void_transaction(uuid, text) to authenticated, service_role;

comment on function public.void_transaction(uuid, text) is
  'AUDIT.9: anula una transacción posted (no settlement, no referenciada por settlement, obligaciones vinculadas solo open) con reversa append-only de ledger + transaction.voided. Idempotente sobre voided.';

-- ────────────────────────────────────────────────────────────────────────────
-- Smoke
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_audit_void_transaction()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  u_a uuid; a_a uuid;
  u_b uuid; a_b uuid;
  u_c uuid; a_c uuid;
  v_ctx uuid; v_code text;
  v_txn uuid;
  v_result jsonb;
  v_open int; v_cancelled int;
  v_net numeric;
  v_caught boolean;
begin
  -- Mundo: contexto de 3 con un gasto repartido
  select auth_id, actor_id into u_a, a_a from public._r2_make_person('Ana VoidTx', '+5210000990');
  select auth_id, actor_id into u_b, a_b from public._r2_make_person('Beto VoidTx', '+5210000991');
  select auth_id, actor_id into u_c, a_c from public._r2_make_person('Caro VoidTx', '+5210000992');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := (public.create_context('Void Tx Smoke', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_txn := (public.record_expense(v_ctx::uuid, 300, 'MXN', 'Gasto a anular',
              p_split_with := array[a_a, a_b, a_c]))->>'transaction_id';

  select count(*) into v_open from public.obligations
   where (metadata->>'transaction_id')::uuid = v_txn and status = 'open';
  if v_open < 1 then
    raise exception 'void smoke 1: el gasto no generó obligaciones open vinculadas';
  end if;

  -- 2. No-creador sin money.settle no puede anular
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  v_caught := false;
  begin
    perform public.void_transaction(v_txn);
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'void smoke 2: un miembro no-creador sin money.settle pudo anular';
  end if;

  -- 3. El creador anula: txn voided, obligaciones canceladas, ledger neto 0
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_result := public.void_transaction(v_txn, 'smoke: gasto erróneo');
  if v_result->>'status' <> 'voided' then
    raise exception 'void smoke 3a: status esperado voided, fue %', v_result->>'status';
  end if;
  if not exists (select 1 from public.money_transactions where id = v_txn and status = 'voided') then
    raise exception 'void smoke 3b: la transacción no quedó voided';
  end if;
  select count(*) into v_cancelled from public.obligations
   where (metadata->>'transaction_id')::uuid = v_txn and status = 'cancelled';
  if v_cancelled <> v_open then
    raise exception 'void smoke 3c: % obligaciones canceladas, esperaba %', v_cancelled, v_open;
  end if;
  select coalesce(sum(case entry_type when 'credit' then amount else -amount end), 0)
    into v_net
    from public.ledger_entries where transaction_id = v_txn;
  if v_net <> 0 then
    raise exception 'void smoke 3d: el ledger de la txn no quedó neto (%)', v_net;
  end if;
  if not exists (select 1 from public.activity_events
                  where event_type = 'transaction.voided' and subject_id = v_txn) then
    raise exception 'void smoke 3e: no se emitió transaction.voided';
  end if;

  -- 4. Replay idempotente
  v_result := public.void_transaction(v_txn);
  if coalesce((v_result->>'idempotent_replay')::boolean, false) is not true then
    raise exception 'void smoke 4: el replay no fue idempotente';
  end if;

  -- 5. Obligación vinculada fuera de open bloquea el void
  v_txn := (public.record_expense(v_ctx::uuid, 90, 'MXN', 'Gasto con obligación settled',
              p_split_with := array[a_a, a_b, a_c]))->>'transaction_id';
  update public.obligations set status = 'settled'
   where (metadata->>'transaction_id')::uuid = v_txn and status = 'open'
     and id = (select id from public.obligations
                where (metadata->>'transaction_id')::uuid = v_txn and status = 'open'
                limit 1);
  v_caught := false;
  begin
    perform public.void_transaction(v_txn);
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'void smoke 5: se pudo anular con una obligación settled vinculada';
  end if;

  -- Cleanup
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_a, a_b, a_c], array[u_a, u_b, u_c]);
  raise notice '_smoke_mvp2_audit_void_transaction: green';
end;
$$;

revoke all on function public._smoke_mvp2_audit_void_transaction() from public, anon, authenticated;

comment on function public._smoke_mvp2_audit_void_transaction() is
  'AUDIT.9: void_transaction — autoridad, reversa de ledger neta, cancelación de obligaciones open, idempotencia, guard de obligaciones settled.';
