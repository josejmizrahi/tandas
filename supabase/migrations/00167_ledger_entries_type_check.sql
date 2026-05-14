-- 00167 — CHECK constraint on ledger_entries.type (Constitution audit Gap 7).
--
-- Why
-- ===
-- Constitution Article 11: "Tabla canónica `ledger_entries` (atom
-- append-only). Tipos: `payment`, `contribution`, `reimbursement`,
-- `transfer`, `expense`, `fine_issued`, `fine_paid`, `fine_voided`,
-- `settlement`, `payout`, `fundDeposit`." But the `type` column had no
-- CHECK constraint — any text inserted would land. The doctrine was
-- teeth-less; silent drift was already happening (`fine_officialized`
-- in production data is not in Article 11's list).
--
-- Mirrors the Article 2 pattern: `resources.resource_type` has had a
-- CHECK enforcing the frozen 6 values since mig 00147. Ledger types
-- get the same treatment.
--
-- Canonical list (this migration's source of truth)
-- =================================================
-- Live data + emitters:
--   - contribution        (used; fund deposit emitter trigger reads it)
--   - expense             (used)
--   - fine_issued         (used; mig 00148)
--   - fine_officialized   (used; mig 00148+150) ← NOT in Article 11 list;
--                          added to the canonical list because it's
--                          load-bearing in production. Constitution
--                          doc reconciliation lands in a paired commit.
--   - fine_paid           (used; mig 00148)
--   - fine_voided         (used; mig 00148+150)
--   - settlement          (used; mig 00145)
--
-- Doctrine-future-reserved (per Article 11):
--   - payment
--   - reimbursement
--   - transfer
--   - payout
--
-- Article 11 also lists `fundDeposit`, but:
--   1. No code uses it (the fund-deposit SystemEvent fires off
--      ledger entries of type='contribution' with resource_type='fund').
--   2. Case style conflicts with the snake_case convention every other
--      value follows.
-- It's intentionally omitted; if the doctrine wants a distinct ledger
-- type later, a new migration can add `fund_deposit` (snake_case).
--
-- Verification (pre-deploy)
-- =========================
-- All existing rows have type IN (canonical list) — checked manually
-- via the audit query: distinct values were
--   contribution, expense, fine_issued, fine_officialized, fine_paid, settlement.
-- Each one is in the new constraint's allowed set. ALTER will not fail.
--
-- Rollback
-- ========
-- _rollbacks/00167_rollback.sql

alter table public.ledger_entries
  add constraint ledger_entries_type_canonical
  check (type in (
    'contribution',
    'expense',
    'fine_issued',
    'fine_officialized',
    'fine_paid',
    'fine_voided',
    'settlement',
    'payment',
    'reimbursement',
    'transfer',
    'payout'
  ));

comment on constraint ledger_entries_type_canonical on public.ledger_entries is
  'Constitution Article 11 enforcement. Adds the CHECK that Article 11 doctrine implied but never enforced. Future types require a new migration that ALTER ... DROP CONSTRAINT + ADD with the expanded list — same model as resource_type freeze (mig 00147).';
