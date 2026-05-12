-- 00059 rollback — Drop the restored `rules.trigger` column.
--
-- WARNING: rolling back 00059 leaves the schema in the broken
-- post-00058 state where the rule engine cannot dispatch any rule
-- (no trigger column = no eventType lookup). Only run this if you
-- intend to also roll back 00058 immediately afterwards.

alter table public.rules
  drop column if exists trigger;
