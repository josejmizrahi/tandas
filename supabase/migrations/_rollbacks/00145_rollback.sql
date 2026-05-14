-- Rollback 00145 — drop record_settlement. Existing ledger_entries
-- with type='settlement' inserted via this RPC stay (append-only audit).

drop function if exists public.record_settlement(uuid, uuid, uuid, bigint, text, uuid, text);
