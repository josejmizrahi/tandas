-- 00107 — Harden audit artifacts per Supabase advisor.
--
-- Post-apply advisors flagged three lints introduced by 00103-00105:
--
--   1. resources_view (00104) — security_definer_view (ERROR)
--      Postgres creates views with the creator's permissions by default,
--      bypassing the caller's RLS. Switch to SECURITY INVOKER so
--      resources/resource_series/resource_capabilities RLS still gates
--      access through the view.
--
--   2. atom_no_mutation_guard (00103) — function_search_path_mutable (WARN)
--   3. templates_bump_version  (00105) — function_search_path_mutable (WARN)
--      Functions without an explicit search_path inherit the caller's,
--      which is a soft injection vector. Pin to `public, pg_catalog` so
--      the function always resolves its own table references.
--
-- Three pre-existing views (invite_preview, group_members_with_founder,
-- events_view, vote_counts_view) carry the same security_definer_view
-- lint but predate this audit; not retrofitting them here so the
-- migration stays scoped to objects this audit shipped.

-- 1. resources_view — SECURITY INVOKER
alter view public.resources_view set (security_invoker = true);

-- 2. atom_no_mutation_guard — pinned search_path
create or replace function public.atom_no_mutation_guard()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
begin
  if tg_op = 'UPDATE' then
    raise exception
      'atom row %.% is append-only; UPDATE rejected',
      tg_table_schema, tg_table_name
      using errcode = 'check_violation';
  end if;
  if tg_op = 'DELETE' then
    raise exception
      'atom row %.% is append-only; DELETE rejected',
      tg_table_schema, tg_table_name
      using errcode = 'check_violation';
  end if;
  return null;
end $$;

-- 3. templates_bump_version — pinned search_path
create or replace function public.templates_bump_version()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
begin
  if new.config       is distinct from old.config
     or new.name        is distinct from old.name
     or new.description is distinct from old.description
     or new.icon        is distinct from old.icon
     or new.available   is distinct from old.available
  then
    new.version := old.version + 1;
  end if;
  return new;
end $$;
