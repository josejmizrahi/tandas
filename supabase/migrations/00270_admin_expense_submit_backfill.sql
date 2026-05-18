-- Mig 00269: idempotent expenseSubmit backfill on founder AND admin.
--
-- Context: mig 00264 was originally written before main's mig 00262
-- introduced the admin role. The earlier version of mig 00264 is
-- already recorded in prod's migration log, so the rewrite of mig
-- 00263 in this commit (which adds expenseSubmit to BOTH founder and
-- admin in the column default + backfill) will NOT re-execute against
-- prod — Supabase keys migrations by their timestamp version.
--
-- This dedicated one-shot mig closes the gap on the LIVE roles jsonb
-- for existing groups:
--   1. founder.permissions — groups created BETWEEN mig 00264's first
--      run and mig 00262 (e.g. on a fresh DB or after a partial
--      reset) inherited the post-00262 default which lacked
--      expenseSubmit on founder. Backfill catches them.
--   2. admin.permissions — every group (admin was introduced by mig
--      00262 with the 8 ops perms; expenseSubmit was never added).
--
-- Idempotent on both branches via `not (... ? 'expenseSubmit')` guard,
-- so re-running is a silent no-op. Future deploys that start fresh
-- apply mig 00264 (the rewritten version) and never need this mig;
-- running it anyway is safe.

BEGIN;

-- ============================================================
-- Founder backfill (covers groups born between mig 00264 + 00262)
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
   and g.roles->'founder' ? 'permissions'
   and not (g.roles->'founder'->'permissions' ? 'expenseSubmit');

-- ============================================================
-- Admin backfill (every group — admin landed in 00262 without the perm)
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
   and g.roles->'admin' ? 'permissions'
   and not (g.roles->'admin'->'permissions' ? 'expenseSubmit');

-- ============================================================
-- Audit
-- ============================================================
do $$
declare
  v_founder int;
  v_admin   int;
  v_total   int;
begin
  select count(*) into v_total   from public.groups;
  select count(*) into v_founder from public.groups
   where roles->'founder'->'permissions' ? 'expenseSubmit';
  select count(*) into v_admin   from public.groups
   where roles->'admin'->'permissions' ? 'expenseSubmit';
  raise notice 'mig 00270: %/% groups grant founder.expenseSubmit; %/% groups grant admin.expenseSubmit',
    v_founder, v_total, v_admin, v_total;
end;
$$;

COMMIT;
