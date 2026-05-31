-- 00135 — Tier 1.7: place `shared_no_show` rule on the right module.
--
-- Background
-- ==========
-- Pre-00075, `seed_template_rules` read `templates.config.defaultRules`
-- and bulk-inserted every rule for the group. After the L1 rules-
-- architecture refactor (00075), rules belong to MODULES (via
-- `modules.provided_rules_def`) and templates only declare WHICH
-- modules to activate. The `seed_template_rules` post-refactor
-- reads `groups.active_modules` and orchestrates `seed_module_rules`
-- per slug.
--
-- Result: `templates.shared_resource.config.defaultRules`
-- (mig 00066) contains `shared_no_show` + `shared_swap_warning`,
-- but those rule definitions are nowhere in `modules.provided_rules_def`.
-- They sit in the templates table as orphan data — the new orchestrator
-- has no path to surface them.
--
-- Real consequence (palcoSharedResource.test.ts): a `shared_resource`
-- group lands with zero rules even though both 00134's auto-call
-- AND the iOS-side explicit call invoke `seed_template_rules`.
--
-- Fix
-- ===
-- Move `shared_no_show` into `modules.slot_assignment.provided_rules_def`.
-- `slot_assignment` is the natural owner: the rule's trigger is
-- `slotExpired`, the condition is `slotIsUnassigned`, and the entire
-- semantics ("if your assigned cupo expired without anyone using it,
-- pay") lives in the slot domain. `slot_assignment` is already
-- listed in `shared_resource.defaultModules`, so the orchestrator
-- will pick it up.
--
-- The `shared_swap_warning` companion (`slotExpiresInHours` trigger)
-- stays unscheduled for now — it requires an `emit-slot-expires-in-hours`
-- cron that doesn't exist. Document as deferred; not a Tier 1.7
-- blocker.
--
-- We DO NOT remove `shared_no_show` from `templates.shared_resource.
-- config.defaultRules` — keeping it there lets a future audit tool
-- show the full rule catalog per template without joining to modules.
-- The orchestrator just ignores it now.

update public.modules
   set provided_rules_def = jsonb_build_array(
     jsonb_build_object(
       'slug',         'shared_no_show',
       'name',         'No usar el cupo asignado',
       'description',  'Multa cuando un cupo asignado expira sin que nadie lo use ni lo libere a tiempo.',
       'isActive',     true,
       'trigger',      jsonb_build_object(
         'eventType', 'slotExpired',
         'config',    '{}'::jsonb
       ),
       'conditions',   jsonb_build_array(
         jsonb_build_object('type', 'slotIsUnassigned', 'config', '{}'::jsonb)
       ),
       'consequences', jsonb_build_array(
         jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
       )
     )
   )
 where id = 'slot_assignment';

comment on column public.modules.provided_rules_def is
  'Per-module rule catalog. `seed_module_rules(group_id, slug)` reads this and inserts/upserts into public.rules with module_key=slug. 00135 placed shared_no_show on slot_assignment so the shared_resource template surfaces it via active_modules instead of relying on templates.defaultRules (orphan data post-00075).';
