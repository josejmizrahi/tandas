-- 00071 — Add module/resource scope columns to rules + provided_rules_def to modules.
--
-- Closes Hallazgo 1 from L1 audit (Plans/Active/L1_Audit_2026-05-10.md):
-- rules today carry only `group_id` as scope. Three problems:
--
--   1. Activating a module post-onboarding never seeds its rules
--      (set_group_module only updates groups.active_modules array).
--   2. Disabling a module leaves its rules zombie in the rules table.
--   3. No storage for per-instance overrides (e.g. one Trip with
--      different cancellation policy than the group default).
--
-- Three-level rule scope going forward:
--
--   A. Group-level rules → `groups.governance` jsonb (already in place,
--      no change here). Quorum, thresholds, who-can-X permissions.
--
--   B. Module-level rules → `public.rules` with `module_key` set,
--      `resource_id` null. Seeded by `seed_module_rules(group, slug)`
--      on module enable; archived by `archive_module_rules` on disable.
--      (RPCs land in 00073, set_group_module cascade in 00074.)
--
--   C. Resource-instance overrides → `public.rules` with `resource_id`
--      set. Created by callers when a specific resource needs a
--      deviation. May also carry `module_key` ("this resource's copy of
--      basic_fines.dinner_late_arrival, but with a custom amount").
--      Cascades on resource delete.
--
-- This migration is PURELY ADDITIVE — no behavior change yet. Follow-ups:
--   - 00072 backfill modules.basic_fines.provided_rules_def from the
--     dinner rule definitions currently living in templates.
--   - 00073 seed_module_rules + archive_module_rules RPCs.
--   - 00074 set_group_module rule-cascade extension.
--   - 00075 backfill module_key on existing rules rows.

-- =========================================================
-- 1. rules: add module_key + resource_id
-- =========================================================
alter table public.rules
  add column if not exists module_key  text null,
  add column if not exists resource_id uuid null
    references public.resources(id) on delete cascade;

create index if not exists idx_rules_module_key
  on public.rules(module_key)
  where module_key is not null;

create index if not exists idx_rules_resource_id
  on public.rules(resource_id)
  where resource_id is not null;

create index if not exists idx_rules_group_module
  on public.rules(group_id, module_key);

comment on column public.rules.module_key is
  'When set, this rule was seeded by module activation (set_group_module). Lifecycle bound to module enable/disable. Null = group-level or template-seeded rule with no module affinity.';
comment on column public.rules.resource_id is
  'When set, this rule is an override for a specific resource instance (e.g. one event with custom cancellation policy). Cascades on resource delete.';

-- =========================================================
-- 2. modules: add provided_rules_def jsonb
-- =========================================================
-- The full rule body lives here, keyed by slug. seed_module_rules reads
-- from this column on module enable and inserts rows into public.rules
-- with module_key = modules.id. Until now `modules.provided_rules` was
-- only an array of slugs — the actual definitions were duplicated in
-- iOS (DinnerRecurringTemplate.swift), in templates.config.defaultRules,
-- and inside seed_dinner_template_rules. This column makes modules the
-- canonical owner, eliminating the three-way drift.

alter table public.modules
  add column if not exists provided_rules_def jsonb not null default '[]'::jsonb;

comment on column public.modules.provided_rules_def is
  'Canonical rule definitions provided by this module. Array of {slug, name, isActive, trigger, conditions, consequences}. seed_module_rules(group, slug) iterates this array and inserts into public.rules with module_key = modules.id. Source of truth — replaces duplicate copies in templates.config.defaultRules and DinnerRecurringTemplate.swift.';
