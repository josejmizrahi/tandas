-- Rollback for 00086. Drops the renamed RPCs. The originals from
-- 00083/00085 still exist and continue working.

drop function if exists public.create_resource_rule(uuid, uuid, text, jsonb, jsonb, jsonb);
drop function if exists public.list_resource_rules_with_inherited(uuid);
