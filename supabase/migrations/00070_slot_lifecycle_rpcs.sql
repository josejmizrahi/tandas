-- 00070 — Slot/Booking/Asset lifecycle RPCs (Phase 2 Slice 2.3)
--
-- 5 RPCs that materialize the polymorphic `resources` table for the
-- shared_resource template (palco/cabaña/casa). Each gated by
-- has_permission() (mig 00063 RolesV2 foundation) + emits a matching
-- SystemEvent so the rule engine (Slice 2.1 evaluators + Slice 2.2
-- emitter) can react.
--
-- Polymorphism contract (Plans/Active/Primitives.md § 2):
--   resource_type='asset'   metadata={ name, capacity }
--   resource_type='slot'    metadata={ asset_id, starts_at, ends_at,
--                                       assigned_member_id, booking_id }
--   resource_type='booking' metadata={ slot_id, member_id, booked_at }
--
-- All RPCs are SECURITY DEFINER so they can write across RLS boundaries
-- on resources/system_events; auth check goes through has_permission().

-- =============================================================================
-- 1. create_asset
-- =============================================================================
create or replace function public.create_asset(
  p_group_id uuid,
  p_name text,
  p_capacity int default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id uuid := auth.uid();
  v_asset_id  uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not public.has_permission(p_group_id, v_caller_id, 'assignSlot') then
    raise exception 'permission denied: assignSlot required' using errcode = '42501';
  end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'asset name required' using errcode = '22023';
  end if;

  insert into public.resources (group_id, resource_type, status, metadata, created_by)
  values (
    p_group_id,
    'asset',
    'active',
    jsonb_build_object(
      'name',     p_name,
      'capacity', p_capacity
    ),
    v_caller_id
  )
  returning id into v_asset_id;

  perform public.record_system_event(
    p_group_id,
    'assetCreated',
    v_asset_id,
    null,
    jsonb_build_object('name', p_name, 'capacity', p_capacity)
  );

  return v_asset_id;
end;
$$;

revoke execute on function public.create_asset(uuid, text, int) from public, anon;
grant  execute on function public.create_asset(uuid, text, int) to authenticated;

comment on function public.create_asset(uuid, text, int) is
  'Phase 2 Slice 2.3 — create a new asset (palco/cabaña/casa). Requires assignSlot permission. Emits assetCreated.';

-- =============================================================================
-- 2. create_slot
-- =============================================================================
create or replace function public.create_slot(
  p_asset_id  uuid,
  p_starts_at timestamptz,
  p_ends_at   timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id    uuid := auth.uid();
  v_group_id     uuid;
  v_asset_status text;
  v_slot_id      uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, status into v_group_id, v_asset_status
  from public.resources
  where id = p_asset_id and resource_type = 'asset';
  if v_group_id is null then
    raise exception 'asset not found' using errcode = '02000';
  end if;
  if v_asset_status <> 'active' then
    raise exception 'asset is %, cannot add slots', v_asset_status using errcode = '22023';
  end if;
  if not public.has_permission(v_group_id, v_caller_id, 'assignSlot') then
    raise exception 'permission denied: assignSlot required' using errcode = '42501';
  end if;
  if p_starts_at >= p_ends_at then
    raise exception 'starts_at must be before ends_at' using errcode = '22023';
  end if;

  insert into public.resources (group_id, resource_type, status, metadata, created_by)
  values (
    v_group_id,
    'slot',
    'unassigned',
    jsonb_build_object(
      'asset_id',           p_asset_id,
      'starts_at',          p_starts_at,
      'ends_at',            p_ends_at,
      'assigned_member_id', null,
      'booking_id',         null
    ),
    v_caller_id
  )
  returning id into v_slot_id;

  return v_slot_id;
end;
$$;

revoke execute on function public.create_slot(uuid, timestamptz, timestamptz) from public, anon;
grant  execute on function public.create_slot(uuid, timestamptz, timestamptz) to authenticated;

comment on function public.create_slot(uuid, timestamptz, timestamptz) is
  'Phase 2 Slice 2.3 — create a slot under an asset (status=unassigned). Requires assignSlot permission. No system_event emitted: slot creation is operational, not governance-relevant.';

-- =============================================================================
-- 3. assign_slot
-- =============================================================================
create or replace function public.assign_slot(
  p_slot_id   uuid,
  p_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_slot_status   text;
  v_member_active boolean;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, status into v_group_id, v_slot_status
  from public.resources
  where id = p_slot_id and resource_type = 'slot';
  if v_group_id is null then
    raise exception 'slot not found' using errcode = '02000';
  end if;
  if not public.has_permission(v_group_id, v_caller_id, 'assignSlot') then
    raise exception 'permission denied: assignSlot required' using errcode = '42501';
  end if;
  if v_slot_status not in ('unassigned', 'assigned') then
    raise exception 'slot is %, cannot reassign', v_slot_status using errcode = '22023';
  end if;

  -- Verify target member is active in the same group
  select active into v_member_active
  from public.group_members
  where id = p_member_id and group_id = v_group_id;
  if v_member_active is null then
    raise exception 'member not in this group' using errcode = '02000';
  end if;
  if not v_member_active then
    raise exception 'member is not active' using errcode = '22023';
  end if;

  update public.resources
  set
    status   = 'assigned',
    metadata = metadata || jsonb_build_object('assigned_member_id', p_member_id::text)
  where id = p_slot_id;

  perform public.record_system_event(
    v_group_id,
    'slotAssigned',
    p_slot_id,
    p_member_id,
    jsonb_build_object('assigned_by', v_caller_id)
  );
end;
$$;

revoke execute on function public.assign_slot(uuid, uuid) from public, anon;
grant  execute on function public.assign_slot(uuid, uuid) to authenticated;

comment on function public.assign_slot(uuid, uuid) is
  'Phase 2 Slice 2.3 — assign a slot to a member (status=assigned). Requires assignSlot permission. Emits slotAssigned.';

-- =============================================================================
-- 4. book_slot
-- =============================================================================
create or replace function public.book_slot(
  p_slot_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id          uuid := auth.uid();
  v_group_id           uuid;
  v_slot_status        text;
  v_metadata           jsonb;
  v_assigned_member_id uuid;
  v_caller_member_id   uuid;
  v_booking_id         uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, status, metadata
    into v_group_id, v_slot_status, v_metadata
  from public.resources
  where id = p_slot_id and resource_type = 'slot';
  if v_group_id is null then
    raise exception 'slot not found' using errcode = '02000';
  end if;
  if not public.has_permission(v_group_id, v_caller_id, 'bookSlot') then
    raise exception 'permission denied: bookSlot required' using errcode = '42501';
  end if;
  if v_slot_status not in ('unassigned', 'assigned') then
    raise exception 'slot is %, cannot book', v_slot_status using errcode = '22023';
  end if;

  -- Resolve caller's member_id
  select id into v_caller_member_id
  from public.group_members
  where group_id = v_group_id and user_id = v_caller_id and active;
  if v_caller_member_id is null then
    raise exception 'caller not active member' using errcode = '42501';
  end if;

  -- If slot is assigned to a different member, that holder gets first-right.
  -- An unassigned slot is bookable by anyone with bookSlot permission.
  v_assigned_member_id := nullif(v_metadata->>'assigned_member_id', '')::uuid;
  if v_assigned_member_id is not null and v_assigned_member_id <> v_caller_member_id then
    raise exception 'slot assigned to a different member' using errcode = '42501';
  end if;

  -- Create booking resource
  insert into public.resources (group_id, resource_type, status, metadata, created_by)
  values (
    v_group_id,
    'booking',
    'active',
    jsonb_build_object(
      'slot_id',   p_slot_id,
      'member_id', v_caller_member_id::text,
      'booked_at', now()
    ),
    v_caller_id
  )
  returning id into v_booking_id;

  -- Update slot to 'booked' + populate booking_id metadata so the
  -- slotIsUnassigned condition (Slice 2.1) sees it.
  update public.resources
  set
    status   = 'booked',
    metadata = metadata || jsonb_build_object('booking_id', v_booking_id::text)
  where id = p_slot_id;

  perform public.record_system_event(
    v_group_id,
    'bookingCreated',
    v_booking_id,
    v_caller_member_id,
    jsonb_build_object('slot_id', p_slot_id)
  );

  return v_booking_id;
end;
$$;

revoke execute on function public.book_slot(uuid) from public, anon;
grant  execute on function public.book_slot(uuid) to authenticated;

comment on function public.book_slot(uuid) is
  'Phase 2 Slice 2.3 — book a slot for the caller (slot.status=booked, booking.status=active). Requires bookSlot permission. Emits bookingCreated.';

-- =============================================================================
-- 5. request_slot_swap
-- =============================================================================
create or replace function public.request_slot_swap(
  p_slot_id          uuid,
  p_target_member_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id          uuid := auth.uid();
  v_group_id           uuid;
  v_metadata           jsonb;
  v_assigned_member_id uuid;
  v_caller_member_id   uuid;
  v_target_active      boolean;
  v_vote_id            uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, metadata into v_group_id, v_metadata
  from public.resources
  where id = p_slot_id and resource_type = 'slot';
  if v_group_id is null then
    raise exception 'slot not found' using errcode = '02000';
  end if;
  if not public.has_permission(v_group_id, v_caller_id, 'bookSlot') then
    raise exception 'permission denied: bookSlot required' using errcode = '42501';
  end if;

  -- Resolve caller's member_id
  select id into v_caller_member_id
  from public.group_members
  where group_id = v_group_id and user_id = v_caller_id and active;
  if v_caller_member_id is null then
    raise exception 'caller not active member' using errcode = '42501';
  end if;

  -- Only the current assigned holder can request a swap
  v_assigned_member_id := nullif(v_metadata->>'assigned_member_id', '')::uuid;
  if v_assigned_member_id is null then
    raise exception 'slot is unassigned, nothing to swap' using errcode = '22023';
  end if;
  if v_assigned_member_id <> v_caller_member_id then
    raise exception 'only the assigned holder can request a swap' using errcode = '42501';
  end if;

  -- Verify target is an active member
  select active into v_target_active
  from public.group_members
  where id = p_target_member_id and group_id = v_group_id;
  if v_target_active is null then
    raise exception 'target member not in group' using errcode = '02000';
  end if;
  if not v_target_active then
    raise exception 'target member not active' using errcode = '22023';
  end if;
  if p_target_member_id = v_caller_member_id then
    raise exception 'cannot swap with yourself' using errcode = '22023';
  end if;

  -- Open vote of type 'slot_swap'. start_vote auto-emits voteOpened
  -- and seeds vote_casts for all active members. Vote outcome →
  -- actual swap execution lands in Slice 2.5 (finalize handler).
  v_vote_id := public.start_vote(
    v_group_id,
    'slot_swap',
    p_slot_id,
    'Solicitud de swap de cupo',
    null,
    jsonb_build_object(
      'from_member_id',   v_caller_member_id::text,
      'to_member_id',     p_target_member_id::text,
      'slot_id',          p_slot_id::text
    ),
    null, null, null, null, null
  );

  perform public.record_system_event(
    v_group_id,
    'slotSwapRequested',
    p_slot_id,
    v_caller_member_id,
    jsonb_build_object(
      'vote_id',          v_vote_id,
      'target_member_id', p_target_member_id
    )
  );

  return v_vote_id;
end;
$$;

revoke execute on function public.request_slot_swap(uuid, uuid) from public, anon;
grant  execute on function public.request_slot_swap(uuid, uuid) to authenticated;

comment on function public.request_slot_swap(uuid, uuid) is
  'Phase 2 Slice 2.3 — open a vote of type slot_swap to transfer an assigned slot to another member. Requires bookSlot permission + caller must be the current assigned holder. Emits slotSwapRequested + voteOpened (via start_vote). Vote outcome execution = Slice 2.5.';
