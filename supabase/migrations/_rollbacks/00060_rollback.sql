-- 00060 rollback — Drop modules table + list_modules RPC.
--
-- WARNING: only safe AFTER 00061 is also rolled back. 00061 rewires
-- set_group_module to consult public.modules; rolling back 00060
-- alone would leave the function querying a missing table.

drop function if exists public.list_modules();

drop table if exists public.modules;
