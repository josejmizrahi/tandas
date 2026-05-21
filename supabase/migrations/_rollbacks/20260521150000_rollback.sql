-- Rollback for 20260521150000_ledger_entries_source_resource_id.sql.
-- Drops the two indexes, the FK, and the column. Safe at this point
-- because mig 00356 ONLY adds the column — no RPC, view, or trigger
-- reads it yet (mig 00359 is what wires the column into the RPC
-- writers). Existing data loses a uniformly-NULL column.

drop index if exists public.idx_ledger_group_source_resource;
drop index if exists public.idx_ledger_source_resource;

alter table public.ledger_entries
  drop constraint if exists ledger_entries_source_resource_id_fkey;

alter table public.ledger_entries
  drop column if exists source_resource_id;
