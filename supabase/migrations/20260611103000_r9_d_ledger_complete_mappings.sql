-- ============================================================================
-- R.9.D — LEDGER SOMBRA COMPLETO: mapeos para TODOS los transaction_types
-- ============================================================================
-- Problema: el ledger de doble entrada (R.4C) sólo mapeaba 'expense' y
-- 'payment'. Los movimientos de settlement / multas / game_result /
-- contribution / payout NO generaban filas de ledger, así que ledger_entries
-- y actor_money_balances los omitían en silencio. El producto ya le dio la
-- vuelta (el balance del context descriptor lee obligations), pero el ledger
-- deja de servir como verificación de integridad si le faltan familias enteras.
--
-- Auditoría de qué emite splits HOY (fuente: cadena de migrations, incluidos
-- los slices R.9.A–C y R.8.C de esta misma ronda):
--   · record_expense (r2s_3 / r9_c)    → expense: payer / beneficiary / debtor / excluded
--   · record_game_result (r2h y r9_b)  → game_result: debtor (perdedor) / creditor (ganador)
--   · record_fine (r9_b)               → transaction ancla type='other'
--                                        (metadata.kind='fine') + splits debtor / creditor
--   · resolve_pool (r8_c, posterior)   → payout: payer (pool) / beneficiary (winner)
--   · _settlement_finalize_item (r5z)  → 'settlement' transaction SIN splits
--   · contribute_to_pool (r8_b, cash)  → 'contribution' transaction SIN splits
--   · 'payment'                        → ningún writer en producción (solo smokes r4c)
--
-- Qué hace esta migration:
--   1. Constraint fix: settlement_items.status ahora admite
--      'pending_confirmation' y 'disputed' — R.5Z (handshake + appeal) los
--      escribe pero el CHECK de mvp2_009 nunca se relajó (bug latente: el
--      primer deudor que marcara pagado reventaba el CHECK; ningún smoke
--      ejercía el camino del deudor).
--   2. _ledger_entry_type_for(type, role): la tabla de mapeo canónica, en UN
--      solo lugar (la usan el trigger y el backfill — cero drift).
--   3. _emit_ledger_from_split redefinido para usar el mapeo completo.
--   4. Trigger nuevo _emit_splits_for_two_party_txn sobre money_transactions:
--      settlement y contribution son transferencias bilaterales (from → to)
--      cuyos writers NO insertan splits; el trigger los sintetiza para que el
--      ledger los registre sin tocar cada writer. payout (r8_c) y la multa
--      ancla 'other' (r9_b) NO pasan por aquí: sus writers ya insertan splits.
--   5. Backfill A: sintetiza splits para transactions settlement/contribution
--      históricas sin splits — al insertarse, el trigger de money_splits emite
--      las filas de ledger automáticamente.
--   6. Backfill B: filas de ledger para splits históricos que ahora mapean
--      (game_result, multas 'other'). Idempotente vía metadata->>'source_split_id'.
--   7. Smoke _smoke_mvp2_r9_d_ledger_complete().
--
-- NO se toca record_fine: R.9.B (20260611101000) ya lo dejó con transaction
-- ancla + splits + idempotencia, y su smoke asserta transaction_type='other'.
--
-- ── Convención de signos (heredada de R.4C: view actor_money_balances) ──────
--   credit = dinero que salió del bolsillo del actor / su claim sube
--            (suma al net_balance → positivo = acreedor)
--   debit  = consumo / beneficio recibido / su obligación sube
--            (resta del net_balance → negativo = deudor)
--   Invariante: cada transacción mapeada emite credits == debits, así que la
--   suma firmada por (context, currency) entre actores siempre es 0.
--
-- ── Tabla de mapeo (transaction_type, split_role) → entry_type ──────────────
--   expense      payer        → credit   (puso el dinero de la cuenta)
--   expense      beneficiary  → debit    (consumió su parte)
--   expense      debtor       → debit    (tercero que debe su parte)
--   payment      payer        → credit   (paga su deuda → su neto sube a 0)
--   payment      debtor       → credit   (alias legacy del payer)
--   payment      creditor     → debit    (recibe el pago → su claim baja)
--   settlement   payer        → credit   (deudor que liquida el iou)
--   settlement   debtor       → credit   (alias defensivo, familia payment)
--   settlement   creditor     → debit    (acreedor que recibe)
--   game_result  debtor       → debit    (perdedor)
--   game_result  creditor     → credit   (ganador)
--   contribution payer        → credit   (aportó al pool → tiene basis/claim)
--   contribution beneficiary  → debit    (el pool actor recibió el dinero)
--   payout       payer        → credit   (el pool paga → su neto sube a 0)
--   payout       beneficiary  → debit    (receptor del payout → su claim baja)
--   other        debtor       → debit    (deuda bilateral genérica — hoy: la
--   other        creditor     → credit    multa ancla de record_fine R.9.B)
--   *            excluded     → (sin fila — contrato del smoke r4c C7)
--   other        payer/beneficiary/… → (sin fila — semántica desconocida)
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. settlement_items.status CHECK: + 'pending_confirmation' / 'disputed'
--    (los escriben mark_settlement_paid R.5Z y appeal_settlement_payment;
--     el CHECK original de mvp2_009 nunca se actualizó)
-- ────────────────────────────────────────────────────────────────────────────
alter table public.settlement_items
  drop constraint if exists settlement_items_status_check;
