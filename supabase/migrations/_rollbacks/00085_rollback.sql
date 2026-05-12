-- Rollback for 00085 — drops the inherited rules RPC. Existing rules
-- remain intact; only the convenience query path is removed.

drop function if exists public.list_event_rules_with_inherited(uuid);
