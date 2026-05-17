-- Mig 00233: backfill `links` capability on every existing resource.
--
-- Fase 2 promoted `links` to Tier 0 (Plans/Active/CapabilityTiers.md §2 +
-- Plans/Active/ResourceLinks.md §6). Every resource is a node of the
-- polymorphic graph, so the surface that lets the user see and edit
-- the resource's in/out edges has to appear everywhere — including
-- resources created before this migration.
--
-- Idempotent. Future resources pick `links` up via the builders'
-- `withTierDefaults()` merge (CapabilityCatalog.tier0CapabilityIds
-- now lists "links").
--
-- `enabled_by` sourced from `resources.created_by` to preserve
-- provenance — same pattern mig 00231 used for the Fase 1 backfill.

BEGIN;

INSERT INTO public.resource_capabilities (
  resource_id, capability_block_id, config, enabled,
  enabled_at, enabled_by
)
SELECT
  r.id,
  'links',
  '{}'::jsonb,
  true,
  now(),
  r.created_by
FROM public.resources r
WHERE r.archived_at IS NULL
ON CONFLICT (resource_id, capability_block_id) DO NOTHING;

DO $$
declare v_count int;
begin
  select count(*) into v_count
    from public.resource_capabilities
   where capability_block_id = 'links' AND enabled;
  raise notice 'mig 00233: % resources now expose the links capability', v_count;
end;
$$;

COMMIT;
