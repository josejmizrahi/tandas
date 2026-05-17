-- Rollback for 00241_groups_roles_version_cas.sql.
--
-- Drops the column, trigger, and restores the prior 5-arg RPC
-- signatures (without p_expected_version). Note: this DROPs the new
-- 6-arg / 3-arg functions to avoid leaving overloads with different
-- defaults — postgres would reject the CREATE OR REPLACE otherwise.

drop trigger if exists trg_bump_groups_roles_version on public.groups;
drop function if exists public.bump_groups_roles_version();

drop function if exists public.upsert_group_role(uuid, text, text, text[], integer, int);
drop function if exists public.delete_group_role(uuid, text, int);

alter table public.groups drop column if exists roles_version;

-- Restore prior bodies (mig 00230).
create or replace function public.upsert_group_role(
  p_group_id    uuid,
  p_role_id     text,
  p_label       text default null,
  p_permissions text[] default array[]::text[],
  p_max_holders integer default null
)
returns public.groups
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

create or replace function public.delete_group_role(p_group_id uuid, p_role_id text)
returns public.groups
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
