-- Rollback for 20260521170000_shared_money_wrapper_rpcs.sql.
-- Drops both Phase 2 wrappers. Underlying Phase 1 writers
-- (fund_contribute, fund_record_expense) untouched and remain the
-- entry points for any client that used them directly.

drop function if exists public.record_shared_expense(uuid, bigint, uuid, text, text, uuid, uuid, uuid);
drop function if exists public.contribute_to_shared_money(uuid, bigint, text, text, uuid, uuid);