alter table public.settlement_items
  add constraint settlement_items_status_check
  check (status in ('pending', 'pending_confirmation', 'disputed', 'paid', 'cancelled'));

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Mapeo canónico (transaction_type, split_role) → entry_type
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._ledger_entry_type_for(
  p_transaction_type text,
  p_split_role text
)
returns text
language sql
immutable
as $$
  select case
    -- expense: el payer puso el dinero (credit); beneficiarios y debtors
    -- terceros consumieron (debit).
    when p_transaction_type = 'expense'      and p_split_role = 'payer'       then 'credit'
    when p_transaction_type = 'expense'      and p_split_role = 'beneficiary' then 'debit'
    when p_transaction_type = 'expense'      and p_split_role = 'debtor'      then 'debit'
    -- payment: quien paga (payer/debtor legacy) sube su neto hacia 0 (credit);
    -- quien recibe (creditor) baja su claim (debit).
    when p_transaction_type = 'payment'      and p_split_role = 'payer'       then 'credit'
    when p_transaction_type = 'payment'      and p_split_role = 'debtor'      then 'credit'
    when p_transaction_type = 'payment'      and p_split_role = 'creditor'    then 'debit'
    -- settlement: misma familia que payment (el deudor liquida el iou).
    when p_transaction_type = 'settlement'   and p_split_role = 'payer'       then 'credit'
    when p_transaction_type = 'settlement'   and p_split_role = 'debtor'      then 'credit'
    when p_transaction_type = 'settlement'   and p_split_role = 'creditor'    then 'debit'
    -- game_result: perdedor debe (debit), ganador con claim (credit).
    when p_transaction_type = 'game_result'  and p_split_role = 'debtor'      then 'debit'
    when p_transaction_type = 'game_result'  and p_split_role = 'creditor'    then 'credit'
    -- contribution: el contribuyente puso dinero al pool (credit); el pool
    -- actor lo recibió (debit). Simétrico con expense.
    when p_transaction_type = 'contribution' and p_split_role = 'payer'       then 'credit'
    when p_transaction_type = 'contribution' and p_split_role = 'beneficiary' then 'debit'
    -- payout (resolve_pool R.8.C: pool actor payer / winner beneficiary):
    -- el pool paga (credit, su neto sube a 0), el receptor recibe (debit).
    when p_transaction_type = 'payout'       and p_split_role = 'payer'       then 'credit'
    when p_transaction_type = 'payout'       and p_split_role = 'beneficiary' then 'debit'
    -- other + debtor/creditor: deuda bilateral genérica. Hoy el único writer
    -- es la multa ancla de record_fine (R.9.B): multado debtor (debit), el
    -- contexto creditor (credit).
    when p_transaction_type = 'other'        and p_split_role = 'debtor'      then 'debit'
    when p_transaction_type = 'other'        and p_split_role = 'creditor'    then 'credit'
    -- 'excluded' y cualquier combinación desconocida (roles raros, 'other'
    -- con payer/beneficiary): intencionalmente SIN fila (contrato r4c C7).
    else null
  end;
