-- Rollback for 00102 — drops the scope exclusion check.

alter table public.rules drop constraint if exists rules_scope_exclusion;
