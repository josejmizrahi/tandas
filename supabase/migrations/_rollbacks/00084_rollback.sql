-- Rollback for 00084 — drops rule_shapes catalog. Existing rules are not
-- affected (they store their trigger/condition/consequence config as jsonb
-- inline). The iOS form just loses its dynamic catalog source.

drop function if exists public.list_rule_shapes();
drop policy if exists "rule_shapes_read_authenticated" on public.rule_shapes;
drop table if exists public.rule_shapes;