$$;

comment on function public._ledger_entry_type_for(text, text) is
  'R.9.D: tabla canónica (transaction_type, split_role) → debit/credit del ledger sombra. NULL = no se emite fila (excluded / combinaciones desconocidas).';

revoke all on function public._ledger_entry_type_for(text, text) from public, anon;
grant execute on function public._ledger_entry_type_for(text, text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Trigger de splits → ledger, ahora con el mapeo completo
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._emit_ledger_from_split()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_txn public.money_transactions%rowtype;
  v_entry_type text;
begin
  select * into v_txn from public.money_transactions where id = new.transaction_id;
  if v_txn.id is null or v_txn.context_actor_id is null then
    return new;
  end if;

  v_entry_type := public._ledger_entry_type_for(v_txn.transaction_type, new.split_role);
  if v_entry_type is null then
    return new;
  end if;

  insert into public.ledger_entries(
    context_actor_id, transaction_id, actor_id, entry_type, amount, currency,
    occurred_at, metadata
  )
  values (
    v_txn.context_actor_id, v_txn.id, new.actor_id, v_entry_type, new.amount,
    new.currency, v_txn.occurred_at,
    jsonb_build_object(
      'transaction_type', v_txn.transaction_type,
      'split_role', new.split_role,
      'source_split_id', new.id
    )
  );

  return new;
end;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Trigger nuevo: transactions bilaterales sin splits → splits sintéticos
-- ────────────────────────────────────────────────────────────────────────────
-- _settlement_finalize_item (r5z) y contribute_to_pool (r8_b, cash) crean la
-- transaction con from/to pero NO insertan money_splits, así que el trigger
-- del punto 3 nunca disparaba para esas familias. Este trigger sintetiza los
-- dos splits canónicos al insertar la transaction; el ledger sale en cascada
-- del trigger de money_splits.
--
-- CONTRATO: los writers de 'settlement' y 'contribution' NO deben insertar
-- splits manualmente (se duplicaría la doble entrada). expense / payment /
-- game_result / payout (r8_c) / 'other' (multa r9_b) siguen emitiendo sus
-- propios splits y NO pasan por aquí.
create or replace function public._emit_splits_for_two_party_txn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.transaction_type not in ('settlement', 'contribution') then
    return new;
  end if;
  if new.context_actor_id is null
     or new.from_actor_id is null
     or new.to_actor_id is null
     or new.from_actor_id = new.to_actor_id
     or new.status <> 'posted' then
    return new;
  end if;

  insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency, metadata)
  values
    (new.id, new.from_actor_id,
     'payer',
     new.amount, new.currency,
     jsonb_build_object('auto_emitted', 'two_party_txn')),
    (new.id, new.to_actor_id,
     case new.transaction_type when 'settlement' then 'creditor' else 'beneficiary' end,
     new.amount, new.currency,
     jsonb_build_object('auto_emitted', 'two_party_txn'));

  return new;
end;
$$;

comment on function public._emit_splits_for_two_party_txn() is
  'R.9.D: sintetiza los 2 money_splits canónicos para transactions bilaterales settlement/contribution cuyos writers no insertan splits. El ledger sale en cascada del trigger de money_splits.';

drop trigger if exists money_transactions_emit_two_party_splits on public.money_transactions;
create trigger money_transactions_emit_two_party_splits
  after insert on public.money_transactions
  for each row execute function public._emit_splits_for_two_party_txn();

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Backfill A: splits sintéticos para transactions settlement/contribution
--    históricas sin splits. Al insertarse disparan money_splits_emit_ledger →
--    las filas de ledger salen solas con el mapeo nuevo. Idempotente:
--    NOT EXISTS splits para esa transaction.
-- ────────────────────────────────────────────────────────────────────────────
insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency, metadata)
select
  t.id, x.actor_id, x.split_role, t.amount, t.currency,
  jsonb_build_object('auto_emitted', 'two_party_txn', 'backfill', 'r9_d')
