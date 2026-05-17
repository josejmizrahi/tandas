-- Mig 00269: backfill `expenseSubmit` onto admin roles in prod.
--
-- Context: mig 00263 originally only added `expenseSubmit` to founder
-- (it was written before main's mig 00262 introduced the admin role).
-- That earlier version of mig 00263 is already recorded in prod's
-- migration log, so the rewrite of mig 00263 in this same commit
-- (which adds expenseSubmit to BOTH founder and admin) will NOT
-- re-execute against prod — Supabase keys migrations by their
-- timestamp version.
--
-- This dedicated one-shot mig closes the gap for prod: walks every
-- group whose `roles.admin` exists (mig 00262 backfilled admin onto
-- all of them) and ensures admin.permissions includes expenseSubmit.
--
-- Idempotent. Future deploys that start fresh apply mig 00263 (the
-- rewritten version) and never need this mig; running it anyway is a
-- silent no-op because the perm is already present.

BEGIN;

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

do $$
declare v_count int;
begin
  select count(*) into v_count
    from public.groups
   where roles->'admin'->'permissions' ? 'expenseSubmit';
  raise notice 'mig 00269: % groups now grant admin.expenseSubmit', v_count;
end;
$$;

COMMIT;
