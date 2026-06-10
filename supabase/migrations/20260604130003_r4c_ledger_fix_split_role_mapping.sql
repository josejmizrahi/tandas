-- =============================================================================
-- R.4C fix: ledger split_role mapping must include all roles emitted by the
-- existing record_expense / mark_settlement_paid implementations:
--   - expense.debtor   = third-party who owes (in addition to beneficiary)
--   - payment.payer    = the actor making the payment
--   - payment.debtor   = legacy name for payer (preserved)
-- Without these, double-entry sum across actors is non-zero (audit showed
-- a -499,333.33 imbalance after the first backfill).
-- =============================================================================

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

  v_entry_type := case
    -- expense: payer fronted money (credit), beneficiaries and 3rd-party
    -- debtors took benefit (debit).
    when v_txn.transaction_type = 'expense' and new.split_role = 'payer'       then 'credit'
    when v_txn.transaction_type = 'expense' and new.split_role = 'beneficiary' then 'debit'
    when v_txn.transaction_type = 'expense' and new.split_role = 'debtor'      then 'debit'
    -- payment: the actor paying (payer/debtor) reduces what they owe (credit
    -- moves their net toward 0); the actor being paid (creditor) reduces what
    -- they're owed (debit).
    when v_txn.transaction_type = 'payment' and new.split_role = 'payer'       then 'credit'
    when v_txn.transaction_type = 'payment' and new.split_role = 'debtor'      then 'credit'
    when v_txn.transaction_type = 'payment' and new.split_role = 'creditor'    then 'debit'
    -- Unknown combinations are silently ignored. Future transaction types
    -- (settlement, payout, fine) can be added here.
    else null
  end;

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

-- Re-backfill cleanly. ledger_entries has no FK dependents, so TRUNCATE is safe.
truncate public.ledger_entries;

insert into public.ledger_entries (
  context_actor_id, transaction_id, actor_id, entry_type, amount, currency,
  occurred_at, metadata
)
select
  t.context_actor_id, t.id, s.actor_id,
  case
    when t.transaction_type = 'expense' and s.split_role = 'payer'       then 'credit'
    when t.transaction_type = 'expense' and s.split_role = 'beneficiary' then 'debit'
    when t.transaction_type = 'expense' and s.split_role = 'debtor'      then 'debit'
    when t.transaction_type = 'payment' and s.split_role = 'payer'       then 'credit'
    when t.transaction_type = 'payment' and s.split_role = 'debtor'      then 'credit'
    when t.transaction_type = 'payment' and s.split_role = 'creditor'    then 'debit'
  end as entry_type,
  s.amount, s.currency, t.occurred_at,
  jsonb_build_object(
    'transaction_type', t.transaction_type,
    'split_role', s.split_role,
    'source_split_id', s.id,
    'backfill', true
  )
from public.money_splits s
join public.money_transactions t on t.id = s.transaction_id
where t.context_actor_id is not null
  and case
        when t.transaction_type = 'expense' and s.split_role = 'payer'       then true
        when t.transaction_type = 'expense' and s.split_role = 'beneficiary' then true
        when t.transaction_type = 'expense' and s.split_role = 'debtor'      then true
        when t.transaction_type = 'payment' and s.split_role = 'payer'       then true
        when t.transaction_type = 'payment' and s.split_role = 'debtor'      then true
        when t.transaction_type = 'payment' and s.split_role = 'creditor'    then true
        else false
      end;
