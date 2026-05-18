-- 00286 — Guard direct REST writes to groups.roles + emit groupRolesChanged.
-- (Originally numbered 00279; renumbered to 00286 — parallel work claimed
-- 00278..00284. Live applied under timestamp 20260518 / name
-- guard_groups_roles_write.)
--
-- Sprint B of the RolesRemediation plan (Plans/Active/RolesRemediation_2026-05-17.md).
-- Closes V2 + V14 of RolesAudit_2026-05-17.md.
--
-- Background
-- ==========
-- groups.roles jsonb (the role catalog) is mutated by upsert_group_role
-- and delete_group_role (mig 00230, with CAS bolted on in mig 00241).
-- RLS groups_update_admin (mig 00002) ALSO allows ANY active admin to
-- UPDATE groups.* including .roles directly via /rest/v1/groups —
-- bypassing the RPCs entirely. Mig 00230 header §"Events" deliberately
-- deferred catalog atoms; Sprint B closes the gap.
--
-- Design
-- ======
-- Same shape as mig 00124 (guard_groups_governance_update), with one
-- addition — the RPC sets a session-local flag the trigger trusts.
-- Pattern:
--   1. NEW.roles IS NOT DISTINCT FROM OLD.roles → no-op, allow.
--   2. auth.uid() IS NULL → service_role / migration path, allow.
--   3. current_setting('app.role_write_via_rpc', true) = '1' → trusted
--      RPC path. Clear the flag immediately so it doesn't leak.
--   4. else → raise 42501 with hint pointing at the RPCs.
--
-- This migration preserves the signatures + CAS check introduced by
-- mig 00241 (upsert: 6 args, delete: 3 args). It wraps the body to
-- (a) set the bypass flag before the groups UPDATE, and (b) emit
-- groupRolesChanged after success. delete_group_role additionally
-- loops the affected members so one roleUnassigned atom is emitted
-- per holder (and the member-roles bypass flag from mig 00287 is set
-- inside the loop).

-- =============================================================================
-- 1. Trigger function + attach
-- =============================================================================
create or replace function public.guard_groups_roles_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_flag text;
begin
  if new.roles is not distinct from old.roles then
    return new;
  end if;

  if auth.uid() is null then
    return new;
  end if;

  v_flag := current_setting('app.role_write_via_rpc', true);
  if v_flag = '1' then
    perform set_config('app.role_write_via_rpc', '', true);
    return new;
  end if;

  raise exception
    'direct write to groups.roles is forbidden — use upsert_group_role/delete_group_role RPCs (caller %)', auth.uid()
    using errcode = '42501',
          hint = 'public.upsert_group_role(p_group_id, p_role_id, ...) / public.delete_group_role(p_group_id, p_role_id, ...)';
end;
$$;

revoke execute on function public.guard_groups_roles_write() from public, anon, authenticated;

comment on function public.guard_groups_roles_write() is
  'BEFORE UPDATE OF roles trigger on groups: blocks direct REST writes; trusts SECURITY DEFINER RPC callers via session flag app.role_write_via_rpc. Closes V2 from RolesAudit 2026-05-17.';

drop trigger if exists groups_roles_guard on public.groups;
create trigger groups_roles_guard
  before update of roles on public.groups
  for each row
  execute function public.guard_groups_roles_write();

comment on trigger groups_roles_guard on public.groups is
  'Sprint B (mig 00286): blocks direct UPDATE of groups.roles outside RPC funnel.';

