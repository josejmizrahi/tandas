-- 00100_rollback.sql
-- Removes the auto-seed trigger and helper. Existing policy rows that
-- were inserted by the trigger or by the one-shot top-up stay — those
-- are real data writes equivalent to what 00090's backfill produced,
-- and we don't blow them away on rollback.

drop trigger if exists seed_policies_on_group_insert_trg on public.groups;
drop function if exists public.seed_policies_on_group_insert();
drop function if exists public.seed_default_group_policies(uuid, jsonb, uuid);
