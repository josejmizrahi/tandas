-- 00228 — has_permission aggregates permissions from group_members.roles jsonb.
--
-- Background
-- ==========
-- mig 00063 introduced has_permission(group_id, user_id, permission). It
-- resolves the caller's role from group_members.role (text, singular)
-- and looks up groups.roles[role].permissions. That model has two
-- shortcomings unblocking Phase 5:
--
--   1. group_members.role is the legacy text column flagged DEPRECATED
--      in mig 00106. group_members.roles (jsonb array, mig 00019) is
--      canonical and supports multi-role membership ("founder + member",
--      "treasurer + member", "host + member"). Reading only the text
--      column means a member with roles=["member","treasurer"] but
--      role="member" never resolves the treasurer permissions —
--      Permission.fundWithdraw stays denied even though the catalog
--      grants it.
--
--   2. assign_role (mig 00229) writes to the jsonb array, not the text
--      column. Without this rewrite the permission a founder just
--      granted would be invisible to has_permission.
--
-- Fix
-- ===
-- Iterate jsonb_array_elements_text(group_members.roles) and return true
-- if ANY of the assigned roles in groups.roles grants p_permission.
-- Legacy 'admin' string in either column aliases to 'founder' (kept
-- from mig 00063). Falls back to the text column when the jsonb array
-- is empty/null so legacy rows that never got backfilled still work.
--
-- Behavioral changes
-- ==================
-- A member previously holding a single text role can now hold multiple
-- jsonb roles; their effective permission set becomes the UNION across
-- all roles, not the intersection. This is the intended Phase 5 model
-- (RolesV2 plan §1).
--
-- Affected callers (audited 2026-05-16):
--   - 00216_bookings_atom.sql:133  bookSlot
--   - 00113 / 00111 / 00112 / 00114  resolve_governance.* family
--   - 00124 groups_governance_guard
--   - 00183 regenerate_invite_code
--   - 00168 create_asset
--   - 00087 group_policies
-- All consume has_permission(group_id, user_id, permission) → true|false.
-- Signature unchanged, return semantics same; the only observable change
-- is "true when the jsonb array grants it" — strictly more permissive
-- for members who hold additional roles. No caller breaks.

create or replace function public.has_permission(
  p_group_id   uuid,
  p_user_id    uuid,
  p_permission text
) returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_member_roles jsonb;
  v_legacy_role  text;
  v_group_roles  jsonb;
  v_role_key     text;
  v_perms        jsonb;
begin
  if p_group_id is null or p_user_id is null or p_permission is null then
    return false;
  end if;

  select gm.roles, gm.role
    into v_member_roles, v_legacy_role
    from public.group_members gm
   where gm.group_id = p_group_id
     and gm.user_id  = p_user_id
     and gm.active
   limit 1;

  if not found then
    return false;
  end if;

  select g.roles into v_group_roles
    from public.groups g
   where g.id = p_group_id;

  if v_group_roles is null then
    return false;
  end if;

  -- Primary path: aggregate from the jsonb roles array. A member holding
  -- ["founder","member","treasurer"] gets the UNION of all three role
  -- permission sets.
  if v_member_roles is not null and jsonb_typeof(v_member_roles) = 'array' then
    for v_role_key in
      select value::text from jsonb_array_elements_text(v_member_roles)
    loop
      -- Legacy V1 alias: 'admin' → 'founder'.
      if v_role_key = 'admin' then
        v_role_key := 'founder';
      end if;
      v_perms := v_group_roles -> v_role_key -> 'permissions';
      if v_perms is not null
         and jsonb_typeof(v_perms) = 'array'
         and v_perms ? p_permission then
        return true;
      end if;
    end loop;
  end if;

  -- Fallback: legacy text column for rows where the jsonb array is
  -- empty/null (shouldn't happen post-mig 00019 backfill but harmless
  -- to keep as belt-and-suspenders during the deprecation window).
  if v_legacy_role is not null and length(trim(v_legacy_role)) > 0 then
    v_role_key := case v_legacy_role when 'admin' then 'founder' else v_legacy_role end;
    v_perms := v_group_roles -> v_role_key -> 'permissions';
    if v_perms is not null
       and jsonb_typeof(v_perms) = 'array'
       and v_perms ? p_permission then
      return true;
    end if;
  end if;

  return false;
end;
$$;

revoke execute on function public.has_permission(uuid, uuid, text) from public, anon;
grant  execute on function public.has_permission(uuid, uuid, text) to authenticated;

comment on function public.has_permission(uuid, uuid, text) is
  'Returns true if the user has p_permission on p_group_id by UNION across all roles in group_members.roles jsonb. Phase 5 rewrite (mig 00228): aggregates instead of reading only the legacy text role. Legacy "admin" aliased to "founder".';
