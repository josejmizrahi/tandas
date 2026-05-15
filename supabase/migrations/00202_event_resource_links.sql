-- Mig 00202: `resource_links` — event uses space/asset/fund (§12 spec)
--
-- (Originally drafted as 00198 on the event-resource-specification branch
-- and applied to prod under the snake_case name `event_resource_links`.
-- Renumbered to 00202 at merge time because main concurrently shipped
-- two 00198 files — fund_writers_balance_lifecycle and right_resource_
-- canonical — plus the asset_universal_* batch already on prod but not
-- yet committed to this branch. Prod state is unaffected: supabase tracks
-- migrations by name, not file prefix, so the rename is metadata-only.)
--
-- Plans/Active/EventResource.md §12: "Event puede usar spaces/assets/funds.
-- El event NO posee esos resources. Los coordina temporalmente."
--
-- Today there's no way to declare "this dinner uses the common fund" or
-- "this game uses the stadium space". This migration introduces the
-- polymorphic link table, append-only per §17 (state derived from atoms).
--
-- Design
-- ======
-- Table `resource_links` is append-only:
--   - INSERT on link  → emit `resourceLinked` atom
--   - UPDATE unlinked_at on unlink → emit `resourceUnlinked` atom
--   - Active links = WHERE unlinked_at IS NULL
--   - Re-linking after unlink = new row (full audit trail preserved)
--
-- Polymorphic via link_kind. v1 ships `uses` only (event → space/asset/fund/right
-- per §4). Future kinds: `governs`, `generates`. RPCs validate from/to
-- resource_types per kind, not the table — keeps the schema open.
--
-- Two RPCs:
--   link_resource_to_event(p_event_id, p_resource_id)
--   unlink_resource_from_event(p_link_id)
--
-- Caller must be active member of the group (matches create_fund pattern;
-- not admin-only — group resources are a group activity).

-- =========================================================
-- 1. Whitelist update: resourceLinked + resourceUnlinked
-- =========================================================

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable parallel safe
set search_path = pg_catalog
as $$
  select p_event_type = any (array[
    'eventClosed', 'eventCreated', 'rsvpDeadlinePassed', 'hoursBeforeEvent',
    'rsvpSubmitted', 'rsvpChangedSameDay', 'checkInRecorded', 'checkInMissed',
    'eventDescriptionMissing',
    'slotAssigned', 'slotDeclined', 'slotExpired', 'slotSwapRequested', 'slotSwapApproved',
    'bookingCreated', 'bookingCancelled', 'bookingExpired',
    'assetCreated',
    'fineOfficialized', 'fineVoided', 'finePaid', 'fineReminderSent',
    'appealCreated', 'appealResolved',
    'voteOpened', 'voteCast', 'voteResolved',
    'fundCreated', 'fundDeposit', 'fundThresholdReached',
    'positionChanged', 'memberJoined', 'memberLeft',
    'ruleEnabledChanged', 'ruleAmountChanged',
    'pendingChangeApplied', 'inviteCodeRotated',
    'groupCreated', 'groupArchived', 'groupUnarchived', 'groupRenamed', 'governanceUpdated',
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    'ledgerEntryCreated', 'warningEmitted',
    -- mig 00202: resource_links (event uses space/asset/fund)
    'resourceLinked', 'resourceUnlinked'
  ]);
$$;

-- =========================================================
-- 2. Table: resource_links
-- =========================================================

create table if not exists public.resource_links (
  id                uuid primary key default gen_random_uuid(),
  group_id          uuid not null references public.groups(id) on delete cascade,
  from_resource_id  uuid not null references public.resources(id) on delete cascade,
  to_resource_id    uuid not null references public.resources(id) on delete cascade,
  link_kind         text not null,
  linked_at         timestamptz not null default now(),
  linked_by         uuid references auth.users(id) on delete set null,
  unlinked_at       timestamptz,
  unlinked_by       uuid references auth.users(id) on delete set null,

  constraint resource_links_no_self_chk
    check (from_resource_id <> to_resource_id),
  constraint resource_links_kind_known_chk
    check (link_kind in ('uses')),
  constraint resource_links_unlinked_consistency_chk
    check ((unlinked_at is null) = (unlinked_by is null))
);

comment on table public.resource_links is
  'Polymorphic directed links between resources (event → space/asset/fund). Append-only per Plans/Active/EventResource.md §17: state derives from atoms. Active links: WHERE unlinked_at IS NULL.';

comment on column public.resource_links.link_kind is
  'Relation verb. v1: `uses` (event uses another resource). Future: `governs`, `generates`. Validated per (from_type, to_type) in the RPCs, not the table — keeps the schema open.';

-- Indexes
-- Only one ACTIVE link per (from, to, kind). Re-linking after unlink
-- creates a new row.
create unique index if not exists resource_links_active_unique_idx
  on public.resource_links (from_resource_id, to_resource_id, link_kind)
  where unlinked_at is null;

create index if not exists resource_links_from_active_idx
  on public.resource_links (from_resource_id)
  where unlinked_at is null;

create index if not exists resource_links_to_active_idx
  on public.resource_links (to_resource_id)
  where unlinked_at is null;

create index if not exists resource_links_group_idx
  on public.resource_links (group_id);

-- =========================================================
-- 3. RLS
-- =========================================================

