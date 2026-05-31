-- 00290 — Backfill 'admin' into roles[] for every active member that holds
-- 'founder' but not 'admin'.
-- (Originally numbered 00289; renumbered after splitting out the
-- updated_at-column bug fix into 00289_fix_role_rpcs_updated_at_bug.sql.)
--
-- Sprint A of Plans/Active/RolesRemediation_2026-05-17.md.
-- Closes the data-layer half of V21 + V22 (RolesAudit_2026-05-17.md):
-- post-mig-00262 the role catalog gained an 'admin' entry, but no
-- per-member backfill ever ran. All historical founders still have
-- roles = ['founder', 'member'] and the iOS client + server-side
-- has_permission RPC compensate via the 'admin → founder' alias.
--
-- This migration makes the data explicit so the iOS alias (Member.swift
-- + GovernanceService + GroupHomeCoordinator + Group.roleDefinition)
-- can be removed cleanly. Server-side `has_permission` alias stays for
-- now (Sprint F cleanup) — it's harmless once data is consistent.
--
-- Idempotent: only updates rows missing 'admin'. Safe to re-run.
--
-- Atom emission: emits roleAssigned per affected member with
-- assigned_by = null and payload.cause = 'mig_00289_backfill' so
-- audit trail captures the synthetic origin.
--
-- Performance: scans active members only. Negligible at current scale
-- (low tens). At larger scale a CTE-based bulk strategy with a separate
-- atom-insertion pass would be preferable, but for now the loop is
-- clearer.

do $$
declare
  v_affected record;
  v_count    int := 0;
begin
  for v_affected in
    select gm.id, gm.group_id, gm.user_id
      from public.group_members gm
     where gm.active = true
       and coalesce(gm.roles, '[]'::jsonb) ? 'founder'
       and not (coalesce(gm.roles, '[]'::jsonb) ? 'admin')
       -- Guard against groups whose catalog doesn't have 'admin' yet.
       -- mig 00262 backfilled the catalog for all groups, but check
       -- defensively in case a custom group dropped it.
       and exists (
         select 1 from public.groups g
          where g.id = gm.group_id
            and coalesce(g.roles, '{}'::jsonb) ? 'admin'
       )
  loop
    -- service_role context bypasses guard_group_members_roles_write
    -- (mig 00287) via the auth.uid() IS NULL short-circuit. No flag
    -- needed.
    -- NOTE: group_members has no updated_at column (latent bug surfaced
    -- in mig 00289 fix). joined_at stays as the canonical mutation time.
    update public.group_members
       set roles = coalesce(roles, '[]'::jsonb) || jsonb_build_array('admin')
     where id = v_affected.id;

    perform public.record_system_event(
      v_affected.group_id,
      'roleAssigned',
      null,
      v_affected.id,
      jsonb_build_object(
        'role',         'admin',
        'user_id',      v_affected.user_id,
        'assigned_by',  null,
        'cause',        'mig_00289_backfill'
      )
    );

    v_count := v_count + 1;
  end loop;

  raise notice 'mig 00290: backfilled admin into % member rows', v_count;
end $$;
