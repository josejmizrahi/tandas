-- 00099 — Seed templates.config.defaultCapabilities (Phase X3).
--
-- Founder framing 2026-05-11: capability auto-on defaults in the
-- ResourceWizard belong to the template/preset, not to a Swift switch
-- on resource_type. mig 00021 created the templates table with a jsonb
-- `config` column; this slice extends that jsonb with a new
-- `defaultCapabilities` key without touching the schema.
--
-- Shape: `{ "<resource_type>": ["<capability_id>", …] }`. The iOS
-- `ResourceWizardCoordinator` reads
-- `template.config.defaultCapabilities[builder.resourceType.rawString]`
-- and pre-toggles those caps when the user lands on Step 3.
--
-- recurring_dinner is the only template with content today. The other
-- three placeholder templates (shared_resource, rotating_savings,
-- custom) remain `available=false` and would gain their own defaults
-- when their wizards ship.

update public.templates
   set config = config || jsonb_build_object(
         'defaultCapabilities', jsonb_build_object(
           'event', jsonb_build_array('rsvp', 'check_in', 'rotation')
         )
       ),
       updated_at = now()
 where id = 'recurring_dinner';

-- Sanity: surface the post-state so a re-run reads the seed.
select id, config->'defaultCapabilities' as default_capabilities
  from public.templates
 where id = 'recurring_dinner';
