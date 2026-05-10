-- 00073 rollback — Drop seed_module_rules + archive_module_rules.
--
-- Safe before 00074 (which calls these from set_group_module). After
-- 00074 ships, rolling back this migration without rolling back 00074
-- will break module toggling.

drop function if exists public.seed_module_rules(uuid, text);
drop function if exists public.archive_module_rules(uuid, text);
