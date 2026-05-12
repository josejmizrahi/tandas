-- 00071 rollback — Drop scope columns added by 00071.
--
-- Safe before 00072+ ship. After 00072 (provided_rules_def backfill)
-- this rollback DROPS that data — re-running 00072 idempotently
-- restores it. After 00075 (rules backfill) this rollback also drops
-- the module_key annotations on existing rules — those are recoverable
-- by re-running 00075.

drop index if exists public.idx_rules_group_module;
drop index if exists public.idx_rules_resource_id;
drop index if exists public.idx_rules_module_key;

alter table public.rules
  drop column if exists resource_id,
  drop column if exists module_key;

alter table public.modules
  drop column if exists provided_rules_def;
