-- Mig 00209: grant the 5 right-op permissions to the default founder role.
--
-- Slice 19. The Permission enum (Permission.swift) grew 5 right-op cases
-- (transferRight / delegateRight / revokeRight / suspendRight /
-- exerciseRight) so custom templates + the future Phase 5 RLS rewire
-- can reason about right governance without hard-coding role names.
--
-- This migration ensures the default founder role on every group has
-- the 5 new permissions, so:
--   - New groups created via create_group_with_admin get them via the
--     column default on `groups.roles`.
--   - Existing groups whose `roles.founder.permissions` jsonb predates
--     this slice get backfilled idempotently.
--
-- The mig 00206 RPC gate (`role in ('founder','admin')`) on
-- transfer_right / delegate_right already enforces the right policy
-- correctly for founders today; this migration is the doctrinal
-- alignment so a custom role declared by a template (e.g. "syndic"
-- or "fiduciary") that wants transfer authority just lists
-- 'transferRight' in its permissions and the server's eventual
-- has_permission gate (Phase 5) picks it up. Until then the role
-- check is the authoritative gate; the permission is the catalog.
--
-- Idempotency
-- ===========
-- Uses jsonb_set + a conditional check on the existing perms array.
-- Each value is appended only if not already present, so re-running
-- is a no-op. Founder roles without a `permissions` key (shouldn't
-- exist, mig 00063 defaults guarantee one) are skipped — those
-- would need a separate cleanup migration.

BEGIN;

-- 1. Update the column default so NEW groups get the perms.
alter table public.groups
  alter column roles set default jsonb_build_object(
    'founder', jsonb_build_object(
      'system', true,
      'permissions', jsonb_build_array(
        'modifyGovernance',
        'modifyRules',
        'modifyMembers',
        'assignRoles',
        'removeMember',
        'voidFine',
        'closeAppeal',
        'createVotes',
        -- mig 00209: right governance now part of the founder default.
        'transferRight',
        'delegateRight',
        'revokeRight',
        'suspendRight',
        'exerciseRight'
      )
    ),
    'member', jsonb_build_object(
      'system', true,
      'permissions', jsonb_build_array(
        'createVotes',
        'castVote'
      )
    )
  );

-- 2. Backfill existing groups' founder role. For each, append any of
-- the 5 right perms missing from the current permissions array.
-- jsonb_set on `permissions` path; deduplicate via a SELECT DISTINCT
-- inside the rebuild.
update public.groups g
   set roles = jsonb_set(
     g.roles,
     '{founder,permissions}',
     (
       select jsonb_agg(distinct p order by p)
         from jsonb_array_elements_text(
           coalesce(g.roles->'founder'->'permissions', '[]'::jsonb)
           || jsonb_build_array(
             'transferRight',
             'delegateRight',
             'revokeRight',
             'suspendRight',
             'exerciseRight'
           )
         ) as t(p)
     )
   )
 where g.roles ? 'founder'
   and g.roles->'founder' ? 'permissions';

-- Sanity: count how many groups now grant each right perm to founder.
-- The notice surfaces in the apply log so we can confirm the backfill
-- actually touched everything.
do $$
declare
  v_count int;
begin
  select count(*) into v_count
    from public.groups
   where roles->'founder'->'permissions' ? 'transferRight';
  raise notice 'mig 00209: % groups have founder.transferRight', v_count;
end;
$$;

COMMIT;