-- =============================================================================
-- 2. upsert_group_role v3 — preserves mig 00241 CAS + signature, adds
--    bypass flag + groupRolesChanged atom emit.
-- =============================================================================
create or replace function public.upsert_group_role(
  p_group_id         uuid,
  p_role_id          text,
  p_label            text default null,
  p_permissions      text[] default array[]::text[],
  p_max_holders      integer default null,
  p_expected_version int default null
)
returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid             uuid := auth.uid();
  v_normalized      text;
  v_is_system       boolean := false;
  v_value           jsonb;
  v_perms           jsonb;
  v_current_version int;
  v_existing        jsonb;
  v_op              text;
  g                 public.groups;
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

  if v_normalized = 'founder' and not ('assignRoles' = any (p_permissions)) then
    raise exception 'founder role must retain assignRoles permission (would lock the group out of role management)';
  end if;

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

  -- CAS check (mig 00241): grab the row lock first, compare versions
  -- under it, then update. FOR UPDATE serializes this critical section
  -- against concurrent upsert/delete on the same group. Same SELECT
  -- also captures the existing entry to decide op=created vs op=updated.
  select roles_version, roles -> v_normalized
    into v_current_version, v_existing
    from public.groups
   where id = p_group_id
   for update;

  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  if p_expected_version is not null and v_current_version <> p_expected_version then
    raise exception 'roles version conflict: expected %, got % — refresh and retry',
      p_expected_version, v_current_version
      using errcode = '40001';
  end if;

  v_op := case when v_existing is null then 'created' else 'updated' end;

  -- Sprint B (mig 00286): authorize the trigger before the UPDATE.
  perform set_config('app.role_write_via_rpc', '1', true);

  update public.groups
     set roles      = coalesce(roles, '{}'::jsonb)
                      || jsonb_build_object(v_normalized, v_value),
         updated_at = now()
   where id = p_group_id
   returning * into g;

  -- Sprint B (mig 00286): emit catalog atom.
  perform public.record_system_event(
    p_group_id,
    'groupRolesChanged',
    null,
    null,
    jsonb_build_object(
      'op',           v_op,
      'role_id',      v_normalized,
      'permissions',  v_perms,
      'system',       v_is_system,
      'changed_by',   v_uid
    )
  );

  return g;
end;
$$;

comment on function public.upsert_group_role(uuid, text, text, text[], integer, int) is
  'v3 (mig 00286): preserves mig 00241 CAS + signature. Adds session-flag bypass for guard_groups_roles_write trigger and emits groupRolesChanged atom (op=created|updated). Closes V2 + half of V14 (RolesAudit 2026-05-17).';

-- =============================================================================
-- 3. delete_group_role v3 — preserves mig 00241 CAS + signature, adds
--    bypass flags (both groups + group_members) + per-member roleUnassigned
--    cascade + groupRolesChanged op=deleted atom.
-- =============================================================================
create or replace function public.delete_group_role(
  p_group_id         uuid,
  p_role_id          text,
  p_expected_version int default null
)
returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid             uuid := auth.uid();
  v_normalized      text;
  v_current_version int;
  v_affected        record;
  g                 public.groups;
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

  -- CAS check (mig 00241).
  select roles_version into v_current_version
    from public.groups
   where id = p_group_id
   for update;

  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  if p_expected_version is not null and v_current_version <> p_expected_version then
    raise exception 'roles version conflict: expected %, got % — refresh and retry',
      p_expected_version, v_current_version
      using errcode = '40001';
  end if;

  -- Cascade strip + per-member atom emission. Sprint B (mig 00286):
  -- we replace mig 00241's single bulk UPDATE with a loop so one
  -- roleUnassigned atom is emitted per holder. Each iteration sets
  -- the member-roles bypass flag (consumed by mig 00287's trigger).
  for v_affected in
    select id, user_id
      from public.group_members
     where group_id = p_group_id
       and coalesce(roles, '[]'::jsonb) ? v_normalized
  loop
    perform set_config('app.member_roles_write_via_rpc', '1', true);

    update public.group_members gm
       set roles      = (
                          select coalesce(jsonb_agg(elem), '[]'::jsonb)
                            from jsonb_array_elements_text(gm.roles) as t(elem)
                           where elem <> v_normalized
                        ),
           updated_at = now()
     where gm.id = v_affected.id;

    perform public.record_system_event(
      p_group_id,
      'roleUnassigned',
      null,
      v_affected.id,
      jsonb_build_object(
        'role',           v_normalized,
        'user_id',        v_affected.user_id,
        'unassigned_by',  v_uid,
        'cause',          'role_deleted'
      )
    );
  end loop;

  -- Sprint B (mig 00286): authorize trigger before catalog UPDATE.
  perform set_config('app.role_write_via_rpc', '1', true);

  update public.groups
     set roles      = roles - v_normalized,
         updated_at = now()
   where id = p_group_id
   returning * into g;

  -- Sprint B (mig 00286): emit catalog atom.
  perform public.record_system_event(
    p_group_id,
    'groupRolesChanged',
    null,
    null,
    jsonb_build_object(
      'op',         'deleted',
      'role_id',    v_normalized,
      'changed_by', v_uid
    )
  );

  return g;
end;
$$;

comment on function public.delete_group_role(uuid, text, int) is
  'v3 (mig 00286): preserves mig 00241 CAS + signature. Adds per-member roleUnassigned cascade (cause=role_deleted) and groupRolesChanged op=deleted atom. Sets bypass flags for guard_groups_roles_write + guard_group_members_roles_write triggers. Closes V14 (RolesAudit 2026-05-17).';
