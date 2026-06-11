-- ============================================================================
-- AUDIT.17 — Invariante contable de splits en la base (2026-06-11)
-- ============================================================================
-- Recomendación §4 de la revisión de escalabilidad: hoy "sum(splits) cuadra
-- con la transacción" lo garantizan los RPCs; nada impide que un bug futuro
-- lo rompa en silencio y los balances del ledger queden corruptos.
--
-- Invariante empírico verificado contra TODA la data viva (30 txns, todos los
-- flujos: expense equal/custom/weighted, fine, settlement, game_result):
--     sum(money_splits.amount) = 2 × money_transactions.amount
-- (la pata de quien paga + la pata de quien debe/recibe, ambas positivas;
-- los rows con split_role='excluded' aportan 0).
--
-- Se codifica como CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED sobre
-- money_splits: cada RPC inserta txn+splits en una sola transacción de BD,
-- así que la validación corre al COMMIT con el conjunto completo.
-- Verificación: suite _smoke_mvp2_* COMPLETA en live (cubre también pools R8
-- y el handshake de settlement) tras aplicar.
-- Rollback: drop trigger trg_money_splits_invariant + drop function.
-- ============================================================================

create or replace function public._money_splits_check_invariant()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_txn_id uuid := coalesce(NEW.transaction_id, OLD.transaction_id);
  v_amount numeric;
  v_sum numeric;
begin
  select t.amount into v_amount
    from public.money_transactions t where t.id = v_txn_id;
  if v_amount is null then
    return null; -- la txn ya no existe (cascade en cleanup de smokes)
  end if;

  select coalesce(sum(s.amount), 0) into v_sum
    from public.money_splits s where s.transaction_id = v_txn_id;

  if v_sum <> 2 * v_amount then
    raise exception 'money_splits invariant: sum(splits)=% para la transacción % (amount=%); se esperaba 2×amount=%',
      v_sum, v_txn_id, v_amount, 2 * v_amount
      using errcode = '23514',
      hint = 'cada transacción lleva la pata del pagador y la pata de los deudores/beneficiarios, ambas sumando amount';
  end if;
  return null;
end;
$$;

drop trigger if exists trg_money_splits_invariant on public.money_splits;
create constraint trigger trg_money_splits_invariant
  after insert or update or delete on public.money_splits
  deferrable initially deferred
  for each row
  execute function public._money_splits_check_invariant();

comment on function public._money_splits_check_invariant() is
  'AUDIT.17: invariante contable sum(splits) = 2×amount por transacción, validado al COMMIT (deferred). La base garantiza lo que antes solo garantizaban los RPCs.';
