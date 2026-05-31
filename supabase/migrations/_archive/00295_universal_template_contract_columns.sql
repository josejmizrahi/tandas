-- 00295 — Universal template contract columns + alias_of self-FK.
--
-- Source: Plans/Active/UniversalRuleTemplates.md §11.2 + §14.2.
-- Background: 12 current templates leak verticality (`late_arrival_fine`,
-- `host_no_menu_fine`, `space_damage_temporary_closure_vote`, …). The
-- universal-templates doctrine reabstracts them into ~9 categories of
-- social/legal patterns (allocation, obligation, governance, …) where
-- each template applies to ≥5 verticals.
--
-- This migration is the additive substrate: new columns + self-FK so
-- mig 00296 can seed the universal templates and mig 00297 can mark the
-- current 12 as aliases (without breaking existing rule_versions that
-- already FK into them).
--
-- Doctrine alignment:
--   - Atom/projection/truth invariants untouched (no changes to rule_versions,
--     rule_evaluations, system_events).
--   - `public.rule_templates` is a curated UX catalog mirror; adding columns
--     is safe (status='active' rows continue working, list_rule_templates
--     returns `setof public.rule_templates` so new columns flow through).
--   - Feature freeze (ConsistencyAudit_2026-05-17): this is a refactor of
--     the UX catalog, not a new primitive/capability/resource_type.
--
-- Rollback: _rollbacks/00295_rollback.sql drops the new columns.

-- =============================================================================
-- 1. New columns
-- =============================================================================

alter table public.rule_templates
  add column if not exists doctrinal_category text
    not null default 'uncategorized',
  add column if not exists what_it_is_not text[]
    not null default '{}',
  add column if not exists examples_across_verticals jsonb
    not null default '[]'::jsonb,
  add column if not exists natural_language_preview_template_es text,
  add column if not exists conflicts_to_detect text[]
    not null default '{}',
  add column if not exists beta_status text
    not null default 'post_beta'
    check (beta_status in ('beta1','post_beta','never')),
  add column if not exists supported_scopes text[]
    not null default '{}',
  add column if not exists tests_required text[]
    not null default '{}',
  add column if not exists alias_of text
    references public.rule_templates(id) on delete set null;

-- =============================================================================
-- 2. Indexes
-- =============================================================================

-- Fast filter for canonical (non-aliased) templates in the Gallery query.
create index if not exists idx_rule_templates_canonical
  on public.rule_templates (sort_order, display_name_es)
  where alias_of is null and status = 'active';

-- Category browse / admin reports.
create index if not exists idx_rule_templates_category
  on public.rule_templates (doctrinal_category)
  where status = 'active';

-- Beta-status filter for "what ships in Beta 1" admin views.
create index if not exists idx_rule_templates_beta_status
  on public.rule_templates (beta_status)
  where status = 'active';

-- =============================================================================
-- 3. Comments
-- =============================================================================

comment on column public.rule_templates.doctrinal_category is
  'Universal category from Plans/Active/UniversalRuleTemplates.md §3. One of: A — Allocation, B — Capacity, C — Obligation, D — Governance, E — Access, F — Custody, G — Transfer, H — Money, I — Exception, uncategorized.';

comment on column public.rule_templates.what_it_is_not is
  'Antitemplate hints rendered as "Esto NO" on the Gallery card. Distinguishes the template from neighbouring ones (e.g. deadline_enforcement is NOT capacity_limit).';

comment on column public.rule_templates.examples_across_verticals is
  'jsonb array of {vertical, label_grupo, params}. The universality test (§2.1) requires ≥5 entries before a template is accepted into the catalog.';

comment on column public.rule_templates.natural_language_preview_template_es is
  'es-MX templated string with {{param_key}} placeholders. The iOS sentence formatter interpolates current form params into this template to render the sticky preview. NULL = fall back to legacy hardcoded formatter (for pre-mig-00295 templates).';

comment on column public.rule_templates.conflicts_to_detect is
  'Conflict signatures publish_rule_composition runs against. Empty = no template-specific conflicts (engine still checks same_scope_overlapping + consequence_missing_capability globally).';

comment on column public.rule_templates.beta_status is
  'Lifecycle marker: beta1 (ships in Beta 1 Gallery), post_beta (future waves), never (anti-patterns we''ve decided not to build).';

comment on column public.rule_templates.supported_scopes is
  'Scope levels this template can be published at — subset of {occurrence, resource, series, resource_type, capability, group, global_default}. Empty = inherits from trigger shape.';

comment on column public.rule_templates.tests_required is
  'Test fixture ids that must exist before a template can be published. CI lint blocks templates with <5 fixtures.';

comment on column public.rule_templates.alias_of is
  'When non-null: this template is an alias of `alias_of` (a more universal template). Existing rule_versions keep working via FK; iOS Gallery filters these out so users only see canonical templates. Set during the post-audit-close renaming pass (mig 00297).';
