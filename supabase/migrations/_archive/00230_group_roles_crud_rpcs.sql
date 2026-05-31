-- 00230 — upsert_group_role + delete_group_role RPCs. Phase 5 (RolesV2).
--
-- Background
-- ==========
-- groups.roles jsonb (mig 00063) is seeded with system roles (founder /
-- member) and optionally extended by templates.config.defaultRoles
-- (mig 00067). Until this migration, founders could not declare new
-- roles after group creation without raw SQL. iOS GroupRolesSheet
-- (Phase 5 UI) consumes these two RPCs.
--
-- Gating: has_permission(assignRoles) — same as the assign_role RPCs
-- in mig 00229. The founder default seed includes assignRoles, so any
-- pre-Phase-5 group can manage roles immediately; custom roles can
-- delegate the catalog to a non-founder by granting them assignRoles.
--
-- Invariants
-- ==========
--   1. Role id must match `^[a-z][a-z0-9_]{0,31}$` (lowercase ascii +
--      underscores, 1-32 chars). Matches typical jsonb-key naming
--      conventions used by templates (`seat_owner`, `co_owner`).
--   2. System roles (`founder`, `member`) cannot be deleted. Their
--      `system: true` flag is preserved on upsert.
--   3. Founder role MUST retain the `assignRoles` permission to prevent
--      a self-lockout where no one in the group can edit roles anymore.
--   4. delete_group_role cascades to group_members: every membership
--      that held the deleted role has the role stripped from their
--      roles jsonb array. Cleanup is single-transaction with the
--      catalog delete to avoid orphan role strings.
--
-- Events
-- ======
-- Role catalog mutations are audit-only metadata changes. We deliberately
-- DO NOT emit per-role lifecycle events (groupRoleCreated/Updated/Deleted)
-- in Beta. The activity feed surfaces the consequence — role assignments
-- via roleAssigned/roleUnassigned (mig 00229). Group-level metadata
-- audit can be reconstructed from groups.updated_at + audit ledger if
-- needed.

-- =============================================================================
-- 1. upsert_group_role
-- =============================================================================

create or replace function public.upsert_group_role(
  p_group_id    uuid,
  p_role_id     text,
  p_label       text          default null,
  p_permissions text[]        default array[]::text[],
  p_max_holders int           default null
) returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid          uuid := auth.uid();
  v_normalized   text;
  v_is_system    boolean := false;
  v_value        jsonb;
  v_perms        jsonb;
  g              public.groups;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;

  if not (public.has_permission(p_group_id, v_uid, 'assignRoles')
          or public.is_group_admin(p_group_id, v_uid)) then
    raise exception 'permission denied: assignRoles';
  end if;

  v_normalized := lower(trim(coalesce(p_role_id, '')));
  if v_normalized = '' or v_normalized !~ '^[a-z][a-z0-9_]{0,31}$' then
    raise exception 'invalid role_id %: must match [a-z][a-z0-9_]{0,31}', p_role_id;
  end if;

  if v_normalized in ('founder', 'member') then
    v_is_system := true;
  end if;

  if p_max_holders is not null and p_max_holders < 1 then
    raise exception 'max_holders must be >= 1 (got %)', p_max_holders;
  end if;

  -- Founder lockout safeguard: assignRoles must be present in the
  -- founder permission set. Same shape as has_permission's jsonb lookup
  -- — we encode it as text-array membership before serializing.
  if v_normalized = 'founder' and not ('assignRoles' = any (p_permissions)) then
    raise exception 'founder role must retain assignRoles permission (would lock the group out of role management)';
  end if;

  -- Deduplicate + stable sort the permissions list so the persisted
  -- jsonb is canonical (helps with idempotency checks downstream).
  v_perms := coalesce(
    (
      select jsonb_agg(p order by p)
      from (select distinct unnest(p_permissions) as p) deduped
    ),
    '[]'::jsonb
  );

  v_value := jsonb_build_object(
    'system',      v_is_system,
    'permissions', v_perms
  );
  if p_label is not null and length(trim(p_label)) > 0 then
    v_value := v_value || jsonb_build_object('label', trim(p_label));
  end if;
  if p_max_holders is not null then
    v_value := v_value || jsonb_build_object('max_holders', p_max_holders);
  end if;

  update public.groups
     set roles      = coalesce(roles, '{}'::jsonb)
                      || jsonb_build_object(v_normalized, v_value),
         updated_at = now()
   where id = p_group_id
   returning * into g;

  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  return g;
end;
$$;

revoke execute on function public.upsert_group_role(uuid, text, text, text[], int)
  from public, anon;
grant  execute on function public.upsert_group_role(uuid, text, text, text[], int)
  to authenticated;

comment on function public.upsert_group_role(uuid, text, text, text[], int) is
  'Phase 5 (mig 00230): adds or replaces an entry in groups.roles jsonb. Gated by has_permission(assignRoles). Validates id format, deduplicates permissions, enforces founder-keeps-assignRoles lockout safeguard. System roles (founder/member) preserve their `system: true` flag.';

-- =============================================================================
-- 2. delete_group_role
-- =============================================================================

create or replace function public.delete_group_role(
  p_group_id uuid,
  p_role_id  text
) returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid        uuid := auth.uid();
  v_normalized text;
  g            public.groups;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;

  if not (public.has_permission(p_group_id, v_uid, 'assignRoles')
          or public.is_group_admin(p_group_id, v_uid)) then
    raise exception 'permission denied: assignRoles';
  end if;

  v_normalized := lower(trim(coalesce(p_role_id, '')));
  if v_normalized = '' then
    raise exception 'role_id required';
  end if;

  if v_normalized in ('founder', 'member') then
    raise exception 'cannot delete system role %', v_normalized;
  end if;

  -- Strip the role from every membership in the group atomically with
  -- the catalog removal. Each affected row is rewritten; updated_at
  -- changes so observers see the cascade.
  update public.group_members gm
     set roles      = (
                        select coalesce(jsonb_agg(elem), '[]'::jsonb)
                          from jsonb_array_elements_text(gm.roles) as t(elem)
                         where elem <> v_normalized
                      ),
         updated_at = now()
   where gm.group_id = p_group_id
     and coalesce(gm.roles, '[]'::jsonb) ? v_normalized;

  update public.groups
     set roles      = roles - v_normalized,
         updated_at = now()
   where id = p_group_id
   returning * into g;

  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  return g;
end;
$$;

revoke execute on function public.delete_group_role(uuid, text) from public, anon;
grant  execute on function public.delete_group_role(uuid, text) to authenticated;

comment on function public.delete_group_role(uuid, text) is
  'Phase 5 (mig 00230): removes a custom role from groups.roles and cascades to strip the role from every group_members.roles array in the group. Gated by has_permission(assignRoles). System roles (founder/member) cannot be deleted.';
