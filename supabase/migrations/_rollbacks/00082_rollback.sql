-- Rollback for 00082 — drops record_ledger_entry RPC. Ledger entries
-- written via the RPC remain (append-only invariant).

drop function if exists public.record_ledger_entry(uuid, uuid, text, bigint, uuid, uuid, text, jsonb);
