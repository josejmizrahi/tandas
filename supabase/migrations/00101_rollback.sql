-- Rollback for 00101 — drops the atomic submit RPC. iOS builders
-- continue to work via their pre-X4 N-call orchestration.

drop function if exists public.build_resource_from_draft(uuid, text, jsonb, text[], jsonb, jsonb, jsonb);
