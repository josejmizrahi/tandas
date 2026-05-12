-- Rollback for 00107 — reverts view to security_definer and functions
-- to mutable search_path. Not recommended; advisor flags reappear.

alter view public.resources_view set (security_invoker = false);

create or replace function public.atom_no_mutation_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' then
    raise exception 'atom row %.% is append-only; UPDATE rejected',
      tg_table_schema, tg_table_name using errcode = 'check_violation';
  end if;
  if tg_op = 'DELETE' then
    raise exception 'atom row %.% is append-only; DELETE rejected',
      tg_table_schema, tg_table_name using errcode = 'check_violation';
  end if;
  return null;
end $$;

create or replace function public.templates_bump_version()
returns trigger
language plpgsql
as $$
begin
  if new.config is distinct from old.config
     or new.name is distinct from old.name
     or new.description is distinct from old.description
     or new.icon is distinct from old.icon
     or new.available is distinct from old.available
  then
    new.version := old.version + 1;
  end if;
  return new;
end $$;
