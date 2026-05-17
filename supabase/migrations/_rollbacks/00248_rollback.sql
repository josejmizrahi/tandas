-- Rollback for 00248_rule_exceptions.sql.
--
-- Drops the new 9-arg / 7-arg signatures, restores the prior 8-arg /
-- 6-arg signatures from mig 00246 / 00247. Drops the rules.exceptions
-- column (data in there gets dropped — no atom backwards-compat issue
-- since the engine doesn't read it pre-00248).

drop function if exists public.publish_rule_composition(uuid, text, jsonb, jsonb, jsonb, jsonb, text, text, jsonb);
drop function if exists public.bump_rule_version(uuid, text, jsonb, jsonb, jsonb, text, jsonb);

alter table public.rules drop column if exists exceptions;

-- Note: callers need to re-apply 00246/00247 SQL to restore the prior
-- function bodies. For an emergency rollback, apply 00246 + 00247
-- contents fresh after this rollback runs.
