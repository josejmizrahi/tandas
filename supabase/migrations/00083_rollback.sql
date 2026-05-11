-- Rollback for 00083 — drops create_event_rule RPC. Rules already created
-- via the RPC remain; only the write path is removed.

drop function if exists public.create_event_rule(uuid, uuid, text, jsonb, jsonb, jsonb);
