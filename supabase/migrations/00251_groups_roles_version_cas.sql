-- 00240 — Compare-And-Set protection for concurrent edits of groups.roles.

alter table public.groups
  add column if not exists roles_version int not null default 0;

comment on column public.groups.roles_version is
  'Monotonic version counter for the roles jsonb column. Bumped by a BEFORE UPDATE trigger when roles changes. Consulted by upsert_group_role / delete_group_role for optimistic-concurrency CAS (mig 00240).';

create or replace function public.bump_groups_roles_version()
returns trigger
language plpgsql
as $$
begin
  if new.roles is distinct from old.roles then
    new.roles_version := coalesce(old.roles_version, 0) + 1;
  end if;
  return new;
end;
$$;

comment on function public.bump_groups_roles_version() is
  'BEFORE UPDATE trigger function: increments groups.roles_version whenever NEW.roles differs from OLD.roles. Powers the CAS check in upsert_group_role / delete_group_role (mig 00240).';

drop trigger if exists trg_bump_groups_roles_version on public.groups;
create trigger trg_bump_groups_roles_version
  before update on public.groups
  for each row
  execute function public.bump_groups_roles_version();

-- Drop the old 5-arg overload first so the new 6-arg version doesn't
-- create an overload collision.
drop function if exists public.upsert_group_role(uuid, text, text, text[], integer);

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

  update public.groups
     set roles      = coalesce(roles, '{}'::jsonb)
                      || jsonb_build_object(v_normalized, v_value),
         updated_at = now()
   where id = p_group_id
   returning * into g;

  return g;
end;
$$;

comment on function public.upsert_group_role(uuid, text, text, text[], integer, int) is
  'v2 (mig 00240): optional CAS via p_expected_version. Pass null to skip check (backward-compatible). On version mismatch raises errcode 40001 (serialization_failure) so the client can refresh + retry.';

drop function if exists public.delete_group_role(uuid, text);

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

  return g;
end;
$$;

comment on function public.delete_group_role(uuid, text, int) is
  'v2 (mig 00240): optional CAS via p_expected_version. Pass null to skip (backward-compatible). On version mismatch raises errcode 40001.';
