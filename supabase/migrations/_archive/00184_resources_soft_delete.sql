-- Mig 00184: Soft-delete on resources
--
-- Constitution §10: "resources | DELETE Soft-delete | Object mutable
-- controlado". Today DELETE FROM public.resources cascades through 6+
-- child tables (resource_capabilities, rsvp_actions, check_in_actions,
-- ledger_entries, vote scopes by reference_id, fines.resource_id). The
-- founder cannot archive a finished resource without erasing its
-- history.
--
-- Schema additions mirror Layer 1 (mig 00177):
--   archived_at timestamptz null  — null = active. Stamped by archive_resource.
--   archived_by uuid null          — who archived it.
--
-- RLS:
--   resources_read_member (00014) restricted to archived_at IS NULL.
--   New `resources_select_archived_founder` lets the group's founder
--   still see + restore. Founder = `roles ? 'founder'` on group_members.
--
-- Permissions:
--   archive_resource — caller must be group admin (founder + custom
--   admin roles via has_permission, like remove_member).
--   unarchive_resource — only the actor who archived can restore
--   (mirrors groups.unarchive_group).

alter table public.resources
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references auth.users(id) on delete set null;

create index if not exists resources_active_idx
  on public.resources (group_id, resource_type, created_at desc)
  where archived_at is null;

comment on column public.resources.archived_at is
  'Soft-delete timestamp. Null = active. Constitution §10 — resources soft-delete only.';

-- RLS — replace the existing single SELECT policy with the two-pass version
drop policy if exists "resources_read_member" on public.resources;

create policy "resources_read_member" on public.resources for select to authenticated
using (
  archived_at is null
  and exists (
    select 1 from public.group_members gm
     where gm.group_id = resources.group_id
       and gm.user_id  = auth.uid()
       and gm.active   = true
  )
);

create policy "resources_select_archived_founder" on public.resources for select to authenticated
using (
  archived_at is not null
  and exists (
    select 1 from public.group_members gm
     where gm.group_id = resources.group_id
       and gm.user_id  = auth.uid()
       and gm.active   = true
       and gm.roles ? 'founder'
  )
);

create or replace function public.archive_resource(p_resource_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid      uuid := auth.uid();
  v_group_id uuid;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;

  select group_id into v_group_id
    from public.resources
   where id = p_resource_id;

  if v_group_id is null then
    raise exception 'resource not found' using errcode = 'check_violation';
  end if;

  if not public.is_group_admin(v_group_id, v_uid) then
    raise exception 'caller is not a group admin' using errcode = 'insufficient_privilege';
  end if;

  update public.resources
     set archived_at = now(),
         archived_by = v_uid,
         updated_at  = now()
   where id = p_resource_id
     and archived_at is null;
end;
$$;

revoke execute on function public.archive_resource(uuid) from public, anon;
grant  execute on function public.archive_resource(uuid) to authenticated;

create or replace function public.unarchive_resource(p_resource_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid         uuid := auth.uid();
  v_archived_by uuid;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;

  select archived_by into v_archived_by
    from public.resources
   where id = p_resource_id
   for update;

  if v_archived_by is null then
    raise exception 'resource is not archived' using errcode = 'check_violation';
  end if;
  if v_archived_by <> v_uid then
    raise exception 'only the actor who archived can restore' using errcode = 'insufficient_privilege';
  end if;

  update public.resources
     set archived_at = null,
         archived_by = null,
         updated_at  = now()
   where id = p_resource_id;
end;
$$;

revoke execute on function public.unarchive_resource(uuid) from public, anon;
grant  execute on function public.unarchive_resource(uuid) to authenticated;
