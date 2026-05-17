-- Mig 00263: grant `expenseSubmit` to founder AND admin (post mig 00262).
--
-- Originally written when groups only had founder + member roles; main
-- shipped mig 00262 (separate_founder_from_admin) that introduces a
-- 3-role catalog (founder + admin + member) BEFORE this mig runs in
-- fresh deploys. This rewrite preserves that 3-role structure while
-- adding the missing `expenseSubmit` permission required by
-- `resolve_governance(expense.create)` when the policy is `admin_only`.
--
-- Why expenseSubmit
-- =================
-- `resolve_governance` (mig 00112) maps `expense.create` + policy_type
-- `admin_only` to the `expenseSubmit` permission. Neither founder's
-- nor admin's default permissions included it, so EVERY group with
-- expense policy `admin_only` blocked all ledger expense entries —
-- including the founder's own. Surfaced on group "Bros test"
-- (85086f6c-...) where the admin saw "Solo los fundadores pueden
-- registrar gastos" despite being founder.
--
-- Both founder and admin receive `expenseSubmit` because mig 00262's
-- doctrine says admin is the operational role; an ad-hoc admin (not
-- founder) must also be able to record expenses under admin_only.
--
-- Idempotent. Re-running is a no-op (jsonb_agg distinct + ON CONFLICT
-- semantics). The actual prod row already ran an earlier version of
-- this mig that only touched founder; the admin gap is closed by
-- mig 00269.

BEGIN;

-- ============================================================
-- 1. Column default for NEW groups: 3 roles, expenseSubmit on both
--    founder and admin. Mirrors mig 00262's structure exactly with
--    the single addition of `expenseSubmit` to both role catalogs.
-- ============================================================
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
        'expenseSubmit'
      )
    ),
    'admin', jsonb_build_object(
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

-- ============================================================
-- 2. Backfill: add expenseSubmit to every existing founder role.
-- ============================================================
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

-- ============================================================
-- 3. Backfill: add expenseSubmit to every existing admin role.
--    Mig 00262 introduced the admin role and backfilled it onto
--    existing groups (its §2 block). This adds the missing perm.
-- ============================================================
update public.groups g
   set roles = jsonb_set(
     g.roles,
     '{admin,permissions}',
     (
       select jsonb_agg(distinct p order by p)
         from jsonb_array_elements_text(
           coalesce(g.roles->'admin'->'permissions', '[]'::jsonb)
           || jsonb_build_array('expenseSubmit')
         ) as t(p)
     )
   )
 where g.roles ? 'admin'
   and g.roles->'admin' ? 'permissions';

-- ============================================================
-- 4. Audit notice
-- ============================================================
do $$
declare
  v_founder_count int;
  v_admin_count   int;
begin
  select count(*) into v_founder_count
    from public.groups
   where roles->'founder'->'permissions' ? 'expenseSubmit';
  select count(*) into v_admin_count
    from public.groups
   where roles->'admin'->'permissions' ? 'expenseSubmit';
  raise notice 'mig 00263: founder.expenseSubmit=% admin.expenseSubmit=%',
    v_founder_count, v_admin_count;
end;
$$;

COMMIT;
