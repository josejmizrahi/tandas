-- 00330 rollback — drop the service-role variant. Any caller using it
-- must revert to direct .from("ledger_entries").insert(...) at the same
-- transaction layer first.

drop function if exists public.record_ledger_entry_system(uuid, uuid, text, bigint, uuid, uuid, text, jsonb, timestamptz);
