-- Rollback for 00249_consequence_targets.sql.
--
-- Drops the validator + the v4 / v3 signatures. Callers must re-apply
-- mig 00248 to restore the prior bodies (which accept p_exceptions
-- but NOT consequences[].target).
--
-- compiled.consequences[].target fields in existing rule_versions
-- remain (just data); engine never read them so removing the column
-- handling is a no-op.

drop function if exists public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text, text, jsonb);
drop function if exists public.bump_rule_version(uuid, text, jsonb, jsonb, jsonb, text, jsonb);
drop function if exists public.validate_consequence_target(text);
