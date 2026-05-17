-- Rollback for 00250_membership_filter.sql.
--
-- Drops the v5 / v4 signatures that accept p_membership_id /
-- p_clear_membership. Re-apply mig 00249 to restore the prior bodies
-- (which accept p_exceptions + consequences[].target but NOT membership).
--
-- rules.membership_id column predates mig 00250 (added in 00078) and is
-- left intact. compiled.membership_id inside rule_versions remains as
-- data — engine read it from rules.membership_id already, so no behavior
-- change from leaving the audit field behind.

drop function if exists public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text, text, jsonb, uuid);
drop function if exists public.bump_rule_version(uuid, text, jsonb, jsonb, jsonb, text, jsonb, uuid, boolean);
