-- 00343 — Backfill `manageEvents` permission into the founder + admin
-- role definitions on every existing group, AND make the role-catalog
-- seed include it going forward.
--
-- Bug: founder/admin couldn't edit event details (location, time,
-- title) for events they didn't host. `update_event_metadata` (mig
-- 00210) gates on (viewer == host) OR (viewer has manageEvents).
-- The v1SystemRoles catalog never granted manageEvents to founder
-- or admin — only the per-event host had it implicitly via the
-- host-bypass branch. Symptom 2026-05-18: user (founder) tapping
-- "Añadir ubicación" on Bhuiii (Eduardo's event) → RPC raised
-- "host or manageEvents permission required" → iOS surfaced "No
-- pudimos guardar la ubicación".
--
-- Founder doctrine: admin/founder can edit any event in their group.
-- The host bypass remains (a member who's the host of THIS event can
-- still edit it without admin status).
--
-- Fix
-- ===
-- 1. UPDATE every group's roles jsonb to add 'manageEvents' to the
--    permissions array of 'founder' and 'admin' (skip if already
--    present so the mig is idempotent on re-run).
-- 2. (Schema-level defaults already updated in iOS RoleDefinition.
--    v1SystemRoles for new groups — covered by a separate iOS-side
--    edit, not in this mig.)

update public.groups
   set roles = (
     select jsonb_object_agg(
       role_key,
       case
         when role_key in ('founder', 'admin')
              and role_value->'permissions' is not null
              and not (role_value->'permissions' ? 'manageEvents')
         then jsonb_set(
                role_value,
                '{permissions}',
                (role_value->'permissions') || '["manageEvents"]'::jsonb
              )
         else role_value
       end
     )
     from jsonb_each(roles) as r(role_key, role_value)
   )
 where roles is not null
   and (
     (roles->'founder'->'permissions' is not null
       and not (roles->'founder'->'permissions' ? 'manageEvents'))
     or
     (roles->'admin'->'permissions' is not null
       and not (roles->'admin'->'permissions' ? 'manageEvents'))
   );

comment on table public.groups is
  'mig 00343: founder + admin roles now carry manageEvents permission so they can edit any event (not just ones they host). Pre-mig groups have been backfilled.';;
