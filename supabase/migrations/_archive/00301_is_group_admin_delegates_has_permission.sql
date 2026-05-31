-- 00301 — V23 close: is_group_admin delegates to has_permission(modifyGovernance).
--
-- Plans/Active/RolesRemediation_2026-05-17.md V23 (TRANSITIONAL DEBT).
-- RLS Phase 5 rewire — without touching ~50 individual policies.
--
-- Background
-- ==========
-- 50+ RLS policies + several RPCs gate on `is_group_admin(gid, uid)`.
-- Mig 00299 already eliminated its dependence on the deprecated role
-- text column by reading `roles ? 'admin' OR roles ? 'founder'` from
-- the jsonb. That fix kept the semantic "is in the admin role set".
--
-- Doctrinal final move: shift the SEMANTIC from "has admin/founder role
-- in roles[]" to "has modifyGovernance permission anywhere in their role
-- bundle". Net behavior is identical for the existing data (admin +
-- founder default catalog entries both grant modifyGovernance), with
-- one principled improvement:
--   - Custom roles that grant modifyGovernance now correctly count as
--     admin-equivalent (today they don't unless named exactly "admin"
--     or "founder").
--   - A custom role with id "admin" that DOESN'T grant modifyGovernance
--     correctly does NOT count as admin (today it would, which is wrong).
--
-- Single-function rewrite — every RLS + RPC caller picks up the new
-- semantics transparently. No signature change.
--
-- Naming: the function is now a misnomer (it really means "has
-- modifyGovernance capability"). A V23.2 rename to `has_admin_capability`
-- or similar can ship once we've validated no breakage; for now the
-- compat name avoids cascading every caller.

create or replace function public.is_group_admin(gid uuid, uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.has_permission(gid, uid, 'modifyGovernance');
$$;

comment on function public.is_group_admin(uuid, uuid) is
  'v3 (mig 00301): delegates to has_permission(gid, uid, ''modifyGovernance''). V23 close — every RLS policy + RPC gating on this function now resolves via the canonical permission resolver. Custom roles that grant modifyGovernance count; custom roles named "admin" without the perm correctly don''t. Name is preserved for compat; V23.2 may rename to has_admin_capability.';
