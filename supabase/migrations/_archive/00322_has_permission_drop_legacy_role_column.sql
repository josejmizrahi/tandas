-- Mig 00322: drop the legacy gm.role fallback from has_permission.
--
-- Background
-- ==========
-- has_permission was authored when `group_members.role` (text) and
-- `group_members.roles` (jsonb) coexisted. mig 00303 dropped the text
-- column entirely, but has_permission kept the `select gm.roles, gm.role`
-- and the trailing v_legacy_role branch — so every call now crashes with
-- ERROR 42703: column gm.role does not exist.
--
-- Live observation:
--   finalize_placeholder_member (mig 00315) calls has_permission as defense
--   in depth and currently always raises 42703, masking the real auth path.
--   Same for any RPC gated on has_permission (fines, votes, rules, events,
--   modules, members — Sprint C migrations 00237-00242 wired them all).
--
-- Fix
-- ===
-- Remove `gm.role` from the SELECT and delete the legacy branch. The jsonb
-- `gm.roles` array is NOT NULL with default `["member"]` (mig 00063 + 00106
-- comment), so we never lose authoritative state.
--
-- Source: incidental discovery during placeholder-members Phase 2 smoke.
-- The original placeholder-members spec (2026-05-17) flagged this as
-- preexisting and out-of-scope; this migration closes the gap so the
-- defense-in-depth check inside finalize_placeholder_member can succeed.

create or replace function public.has_permission(p_group_id uuid, p_user_id uuid, p_permission text)
  returns boolean
  language plpgsql
  stable security definer
  set search_path to 'public'
as $function$
declare
  v_member_roles jsonb;
  v_group_roles  jsonb;
  v_role_key     text;
  v_perms        jsonb;
begin
  if p_group_id is null or p_user_id is null or p_permission is null then
    return false;
  end if;

  select gm.roles
    into v_member_roles
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

  if v_member_roles is not null and jsonb_typeof(v_member_roles) = 'array' then
    for v_role_key in
      select value::text from jsonb_array_elements_text(v_member_roles)
    loop
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

  return false;
end;
$function$;
