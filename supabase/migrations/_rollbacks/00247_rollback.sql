-- Rollback for 00247_bump_rule_version.sql.

drop function if exists public.bump_rule_version(uuid, text, jsonb, jsonb, jsonb, text);
