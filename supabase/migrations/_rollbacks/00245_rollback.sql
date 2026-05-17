-- Rollback for 00245_publish_rule_composition.sql.

drop function if exists public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text);
