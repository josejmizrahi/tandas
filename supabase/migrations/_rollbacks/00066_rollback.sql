-- 00066 rollback — Strip defaultModules / defaultRoles / defaultRules
-- from `shared_resource`. Restores the pre-00066 state where the
-- template existed but had no defaults.
--
-- Groups that were already created from this template keep their
-- per-group rules / roles intact (the template config is consulted
-- only at group creation time via seed_template_rules + analogous
-- defaultRoles/defaultModules application). So this rollback only
-- affects future onboarding flows.

update public.templates
set config = (config - 'defaultModules' - 'defaultRoles' - 'defaultRules')
where id = 'shared_resource';