alter table public.resource_links enable row level security;

-- Members of the group can read all links (active + historical).
create policy "resource_links_read_member" on public.resource_links
  for select to authenticated
  using (
    exists (
      select 1
        from public.group_members gm
       where gm.group_id = resource_links.group_id
         and gm.user_id  = auth.uid()
         and gm.active   = true
    )
  );

-- No direct DML — writes go through the RPCs below (SECURITY DEFINER).

-- =========================================================
-- 4. RPC: link_resource_to_event
-- =========================================================

create or replace function public.link_resource_to_event(
  p_event_id    uuid,
  p_resource_id uuid
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid         uuid := auth.uid();
  v_event_group uuid;
  v_event_type  text;
  v_target_group uuid;
  v_target_type text;
  v_existing_id uuid;
  v_link_id     uuid;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  -- Validate event (from)
  select group_id, resource_type
    into v_event_group, v_event_type
    from public.resources
   where id = p_event_id
     and archived_at is null;

  if v_event_group is null then
    raise exception 'event not found or archived' using errcode = '42704';
  end if;

  if v_event_type <> 'event' then
    raise exception 'link source must be of resource_type=event, got %', v_event_type
      using errcode = '22023';
  end if;

  -- Validate target (to)
  select group_id, resource_type
    into v_target_group, v_target_type
    from public.resources
   where id = p_resource_id
     and archived_at is null;

  if v_target_group is null then
    raise exception 'target resource not found or archived' using errcode = '42704';
  end if;

  if v_target_group <> v_event_group then
    raise exception 'event and target resource must belong to the same group'
      using errcode = '22023';
  end if;

  -- Spec §4: event can `use` space/asset/fund/right.
  if v_target_type not in ('space', 'asset', 'fund', 'right') then
    raise exception 'event can only use space/asset/fund/right, got %', v_target_type
      using errcode = '22023';
  end if;

  -- Caller must be active member of the group
  if not public.is_group_member(v_event_group, v_uid) then
    raise exception 'caller is not a member of this group'
      using errcode = '42501';
  end if;

  -- Idempotent: return existing active link
  select id into v_existing_id
    from public.resource_links
   where from_resource_id = p_event_id
     and to_resource_id   = p_resource_id
     and link_kind        = 'uses'
     and unlinked_at      is null;

  if v_existing_id is not null then
    return v_existing_id;
  end if;

  insert into public.resource_links (
    group_id, from_resource_id, to_resource_id, link_kind, linked_by
  ) values (
    v_event_group, p_event_id, p_resource_id, 'uses', v_uid
  )
  returning id into v_link_id;

  perform public.record_system_event(
    v_event_group,
    'resourceLinked',
    p_event_id,
    null,
    jsonb_build_object(
      'link_id',          v_link_id,
      'link_kind',        'uses',
      'to_resource_id',   p_resource_id,
      'to_resource_type', v_target_type,
      'linked_by',        v_uid
    )
  );

  return v_link_id;
end;
$$;

revoke execute on function public.link_resource_to_event(uuid, uuid) from public, anon;
grant  execute on function public.link_resource_to_event(uuid, uuid) to authenticated;

comment on function public.link_resource_to_event(uuid, uuid) is
  'Attach a space/asset/fund/right resource to an event (link_kind=uses). Idempotent: returns existing active link id if (event, target, uses) already linked. Emits resourceLinked atom. Plans/Active/EventResource.md §12.';

-- =========================================================
-- 5. RPC: unlink_resource_from_event
-- =========================================================

create or replace function public.unlink_resource_from_event(
  p_link_id uuid
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid         uuid := auth.uid();
  v_group_id    uuid;
  v_event_id    uuid;
  v_target_id   uuid;
  v_target_type text;
  v_unlinked    timestamptz;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select group_id, from_resource_id, to_resource_id, unlinked_at
    into v_group_id, v_event_id, v_target_id, v_unlinked
    from public.resource_links
   where id = p_link_id
   for update;

  if v_group_id is null then
    raise exception 'link not found' using errcode = '42704';
  end if;

  if v_unlinked is not null then
    -- Already unlinked; idempotent no-op.
    return;
  end if;

  if not public.is_group_member(v_group_id, v_uid) then
    raise exception 'caller is not a member of this group'
      using errcode = '42501';
  end if;

  select resource_type into v_target_type
    from public.resources
   where id = v_target_id;

  update public.resource_links
     set unlinked_at = now(),
         unlinked_by = v_uid
   where id = p_link_id;

  perform public.record_system_event(
    v_group_id,
    'resourceUnlinked',
    v_event_id,
    null,
    jsonb_build_object(
      'link_id',          p_link_id,
      'link_kind',        'uses',
      'to_resource_id',   v_target_id,
      'to_resource_type', v_target_type,
      'unlinked_by',      v_uid
    )
  );
end;
$$;

revoke execute on function public.unlink_resource_from_event(uuid) from public, anon;
grant  execute on function public.unlink_resource_from_event(uuid) to authenticated;

comment on function public.unlink_resource_from_event(uuid) is
  'Soft-unlink: stamps unlinked_at + unlinked_by on the row. Idempotent. Emits resourceUnlinked atom. Re-linking creates a new row (audit trail preserved). Plans/Active/EventResource.md §12+§17.';
