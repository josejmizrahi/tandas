-- 00102 — Enforce scope axis exclusion on public.rules.
--
-- Audit task M.14. The rules table grew to five scope axes (group, module,
-- series, resource, membership) post-00071 + 00078 but nothing prevents a
-- writer from setting both resource_id and series_id on the same row.
-- Occurrences ARE resources per Taxonomy §1.4, so a rule that targets a
-- specific occurrence sets resource_id (no series_id); a rule that targets
-- every occurrence of a recurring series sets series_id (no resource_id).
-- The two are mutually exclusive on the same axis.
--
-- module_key may coexist with resource_id (a per-instance override that
-- still claims module ownership for archive cascade). membership_id is the
-- orthogonal "per-member deviation" axis and may coexist with any other.
--
-- The constraint is added NOT VALID first and then VALIDATED to surface
-- existing violations as a clear error rather than a silent CHECK failure
-- on the next INSERT.

do $$
declare
  bad_count int;
begin
  select count(*) into bad_count
    from public.rules
   where resource_id is not null
     and series_id   is not null;
  if bad_count > 0 then
    raise exception
      'cannot add rules_scope_exclusion: % rule(s) have both resource_id and series_id set; reconcile data before re-running this migration',
      bad_count;
  end if;
end $$;

alter table public.rules
  add constraint rules_scope_exclusion
  check (resource_id is null or series_id is null)
  not valid;

alter table public.rules validate constraint rules_scope_exclusion;

comment on constraint rules_scope_exclusion on public.rules is
  'A rule cannot be both occurrence-scoped (resource_id) and series-scoped (series_id) at once. Occurrences are resources per Taxonomy §1.4; series-wide rules omit resource_id. module_key and membership_id are orthogonal axes and may coexist.';
