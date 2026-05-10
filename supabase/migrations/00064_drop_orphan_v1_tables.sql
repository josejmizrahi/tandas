-- 00064 — Drop orphan V1 placeholder tables.
--
-- Cleanup migration — dropped 6 tables with zero rows and zero
-- references in iOS or edge functions. Each was added during V1
-- as a "shape we'll need later" placeholder; Phase 3 (Fund / Pool /
-- Ledger) and Phase 4 (Expense) will design fresh atoms following
-- Plans/Active/AtomProjection.md, so the V1 shapes are wrong-shape
-- noise.
--
-- Verified at apply time:
--   select count(*) from <table> = 0 for each below
--   grep -rln "from('<table>\|\"<table>\"" ios/ supabase/functions/ → no hits
--
-- Tables dropped:
--   - pots / pot_entries        (V1 Pool placeholder — Phase 3 redesigns as LedgerEntry)
--   - expenses / expense_shares (V1 Expense placeholder — Phase 4 redesigns)
--   - payments                  (V1 Payment placeholder — folded into LedgerEntry/Settlement)
--   - vote_ballots              (legacy V1 vote table, replaced by vote_casts in mig 00020)
--
-- Rollback recreates the tables as empty shells with their original
-- columns; data is unrecoverable from this migration's drop because
-- there was none.

drop table if exists public.pot_entries cascade;
drop table if exists public.pots cascade;
drop table if exists public.expense_shares cascade;
drop table if exists public.expenses cascade;
drop table if exists public.payments cascade;
drop table if exists public.vote_ballots cascade;
