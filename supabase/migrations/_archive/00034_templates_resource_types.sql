-- 00034 — Templates declare which resource types they instantiate.
--
-- Phase 0.5 Sub-fase E (audit § 5.1 #8). Adds `resourceTypes` array
-- to existing templates.config jsonb. V1: only `recurring_dinner`
-- which declares `["event"]`. Phase 2 `shared_resource` template
-- will declare `["slot", "position"]`.
--
-- iOS reads via TemplateConfig.resourceTypes (optional, defaults to
-- [.event] for backward compat decoding).
--
-- Behavior change V1: zero. Only metadata. Phase 2 uses it to drive
-- what HomeView renders + which create flows are available per group.

update public.templates
set config = config || jsonb_build_object('resourceTypes', jsonb_build_array('event'))
where id = 'recurring_dinner'
  and not (config ? 'resourceTypes');

-- Future templates (shared_resource, rotating_savings, etc.) get
-- their own resourceTypes when they ship. Migration is idempotent
-- via NOT (config ? 'resourceTypes') guard.
