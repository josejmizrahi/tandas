-- Rollback for 20260524175000_mark_fund_protected.sql.
-- Drops the RPC. Existing rows with metadata.is_protected_fund=true
-- (if any) stay as inert annotation — the XOR CHECK from mig 00358
-- continues to enforce mutual-exclusion with is_shared_pool.

drop function if exists public.mark_fund_protected(uuid);
