-- Mig 00177: Soft-delete on groups
--
-- Constitution §10 mandates "groups | DELETE Soft-delete | Dominio vivo".
-- Today `delete from public.groups` cascades through 21+ child tables and
-- wipes the historical record (ledger entries, atoms, votes, fines, …).
-- Soft-delete preserves that history while letting the founder remove
-- the group from active surfaces.
--
-- Schema:
--   archived_at timestamptz null   — null = active. Stamped by archive_group.
--   archived_by uuid null          — who archived it (founder typically).
--
-- RLS: `groups_select` already filters by membership; we add a
-- non-archived gate so dropped groups disappear from list-mine queries.
-- The founder can still read via `select_archived_group(p_group_id)` —
-- explicit lookup by id; useful for restore / export flows.
--
-- Permissions: only members with the `modifyMembers` permission (founder
-- has this by default) can archive. This is the same permission stack
-- used by `remove_member` / governance edits.

-- 1) Columns
alter table public.groups
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references auth.users(id) on delete set null;

create index if not exists groups_active_idx
  on public.groups (created_at desc)
  where archived_at is null;

comment on column public.groups.archived_at is
  'Soft-delete timestamp. Null = active. Constitution §10 — groups soft-delete only.';

-- 2) RLS — hide archived from default reads
drop policy if exists "groups_select" on public.groups;
create policy "groups_select" on public.groups for select to authenticated
using (
  archived_at is null
  and (
    public.is_group_member(id, auth.uid())
    or created_by = auth.uid()
  )
);

-- Separate policy that surfaces archived rows to the original founder
-- only. Used by restore flows; the founder is the only role that should
-- ever see "this group I archived 6 months ago".
create policy "groups_select_archived_founder" on public.groups for select to authenticated
using (
  archived_at is not null
  and created_by = auth.uid()
);

-- 3) archive_group + unarchive_group RPCs
create or replace function public.archive_group(p_group_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;
  if not public.is_group_admin(p_group_id, v_user_id) then
    raise exception 'caller is not a group admin' using errcode = 'insufficient_privilege';
  end if;

  update public.groups
     set archived_at = now(),
         archived_by = v_user_id,
         updated_at  = now()
   where id = p_group_id
     and archived_at is null;
end;
$$;

revoke execute on function public.archive_group(uuid) from public, anon;
grant  execute on function public.archive_group(uuid) to authenticated;

create or replace function public.unarchive_group(p_group_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user_id uuid := auth.uid();
  v_archived_by uuid;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;

  -- Only the founder who archived (or any current admin who can still
  -- see it via groups_select_archived_founder) may restore.
  select archived_by into v_archived_by
    from public.groups
   where id = p_group_id
   for update;

  if v_archived_by is null then
    raise exception 'group is not archived' using errcode = 'check_violation';
  end if;
  if v_archived_by <> v_user_id then
    raise exception 'only the founder who archived can restore' using errcode = 'insufficient_privilege';
  end if;

  update public.groups
     set archived_at = null,
         archived_by = null,
         updated_at  = now()
   where id = p_group_id;
end;
$$;

revoke execute on function public.unarchive_group(uuid) from public, anon;
grant  execute on function public.unarchive_group(uuid) to authenticated;
