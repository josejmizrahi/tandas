-- 00299 — V24 phase 1: eliminate doctrinal dependence on
-- group_members.role text column. Column STAYS on disk (old iOS
-- clients still SELECT it); a follow-up Sprint after iOS rollout
-- drops the column physically.
--
-- Plans/Active/RolesRemediation_2026-05-17.md V24 + V21+V22 cleanup
-- tail. Sprint A (mig 00290) backfilled 'admin' into every founder's
-- roles[], so `is_group_admin` can now read the jsonb authoritatively
-- without losing any current admin. The text column becomes stale-but-
-- harmless from this migration forward.
--
-- Changes
-- =======
-- 1. `is_group_admin(gid, uid)` rewritten to read `roles ? 'admin'
--    OR roles ? 'founder'` from the jsonb. Same boolean, no signature
--    change. Every RLS policy + RPC that calls it (~30 sites) gets
--    the doctrinal fix transparently.
-- 2. `sync_group_members_role_text` trigger + fn DROPPED. Its only
--    purpose was keeping the text column in sync so `is_group_admin`
--    could read it — irrelevant once #1 lands.
-- 3. `validate_group_member_role` trigger + fn DROPPED. It validated
--    UPDATE OF role text values against the catalog — also irrelevant
--    once nothing reads the column for authorization.
-- 4. Column comment updated: marks `group_members.role` as
--    DEPRECATED-DEAD (stale value, do not trust). Column NOT dropped
--    yet — old iOS builds still SELECT it; V24.2 drops it once
--    rollout complete.
--
-- Idempotent: CREATE OR REPLACE + DROP TRIGGER IF EXISTS.

-- =============================================================================
-- 1. is_group_admin reads jsonb
-- =============================================================================
create or replace function public.is_group_admin(gid uuid, uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.group_members
     where group_id = gid
       and user_id  = uid
       and active   = true
       and (
         coalesce(roles, '[]'::jsonb) ? 'admin'
         or coalesce(roles, '[]'::jsonb) ? 'founder'
       )
  );
$$;

comment on function public.is_group_admin(uuid, uuid) is
  'v2 (mig 00299): reads group_members.roles jsonb (any of admin/founder) instead of the legacy group_members.role text column. Mig 00290 backfilled admin into every founder so the predicate covers the same population. Sprint F prerequisite for dropping the text column entirely.';

-- =============================================================================
-- 2. Drop the role-text sync trigger
-- =============================================================================
drop trigger if exists group_members_role_text_sync on public.group_members;
drop function if exists public.sync_group_members_role_text();

-- =============================================================================
-- 3. Drop the role-text validation trigger
-- =============================================================================
drop trigger if exists group_members_role_validation on public.group_members;
drop function if exists public.validate_group_member_role();

-- =============================================================================
-- 4. Mark the column DEPRECATED-DEAD
-- =============================================================================
comment on column public.group_members.role is
  'DEPRECATED-DEAD post-mig-00299. Value is whatever the sync trigger last wrote — no longer maintained, no longer read for authorization. is_group_admin now reads roles jsonb. Kept on disk because old iOS clients SELECT it; physical drop is V24.2 once rollout completes.';
