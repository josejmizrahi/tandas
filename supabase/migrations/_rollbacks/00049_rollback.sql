-- Rollback for 00049_consolidate_basic_fines_module_sot.sql
--
-- Drops the trigger, sync function and check constraint. Does NOT
-- reverse the data backfill — the rows were made consistent and
-- reversing would re-introduce the silent divergence 00019 caused.
-- If pre-00049 row state is genuinely required, restore from snapshot.

alter table public.groups
  drop constraint if exists groups_basic_fines_consistent;

drop trigger if exists groups_sync_basic_fines_module on public.groups;

drop function if exists public.groups_sync_basic_fines_module();
