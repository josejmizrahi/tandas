-- Rollback 00140 — drop the fundDeposit trigger + function.
-- Existing fundDeposit system_events stay (append-only); manual cleanup
-- if needed.

drop trigger if exists trg_on_ledger_entry_inserted_fund_deposit on public.ledger_entries;
drop function if exists public.on_ledger_entry_inserted_fund_deposit();
