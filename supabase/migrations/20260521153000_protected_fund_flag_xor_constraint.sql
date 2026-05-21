-- 00358 — Protected fund flag forward-compat + XOR constraint
-- (SharedMoney Phase 1, brick 3).
--
-- Why
-- ===
-- Shared Money doctrine (founder 2026-05-21, doctrine_shared_money.md)
-- has TWO classes of fund-typed resource rows:
--
--   * Shared pool (metadata.is_shared_pool=true): the canonical group
--     economy. Seeded by mig 00357. At most one per group.
--
--   * Protected fund (metadata.is_protected_fund=true): an explicit
--     advanced surface for cases where patrimonial separation actually
--     matters (fideicomiso, inversión, reserva legal, emergency
--     reserve formal). UX lands in Phase 6.
--
-- These two are mutually exclusive — a fund row can be one OR the
-- other OR neither (a legacy fund pre-doctrine), but never BOTH.
-- Without an explicit invariant, future RPCs that toggle these flags
-- could land in an undefined state.
--
-- This brick:
--   * Adds a CHECK constraint enforcing the XOR for `resource_type =
--     'fund'` rows.
--   * Documents the `is_protected_fund` convention as the data model
--     entry point for Phase 6's Advanced / Protected Funds UI.
--
-- It does NOT:
--   * Add any RPC to set/unset is_protected_fund (Phase 6 surface).
--   * Add a partial unique index on protected funds (no uniqueness
--     constraint applies — a group can legitimately have N protected
--     funds for different separated purposes).
--   * Touch existing data. Pre-flight audit 2026-05-21: 6 fund rows
--     in prod, 0 with either flag → CHECK applies clean.
--
-- Why forward-compat in Phase 1 instead of Phase 6
-- ================================================
-- Establishing the invariant now means Phase 6 cannot accidentally
-- introduce double-flagged rows when it ships the Protected Funds
-- create flow. The cost is one tiny CHECK constraint added during a
-- quiet phase — cheaper than rolling out a constraint later when
-- production already contains conflicting data.
--
-- Rollback
-- ========
-- _rollbacks/20260521153000_rollback.sql drops the CHECK. Safe — no
-- code depends on the constraint's existence (only on its semantic
-- invariant, which is dormant until Phase 6 RPCs land).

alter table public.resources
  add constraint resources_shared_protected_fund_xor
  check (
    resource_type <> 'fund'
    or coalesce(metadata->>'is_shared_pool', '')   <> 'true'
    or coalesce(metadata->>'is_protected_fund', '') <> 'true'
  );

comment on constraint resources_shared_protected_fund_xor on public.resources is
  'SharedMoney Phase 1 (mig 00358): a fund row may have metadata.is_shared_pool=true XOR metadata.is_protected_fund=true XOR neither — never both. Protected funds (Phase 6) are the explicit advanced surface for patrimonial separation; shared pool (mig 00357) is the canonical group economy.';
