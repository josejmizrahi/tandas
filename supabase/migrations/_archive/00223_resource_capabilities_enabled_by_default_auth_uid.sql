-- Mig 00222 — resource_capabilities.enabled_by defaults to auth.uid().
--
-- Bug
-- ===
-- Mig 00190 added NOT NULL on resource_capabilities.enabled_by but did
-- not set a column default. The iOS client (LiveResourceCapabilityRepo
-- .enable) upserts the row without supplying enabled_by, so every
-- ManageCapabilitiesSheet "Activar" tap raised:
--
--   null value in column "enabled_by" of relation
--   "resource_capabilities" violates not-null constraint
--
-- Surfaced 2026-05-15 when users tried to enable the `ledger` capability
-- on funds and other resource types — blocked all manual capability
-- enablement (and therefore expense recording on resources whose group
-- did not auto-seed the `ledger` block via active modules).
--
-- Fix
-- ===
-- Set DEFAULT auth.uid() on enabled_by so the client-side insert path
-- works without the Swift layer having to thread the user id through
-- the repo protocol. Existing rows are unaffected. Server-side RPCs
-- that explicitly pass enabled_by (seed_event_default_capabilities,
-- mig 00221) continue to work — the default only applies when the
-- column is omitted from INSERT.
--
-- RLS policy (resource_capabilities_write_admin) is unchanged; the
-- write-check still verifies the caller is a group admin via the
-- resource's group_id.

alter table public.resource_capabilities
  alter column enabled_by set default auth.uid();

comment on column public.resource_capabilities.enabled_by is
  'User who enabled this capability. Defaulted to auth.uid() (mig 00222) so client-side inserts that omit the column still satisfy the NOT NULL constraint added in mig 00190.';