from public.money_transactions t
cross join lateral (
  values
    (t.from_actor_id, 'payer'),
    (t.to_actor_id,   case t.transaction_type when 'settlement' then 'creditor' else 'beneficiary' end)
) as x(actor_id, split_role)
where t.transaction_type in ('settlement', 'contribution')
  and t.context_actor_id is not null
  and t.from_actor_id is not null
  and t.to_actor_id is not null
  and t.from_actor_id <> t.to_actor_id
  and t.status = 'posted'
  and not exists (
    select 1 from public.money_splits s where s.transaction_id = t.id
  );

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Backfill B: filas de ledger para splits históricos que AHORA mapean y
--    todavía no tienen fila (game_result debtor/creditor, multas 'other';
--    cubre también cualquier expense/payment que se hubiera escapado).
--    Idempotente vía metadata->>'source_split_id' (lo escriben tanto el
--    trigger como los backfills de r4c y éste).
-- ────────────────────────────────────────────────────────────────────────────
insert into public.ledger_entries (
  context_actor_id, transaction_id, actor_id, entry_type, amount, currency,
  occurred_at, metadata
)
select
  t.context_actor_id, t.id, s.actor_id,
  public._ledger_entry_type_for(t.transaction_type, s.split_role) as entry_type,
  s.amount, s.currency, t.occurred_at,
  jsonb_build_object(
    'transaction_type', t.transaction_type,
    'split_role', s.split_role,
    'source_split_id', s.id,
    'backfill', 'r9_d'
  )
from public.money_splits s
join public.money_transactions t on t.id = s.transaction_id
where t.context_actor_id is not null
  and public._ledger_entry_type_for(t.transaction_type, s.split_role) is not null
  and not exists (
    select 1 from public.ledger_entries le
    where le.transaction_id = t.id
      and le.metadata->>'source_split_id' = s.id::text
  );

-- Nota R.9.D sobre views: actor_money_balances (r4c) agrega sobre entry_type
-- ya materializado en ledger_entries — no replica el CASE de mapeo, así que
-- no necesita redefinición. No existe ninguna otra view viva que derive
-- entry_type (verificado contra la cadena MVP2 completa).

-- ────────────────────────────────────────────────────────────────────────────
-- 7. Smoke
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_r9_d_ledger_complete()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid;
  v_ctx uuid;
  v_res jsonb;
  v_fine_txn uuid; v_exp_txn uuid; v_settle_txn uuid;
  v_game_txn uuid; v_contrib_txn uuid;
  v_batch_id uuid; v_item_id uuid;
  v_pool_account uuid; v_pool_actor uuid;
  v_cnt int; v_cnt2 int;
  v_pre int; v_post int;
  v_a_bal numeric; v_b_bal numeric;
