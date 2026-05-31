-- Mig 00190: Enforce resource_capabilities.enabled_by NOT NULL + backfill
--
-- Constitution: every capability enablement should have provenance. The
-- auto-seed trigger (`resources_seed_event_caps_after_insert`, mig 00096)
-- inserted rows without enabled_by, leaving 179/193 prod rows NULL.
--
-- Backfill: for NULL rows, copy the resource's `created_by`. Semantically
-- "the person who created the resource enabled the seeded capabilities".
-- After backfill, tighten the column.
--
-- Pre-existing user-driven INSERTs (admin enables a capability) already
-- pass enabled_by — those are the 14 non-NULL rows.

update public.resource_capabilities rc
   set enabled_by = r.created_by
  from public.resources r
 where rc.resource_id = r.id
   and rc.enabled_by is null;

alter table public.resource_capabilities
  alter column enabled_by set not null;

comment on column public.resource_capabilities.enabled_by is
  'Actor who enabled this capability. NOT NULL — every enablement has provenance. Auto-seed trigger sets to resources.created_by; admin path passes the caller.';
