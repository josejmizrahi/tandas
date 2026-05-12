-- Rollback for 00021_templates_table.sql

drop policy if exists templates_select_all on public.templates;
drop trigger  if exists templates_set_updated_at on public.templates;
drop table    if exists public.templates;
