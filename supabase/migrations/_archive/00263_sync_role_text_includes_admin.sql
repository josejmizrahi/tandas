-- 00263 — Extend role-text sync trigger to also follow the new admin role.
--
-- Background
-- ==========
-- mig 00232 added `sync_group_members_role_text()` BEFORE trigger that
-- mapped `roles ? 'founder' → role := 'admin'`. That was correct under
-- the pre-mig-00262 ontology where founder == admin.
--
-- mig 00262 split founder (identity, immutable) from admin (capability,
-- assignable). Now a member can hold `roles = ['admin','member']`
-- WITHOUT 'founder' — they're an operational admin without the historic
-- badge. The mig 00232 trigger would set their `role` text back to
-- 'member' (because `not (roles ? 'founder')`), which would silently
-- demote them in every is_group_admin()-gated RPC.
--
-- Today on prod: 0 such rows yet (admin assignment via assign_role
-- hasn't fired). But the FIRST time it does, mig 00232 corrupts the
-- text column.
--
-- Fix: trigger considers BOTH founder and admin as text='admin', so:
--   roles ? 'admin' OR roles ? 'founder'   → role := 'admin'
--   neither                                → role := 'member' (only if
--                                            currently 'admin', i.e.
--                                            don't clobber custom text)
--
-- One-shot backfill: 0 rows expected on prod today.

create or replace function public.sync_group_members_role_text()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_admin_capability boolean;
begin
  if new.roles is null then
    return new;
  end if;

  -- After mig 00262, both founder (identity) and admin (capability)
  -- map to the legacy text alias 'admin' for is_group_admin() and the
  -- handful of other helpers that still read the text column.
  v_has_admin_capability := (new.roles ? 'admin') or (new.roles ? 'founder');

  if v_has_admin_capability and coalesce(new.role, '') <> 'admin' then
    new.role := 'admin';
  elsif (not v_has_admin_capability) and new.role = 'admin' then
    new.role := 'member';
  end if;

  return new;
end;
$$;

comment on function public.sync_group_members_role_text() is
  'BEFORE INSERT/UPDATE trigger (mig 00263). Post-mig-00262 split of founder vs admin: both map to legacy text alias ''admin'' so is_group_admin() stays accurate when admin is granted without founder. Idempotent.';

-- Trigger itself is unchanged from mig 00232; CREATE OR REPLACE on the
-- function above is enough since the trigger references it by name.
-- Keep the explicit DROP/CREATE here for idempotent re-apply safety.
drop trigger if exists group_members_role_text_sync on public.group_members;
create trigger group_members_role_text_sync
  before insert or update of roles on public.group_members
  for each row
  execute function public.sync_group_members_role_text();

comment on trigger group_members_role_text_sync on public.group_members is
  'Keeps role (text, deprecated) consistent with roles (jsonb, canonical). v2 post-mig-00263: considers admin AND founder for the admin alias.';

-- =============================================================================
-- One-time backfill — should touch 0 rows on 2026-05-17 prod.
-- =============================================================================

do $$
declare
  v_promoted int;
  v_demoted  int;
begin
  with promoted as (
    update public.group_members
       set role = 'admin'
     where active = true
       and roles is not null
       and ((roles ? 'admin') or (roles ? 'founder'))
       and coalesce(role, '') <> 'admin'
    returning 1
  )
  select count(*) into v_promoted from promoted;

  with demoted as (
    update public.group_members
       set role = 'member'
     where active = true
       and roles is not null
       and not ((roles ? 'admin') or (roles ? 'founder'))
       and role = 'admin'
    returning 1
  )
  select count(*) into v_demoted from demoted;

  raise notice 'mig 00263 backfill: promoted=% demoted=%', v_promoted, v_demoted;
end;
$$;
