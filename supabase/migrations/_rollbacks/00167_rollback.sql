-- Rollback for 00167_ledger_entries_type_check.sql

alter table public.ledger_entries drop constraint if exists ledger_entries_type_canonical;
