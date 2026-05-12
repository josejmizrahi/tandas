-- Rollback for 00105 — drops the version-bump trigger and function.

drop trigger if exists templates_bump_version on public.templates;
drop function if exists public.templates_bump_version();
