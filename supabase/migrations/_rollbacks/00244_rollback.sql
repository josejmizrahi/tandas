-- Rollback for 00244_list_rule_templates_resource_type_filter.sql.
--
-- Postgres treats list_rule_templates() and list_rule_templates(text)
-- as different overloads (different identity arguments) when the second
-- one has a default. DROP the new 1-arg signature explicitly to avoid
-- leaving both around, then restore the original 0-arg body.

drop function if exists public.list_rule_templates(text);

create or replace function public.list_rule_templates()
returns setof public.rule_templates
language sql
security invoker
stable
set search_path = public
as $$
  select *
  from public.rule_templates
  where status = 'active'
  order by sort_order, display_name_es;
$$;

revoke execute on function public.list_rule_templates() from public, anon;
grant  execute on function public.list_rule_templates() to authenticated;
