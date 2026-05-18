-- Rollback for 00295 — drop universal template contract columns.
-- Safe to run only if mig 00296/00297 have NOT seeded universals yet
-- (those rows reference these columns).

drop index if exists public.idx_rule_templates_canonical;
drop index if exists public.idx_rule_templates_category;
drop index if exists public.idx_rule_templates_beta_status;

alter table public.rule_templates
  drop column if exists alias_of,
  drop column if exists tests_required,
  drop column if exists supported_scopes,
  drop column if exists beta_status,
  drop column if exists conflicts_to_detect,
  drop column if exists natural_language_preview_template_es,
  drop column if exists examples_across_verticals,
  drop column if exists what_it_is_not,
  drop column if exists doctrinal_category;
