-- Rollback for 20260521153000_protected_fund_flag_xor_constraint.sql.
-- Drops the XOR CHECK. Existing data unaffected — the constraint was
-- dormant (only enforced on writes) and no Phase 1 RPC introduces
-- double-flagged rows, so there's nothing to clean up.

alter table public.resources
  drop constraint if exists resources_shared_protected_fund_xor;
