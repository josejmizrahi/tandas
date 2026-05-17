-- Mig 00228: grant `expenseSubmit` to the default founder role.
--
-- The policy resolver (`resolve_governance`, mig 00112) maps
-- `expense.create` + policy_type='admin_only' to the `expenseSubmit`
-- permission. The Permission enum already declares the case, but the
-- founder role catalog seeded by mig 00063 / 00128 / the column default
-- never granted it. Consequence: any group whose money policy is
-- `admin_only` blocks ALL ledger expense entries, including the
-- founder's own — `has_permission(..., 'expenseSubmit')` returns false
-- because the perm doesn't appear in `roles.founder.permissions`.
--
-- Caught while exercising the fund resource flow on "Bros test"
-- (group 85086f6c-4149-4fd4-b02d-26cafcf07b65) where the admin saw
-- "Solo los admins pueden registrar gastos" despite being founder.
--
-- Idempotency: jsonb_agg(distinct ... order by ...) on the existing
-- permissions array + append. Re-running is a no-op. Member role is
-- intentionally left untouched: `admin_only` only matters when there
-- IS a founder/member distinction, so granting expenseSubmit to
-- members would collapse the policy.

BEGIN;

-- 1. Column default for NEW groups.
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
        'transferRight',
        'delegateRight',
        'revokeRight',
        'suspendRight',
        'exerciseRight',
        -- mig 00228: expense submission gate for admin_only policy.
        'expenseSubmit'
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

-- 2. Backfill every existing group's founder.permissions array.
update public.groups g
   set roles = jsonb_set(
     g.roles,
     '{founder,permissions}',
     (
       select jsonb_agg(distinct p order by p)
         from jsonb_array_elements_text(
           coalesce(g.roles->'founder'->'permissions', '[]'::jsonb)
           || jsonb_build_array('expenseSubmit')
         ) as t(p)
     )
   )
 where g.roles ? 'founder'
   and g.roles->'founder' ? 'permissions';

-- 3. Surface the backfill count in apply log.
do $$
declare
  v_count int;
begin
  select count(*) into v_count
    from public.groups
   where roles->'founder'->'permissions' ? 'expenseSubmit';
  raise notice 'mig 00228: % groups now grant founder.expenseSubmit', v_count;
end;
$$;

COMMIT;
