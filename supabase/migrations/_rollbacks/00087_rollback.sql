-- 00087_rollback.sql — drop the group_policies table.
-- CASCADE removes the trigger, RLS policies, and indexes automatically.

drop table if exists public.group_policies cascade;