begin
  -- ═══ Mundo: A (admin) + B (miembro) en un contexto ═══
  v_a := public._create_person_actor_for_auth_user(v_auth_a, '_smoke_r9d A', '+520000000990', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, '_smoke_r9d B', '+520000000991', null);

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_r9d Familia', 'collective', 'family')->>'context_actor_id')::uuid;
  perform public.invite_member(v_ctx, v_b);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_auth_a::text)::text, true);

  -- ═══ M1: combinaciones no mapeadas devuelven null (contrato r4c C7) ═══
  if public._ledger_entry_type_for('expense', 'excluded') is not null
     or public._ledger_entry_type_for('other', 'payer') is not null
     or public._ledger_entry_type_for('settlement', 'role_inventado') is not null then
    raise exception 'r9_d M1: las combinaciones no mapeadas deben devolver null';
  end if;

  -- ═══ F: record_fine (ancla R.9.B type=other + splits debtor/creditor)
  --        → filas de ledger ═══
  v_res := public.record_fine(v_ctx, v_b, 50, 'USD', 'multa r9d');
  v_fine_txn := (v_res->>'transaction_id')::uuid;
  if v_fine_txn is null then
    raise exception 'r9_d F1: record_fine no devolvió transaction_id';
  end if;
  select count(*) filter (where entry_type = 'debit'  and actor_id = v_b   and amount = 50),
         count(*) filter (where entry_type = 'credit' and actor_id = v_ctx and amount = 50)
    into v_cnt, v_cnt2
    from public.ledger_entries
   where transaction_id = v_fine_txn and currency = 'USD';
  if v_cnt <> 1 or v_cnt2 <> 1 then
    raise exception 'r9_d F2: multa esperaba 1 debit (multado) + 1 credit (contexto), got % + %', v_cnt, v_cnt2;
  end if;

  -- ═══ E: gasto 100 MXN entre A y B (deja deuda B→A 50) ═══
  v_res := public.record_expense(v_ctx, 100, 'MXN', 'Cena r9d', p_split_with := array[v_a, v_b]);
  v_exp_txn := (v_res->>'transaction_id')::uuid;
  select count(*) into v_cnt from public.ledger_entries where transaction_id = v_exp_txn;
  if v_cnt <> 3 then
    raise exception 'r9_d E1: gasto esperaba 3 filas de ledger (payer + self-share + debtor), got %', v_cnt;
  end if;

  -- split 'excluded' sigue sin emitir fila (contrato r4c C7)
  select count(*) into v_pre from public.ledger_entries where transaction_id = v_exp_txn;
  insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
  values (v_exp_txn, v_a, 'excluded', 0.01, 'MXN');
  select count(*) into v_post from public.ledger_entries where transaction_id = v_exp_txn;
  if v_post <> v_pre then
    raise exception 'r9_d E2: split excluded emitió fila de ledger (pre=% post=%)', v_pre, v_post;
  end if;

  -- ═══ S: ciclo completo de settlement con handshake 2-way (r5z) ═══
  v_res := public.generate_settlement_batch(v_ctx, 'MXN');
  v_batch_id := (v_res->>'batch_id')::uuid;
  select count(*) into v_cnt from public.settlement_items
   where settlement_batch_id = v_batch_id and status = 'pending';
  if v_cnt <> 1 then
    raise exception 'r9_d S1: esperaba 1 settlement item pendiente, got %', v_cnt;
  end if;
  select id into v_item_id from public.settlement_items
   where settlement_batch_id = v_batch_id and status = 'pending';

  -- el deudor (B) marca pagado → pending_confirmation, todavía SIN transaction
  -- (también valida el fix del CHECK de settlement_items.status)
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_res := public.mark_settlement_paid(v_item_id);
  if (v_res->>'status') is distinct from 'pending_confirmation' then
    raise exception 'r9_d S2: el claim del deudor no quedó pending_confirmation (got %)', v_res->>'status';
  end if;
  if exists (select 1 from public.money_transactions
              where context_actor_id = v_ctx and transaction_type = 'settlement') then
    raise exception 'r9_d S3: el claim del deudor no debe crear la transaction todavía';
  end if;

  -- el acreedor (A) confirma → transaction settlement + splits sintéticos + ledger
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_res := public.confirm_settlement_paid(v_item_id);
  v_settle_txn := (v_res->>'transaction_id')::uuid;
  if v_settle_txn is null then
    raise exception 'r9_d S4: confirm_settlement_paid no devolvió transaction_id';
  end if;
  if not coalesce((v_res->>'batch_finalized')::boolean, false) then
    raise exception 'r9_d S5: el batch no quedó finalized tras el único pago';
  end if;
  select count(*) filter (where entry_type = 'credit' and actor_id = v_b and amount = 50),
         count(*) filter (where entry_type = 'debit'  and actor_id = v_a and amount = 50)
    into v_cnt, v_cnt2
    from public.ledger_entries
   where transaction_id = v_settle_txn and currency = 'MXN';
  if v_cnt <> 1 or v_cnt2 <> 1 then
    raise exception 'r9_d S6: settlement esperaba credit del deudor + debit del acreedor, got % + %', v_cnt, v_cnt2;
  end if;

  -- tras liquidar, los balances MXN de A y B vuelven a 0
  select net_balance into v_a_bal from public.actor_money_balances
   where context_actor_id = v_ctx and actor_id = v_a and currency = 'MXN';
  select net_balance into v_b_bal from public.actor_money_balances
   where context_actor_id = v_ctx and actor_id = v_b and currency = 'MXN';
  if coalesce(v_a_bal, -1) <> 0 or coalesce(v_b_bal, -1) <> 0 then
    raise exception 'r9_d S7: tras settlement los balances MXN deben ser 0 (A=% B=%)', v_a_bal, v_b_bal;
  end if;

  -- ═══ G: game_result (variante winner/loser de R.2H) → ledger ═══
  v_res := public.record_game_result(v_ctx, null::uuid, 'Backgammon r9d', v_a, v_b, 20, 'MXN');
  v_game_txn := (v_res->>'transaction_id')::uuid;
  select count(*) filter (where entry_type = 'debit'  and actor_id = v_b and amount = 20),
         count(*) filter (where entry_type = 'credit' and actor_id = v_a and amount = 20)
    into v_cnt, v_cnt2
    from public.ledger_entries
   where transaction_id = v_game_txn and currency = 'MXN';
  if v_cnt <> 1 or v_cnt2 <> 1 then
    raise exception 'r9_d G1: game_result esperaba debit perdedor + credit ganador, got % + %', v_cnt, v_cnt2;
  end if;

  -- ═══ P: pool + contribute_to_pool (cash) → splits sintéticos + ledger ═══
  v_res := public.create_pool(v_ctx, 'Bote r9d', 'equal_share', p_currency := 'MXN');
  v_pool_account := (v_res->>'pool_account_id')::uuid;
  v_pool_actor := (v_res->>'pool_actor_id')::uuid;
  perform public.contribute_to_pool(v_pool_account, 'cash', 100, 'MXN');
  select id into v_contrib_txn from public.money_transactions
   where context_actor_id = v_ctx and transaction_type = 'contribution';
  if v_contrib_txn is null then
    raise exception 'r9_d P1: contribute_to_pool (cash) no creó money_transaction';
  end if;
  select count(*) filter (where entry_type = 'credit' and actor_id = v_a and amount = 100),
         count(*) filter (where entry_type = 'debit'  and actor_id = v_pool_actor and amount = 100)
    into v_cnt, v_cnt2
    from public.ledger_entries
   where transaction_id = v_contrib_txn and currency = 'MXN';
  if v_cnt <> 1 or v_cnt2 <> 1 then
    raise exception 'r9_d P2: contribución esperaba credit contribuyente + debit pool, got % + %', v_cnt, v_cnt2;
  end if;

  -- ═══ Z: doble entrada — suma firmada 0 por (contexto, moneda) ═══
  -- (misma lógica de signos que la view actor_money_balances)
  if exists (
    select 1
      from public.ledger_entries
     where context_actor_id = v_ctx
     group by currency
    having abs(sum(case entry_type when 'credit' then amount else -amount end)) > 0.005
  ) then
    raise exception 'r9_d Z1: el ledger no suma cero por (contexto, moneda)';
  end if;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);

  delete from public.rule_attention_items where context_actor_id = v_ctx;
  delete from public.pool_basis_entries where pool_account_id = v_pool_account;
  delete from public.pool_accounts where id = v_pool_account;
  delete from public.settlement_items where settlement_batch_id in
    (select id from public.settlement_batches where context_actor_id = v_ctx);
  delete from public.settlement_batches where context_actor_id = v_ctx;
  delete from public.ledger_entries where context_actor_id = v_ctx;
  delete from public.money_splits where transaction_id in
    (select id from public.money_transactions where context_actor_id = v_ctx);
  delete from public.money_transactions where context_actor_id = v_ctx;
  delete from public.obligations where context_actor_id = v_ctx;
  delete from public.context_invites where context_actor_id = v_ctx;
  delete from public.role_assignments where context_actor_id = v_ctx;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = v_ctx;
  delete from public.roles where context_actor_id = v_ctx;
  delete from public.actor_memberships where context_actor_id = v_ctx;
  delete from public.actors where id = v_pool_actor;
  delete from public.actors where id = v_ctx;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_r9_d_ledger_complete passed (M1 F E S G P Z)';
end;
$$;

revoke all on function public._smoke_mvp2_r9_d_ledger_complete() from anon;
grant execute on function public._smoke_mvp2_r9_d_ledger_complete() to service_role;
