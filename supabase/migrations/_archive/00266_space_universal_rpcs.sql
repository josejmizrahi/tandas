-- 00266 — Space universal lifecycle RPCs (Plans/Active/Space.md §28).
--
-- 9 SECURITY DEFINER RPCs that materialize the canonical space lifecycle
-- per the doctrinal model: booking + waitlist + access + check-in +
-- metadata + archive. Each is gated by `is_group_member` (or stricter
-- when noted) — finer-grained governance lives in `rules` +
-- `group_policies` (Constitution Article 7).
--
-- Each RPC follows the same shape as create_space (mig 00207) +
-- asset RPCs (mig 00210):
--   1. auth.uid() check.
--   2. resolve target row + group_id + resource_type='space' assertion.
--   3. is_group_member / has_permission gate.
--   4. input validation.
--   5. mutate (`bookings` insert OR `resources.metadata` cache update).
--   6. record_system_event(...) — the atom is the truth.
--
-- Doctrine
-- ========
--   - Space.md §8: bookings are atoms, not space state. `bookings`
--     (mig 00216) is the canonical table. `slot_id` column is reused
--     polymorphically as "target resource id" — same wire shape as
--     book_slot. A future rename slice can promote it to
--     `target_resource_id` once RLS + edge fns + iOS callers are
--     coordinated.
--   - Space.md §12: waitlist is an ordered projection over
--     `spaceWaitlistJoined` minus `spaceWaitlistPromoted` atoms. No
--     `waitlist_json` array in metadata.
--   - Space.md §13: access lives in `spaceAccessGranted` /
--     `spaceAccessRevoked` atoms — no `granted_members` array. Future
--     `space_access_view` derives the active grant set.
--   - Space.md §17: status is derived. We do NOT flip
--     `resources.status` to 'booked' or 'occupied' on the space row;
--     the booking atom is the truth and the projection reads it.
--
-- Out of scope (intentional, follow-up):
--   - `cancel_booking` covers active bookings; it does NOT auto-promote
--     the top of the waitlist. The follow-up `promote_space_from_waitlist`
--     RPC is callable from a trigger/cron when overlap drops below
--     capacity. Wiring lives in a Phase 2 cron slice.
--   - `expire_booking` is callable by service_role only — it's intended
--     for a cron that fires when `metadata.ends_at` passes without
--     check-in. The cron itself ships in a later slice; the RPC lands
--     now so the projection has the atom shape ready.
--   - Overlap detection: we count active bookings within the requested
--     window and compare to `metadata.capacity`. We do NOT model
--     time-band partial overlap (e.g. "11:00-12:30 overlaps 12:00-13:00
--     by 30 min"). For Phase 2 every booking is treated as a unit
--     claim; finer overlap semantics land with the time-band scheduling
--     UI in Phase 3.

-- =============================================================================
-- helper: count of active (non-cancelled, non-expired) bookings on a space
-- =============================================================================

create or replace function public.space_active_booking_count(p_space_id uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int
  from public.bookings b
  where b.slot_id = p_space_id
    and not exists (
      select 1 from public.system_events se
      where se.event_type in ('bookingCancelled', 'bookingExpired')
        and (se.payload->>'booking_id')::uuid = b.id
    );
$$;

revoke execute on function public.space_active_booking_count(uuid) from public, anon;
grant  execute on function public.space_active_booking_count(uuid) to authenticated, service_role;

comment on function public.space_active_booking_count(uuid) is
  'Active booking count for a space (resource_id reused as bookings.slot_id polymorphically). Excludes bookings retired by a bookingCancelled / bookingExpired atom. Used by book_space + join_waitlist capacity gates and by space_capacity_view.';

-- =============================================================================
-- 1. book_space — claim the entire space for a window
-- =============================================================================

create or replace function public.book_space(
  p_space_id  uuid,
  p_starts_at timestamptz default null,
  p_ends_at   timestamptz default null,
  p_notes     text        default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id        uuid := auth.uid();
  v_group_id         uuid;
  v_resource_type    text;
  v_metadata         jsonb;
  v_capacity         int;
  v_active_count     int;
  v_caller_member_id uuid;
  v_booking_id       uuid;
  v_capacity_reached boolean := false;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type, metadata
    into v_group_id, v_resource_type, v_metadata
  from public.resources
  where id = p_space_id and archived_at is null;
  if v_group_id is null then
    raise exception 'space not found or archived' using errcode = '02000';
  end if;
  if v_resource_type <> 'space' then
    raise exception 'resource is not a space' using errcode = '22023';
  end if;

  -- Booking permission. Reuses bookSlot — same operation conceptually
  -- (Space.md §16 booking capability). A future slice may introduce
  -- bookSpace as a sibling permission if grain-of-access diverges.
  if not public.has_permission(v_group_id, v_caller_id, 'bookSlot') then
    raise exception 'permission denied: bookSlot required' using errcode = '42501';
  end if;

  if p_starts_at is not null and p_ends_at is not null and p_ends_at <= p_starts_at then
    raise exception 'ends_at must be after starts_at' using errcode = '22023';
  end if;

  select id into v_caller_member_id
    from public.group_members
   where group_id = v_group_id and user_id = v_caller_id and active;
  if v_caller_member_id is null then
    raise exception 'caller not active member' using errcode = '42501';
  end if;

  v_capacity     := nullif(v_metadata->>'capacity', '')::int;
  v_active_count := public.space_active_booking_count(p_space_id);

  -- Founder directive 2026-05-18: reject with hint when at capacity;
  -- UI catches and offers join_waitlist. Auto-routing would obscure
  -- whether the caller got a booking or a queue slot.
  if v_capacity is not null and v_active_count >= v_capacity then
    raise exception 'space at capacity: % active bookings (cap %). Call join_waitlist to queue.',
      v_active_count, v_capacity
      using errcode = '23514';
  end if;

  v_capacity_reached := (v_capacity is not null and v_active_count + 1 >= v_capacity);

  insert into public.bookings (
    group_id, slot_id, member_id, metadata, created_by
  ) values (
    v_group_id,
    p_space_id,   -- polymorphic: slot_id holds the space resource id
    v_caller_member_id,
    jsonb_strip_nulls(jsonb_build_object(
      'target_kind', 'space',
      'starts_at',   p_starts_at,
      'ends_at',     p_ends_at,
      'notes',       nullif(trim(coalesce(p_notes, '')), ''),
      'booked_at',   now()
    )),
    v_caller_id
  )
  returning id into v_booking_id;

  -- Atom level: same shape book_slot emits.
  perform public.record_system_event(
    v_group_id,
    'bookingCreated',
    p_space_id,
    v_caller_member_id,
    jsonb_strip_nulls(jsonb_build_object(
      'booking_id', v_booking_id::text,
      'target_kind', 'space',
      'starts_at',   p_starts_at,
      'ends_at',     p_ends_at
    ))
  );

  -- Space-level coarse atom: distinguishes "Palco entero reservado"
  -- from per-slot booking activity in the activity feed.
  perform public.record_system_event(
    v_group_id,
    'spaceBooked',
    p_space_id,
    v_caller_member_id,
    jsonb_strip_nulls(jsonb_build_object(
      'booking_id', v_booking_id::text,
      'starts_at',  p_starts_at,
      'ends_at',    p_ends_at,
      'notes',      nullif(trim(coalesce(p_notes, '')), '')
    ))
  );

  if v_capacity_reached then
    perform public.record_system_event(
      v_group_id,
      'spaceCapacityReached',
      p_space_id,
      v_caller_member_id,
      jsonb_build_object(
        'capacity',             v_capacity,
        'triggered_booking_id', v_booking_id::text
      )
    );
  end if;

  return v_booking_id;
end;
$$;

revoke execute on function public.book_space(uuid, timestamptz, timestamptz, text) from public, anon;
grant  execute on function public.book_space(uuid, timestamptz, timestamptz, text) to authenticated;

comment on function public.book_space(uuid, timestamptz, timestamptz, text) is
  'Books a space resource for the caller. Validates space is active, caller is group member with bookSlot permission, capacity not exceeded. Inserts append-only row in public.bookings (slot_id reused polymorphically as target resource id). Emits bookingCreated (atom-level), spaceBooked (coarse), and spaceCapacityReached when this booking lands at capacity. Rejects with capacity error when full — UI routes to join_waitlist. Plans/Active/Space.md §8.';

-- =============================================================================
-- 2. cancel_booking — terminate an active booking (caller or admin)
-- =============================================================================

create or replace function public.cancel_booking(
  p_booking_id uuid,
  p_reason     text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id    uuid := auth.uid();
  v_group_id     uuid;
  v_booker_id    uuid;
  v_target_id    uuid;
  v_target_type  text;
  v_already_done boolean;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select b.group_id, b.member_id, b.slot_id
    into v_group_id, v_booker_id, v_target_id
  from public.bookings b
  where b.id = p_booking_id;
  if v_group_id is null then
    raise exception 'booking not found' using errcode = '02000';
  end if;

  select resource_type into v_target_type
    from public.resources where id = v_target_id;
  if v_target_type is null then
    -- Defensive: orphan booking (target archived/deleted). Allow cancel
    -- so the atom record is consistent; no spaceReleased emission.
    v_target_type := 'unknown';
  end if;

  -- Caller may cancel their own booking; admins may cancel anyone's.
  if not (
    v_booker_id in (
      select id from public.group_members
       where group_id = v_group_id and user_id = v_caller_id and active
    )
    or public.is_group_admin(v_group_id, v_caller_id)
  ) then
    raise exception 'only the booker or an admin may cancel' using errcode = '42501';
  end if;

  -- Idempotent: don't emit a second cancellation atom if one exists.
  select exists (
    select 1 from public.system_events se
    where se.event_type in ('bookingCancelled', 'bookingExpired')
      and (se.payload->>'booking_id')::uuid = p_booking_id
  ) into v_already_done;
  if v_already_done then
    return;
  end if;

  -- For slot targets, bring the slot back to bookable state — mirrors
  -- the inverse of book_slot's status flip. Spaces and assets don't
  -- carry a mutable status field on the resource row (atoms are the
  -- truth), so the UPDATE is gated on target type.
  if v_target_type = 'slot' then
    update public.resources
       set status   = 'unassigned',
           metadata = metadata - 'booking_id'
     where id = v_target_id
       and (metadata->>'booking_id')::uuid = p_booking_id;
  end if;

  perform public.record_system_event(
    v_group_id,
    'bookingCancelled',
    v_target_id,
    v_booker_id,
    jsonb_strip_nulls(jsonb_build_object(
      'booking_id',   p_booking_id::text,
      'cancelled_by', v_caller_id,
      'target_kind',  v_target_type,
      'reason',       nullif(trim(coalesce(p_reason, '')), '')
    ))
  );

  if v_target_type = 'space' then
    perform public.record_system_event(
      v_group_id,
      'spaceReleased',
      v_target_id,
      v_booker_id,
      jsonb_strip_nulls(jsonb_build_object(
        'booking_id', p_booking_id::text,
        'reason',     'cancelled',
        'released_by', v_caller_id
      ))
    );
  end if;
end;
$$;

revoke execute on function public.cancel_booking(uuid, text) from public, anon;
grant  execute on function public.cancel_booking(uuid, text) to authenticated;

comment on function public.cancel_booking(uuid, text) is
  'Cancels an active booking (slot OR space). Caller must be the booker or a group admin. Idempotent: no-op if a bookingCancelled / bookingExpired atom already exists for this booking. Emits bookingCancelled always; emits spaceReleased additionally when target was a space. For slot targets also flips slot.status back to ''unassigned''. Plans/Active/Space.md §8/§9.';

-- =============================================================================
-- 3. expire_booking — cron-driven expiration (service_role only)
-- =============================================================================

create or replace function public.expire_booking(
  p_booking_id uuid,
  p_reason     text default 'expired'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id     uuid;
  v_booker_id    uuid;
  v_target_id    uuid;
  v_target_type  text;
  v_already_done boolean;
begin
  -- service_role-only — auth.uid() will be null when called from cron.
  -- We do NOT block on null caller because the cron context is the
  -- intended caller. Catch human callers by gating EXECUTE later.

  select b.group_id, b.member_id, b.slot_id
    into v_group_id, v_booker_id, v_target_id
  from public.bookings b
  where b.id = p_booking_id;
  if v_group_id is null then
    raise exception 'booking not found' using errcode = '02000';
  end if;

  select resource_type into v_target_type
    from public.resources where id = v_target_id;
  v_target_type := coalesce(v_target_type, 'unknown');

  select exists (
    select 1 from public.system_events se
    where se.event_type in ('bookingCancelled', 'bookingExpired')
      and (se.payload->>'booking_id')::uuid = p_booking_id
  ) into v_already_done;
  if v_already_done then
    return;
  end if;

  if v_target_type = 'slot' then
    update public.resources
       set status   = 'unassigned',
           metadata = metadata - 'booking_id'
     where id = v_target_id
       and (metadata->>'booking_id')::uuid = p_booking_id;
  end if;

  perform public.record_system_event(
    v_group_id,
    'bookingExpired',
    v_target_id,
    v_booker_id,
    jsonb_build_object(
      'booking_id',  p_booking_id::text,
      'target_kind', v_target_type,
      'reason',      p_reason
    )
  );

  if v_target_type = 'space' then
    perform public.record_system_event(
      v_group_id,
      'spaceReleased',
      v_target_id,
      v_booker_id,
      jsonb_build_object(
        'booking_id', p_booking_id::text,
        'reason',     p_reason
      )
    );
  end if;
end;
$$;

revoke execute on function public.expire_booking(uuid, text) from public, anon, authenticated;
grant  execute on function public.expire_booking(uuid, text) to service_role;

comment on function public.expire_booking(uuid, text) is
  'Cron-driven booking expiration. service_role only — meant for a future job that fires when bookings.metadata.ends_at passes without check-in. Idempotent; emits bookingExpired + (if space target) spaceReleased. p_reason ∈ {expired, no_check_in, …}. Plans/Active/Space.md §9.';

-- =============================================================================
-- 4. join_waitlist — append a member to the space waitlist
-- =============================================================================

create or replace function public.join_waitlist(
  p_space_id uuid,
  p_priority int  default 0,
  p_notes    text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id        uuid := auth.uid();
  v_group_id         uuid;
  v_resource_type    text;
  v_caller_member_id uuid;
  v_already_queued   boolean;
  v_event_id         uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type
    into v_group_id, v_resource_type
  from public.resources
  where id = p_space_id and archived_at is null;
  if v_group_id is null then
    raise exception 'space not found or archived' using errcode = '02000';
  end if;
  if v_resource_type <> 'space' then
    raise exception 'resource is not a space' using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  select id into v_caller_member_id
    from public.group_members
   where group_id = v_group_id and user_id = v_caller_id and active;
  if v_caller_member_id is null then
    raise exception 'caller not active member' using errcode = '42501';
  end if;

  -- Idempotent: if the caller already has an open waitlist row (joined
  -- without a later promotion / cancellation), no-op the duplicate.
  select exists (
    select 1
    from public.system_events j
    where j.event_type = 'spaceWaitlistJoined'
      and j.resource_id = p_space_id
      and j.member_id = v_caller_member_id
      and not exists (
        select 1 from public.system_events p
        where p.event_type = 'spaceWaitlistPromoted'
          and p.resource_id = p_space_id
          and p.member_id = v_caller_member_id
          and p.occurred_at > j.occurred_at
      )
  ) into v_already_queued;
  if v_already_queued then
    -- Return the existing waitlist atom id so the UI can address it
    -- without inserting a duplicate.
    select id into v_event_id
      from public.system_events
     where event_type = 'spaceWaitlistJoined'
       and resource_id = p_space_id
       and member_id = v_caller_member_id
     order by occurred_at desc
     limit 1;
    return v_event_id;
  end if;

  v_event_id := public.record_system_event(
    v_group_id,
    'spaceWaitlistJoined',
    p_space_id,
    v_caller_member_id,
    jsonb_strip_nulls(jsonb_build_object(
      'priority',  coalesce(p_priority, 0),
      'joined_at', now(),
      'notes',     nullif(trim(coalesce(p_notes, '')), '')
    ))
  );

  return v_event_id;
end;
$$;

revoke execute on function public.join_waitlist(uuid, int, text) from public, anon;
grant  execute on function public.join_waitlist(uuid, int, text) to authenticated;

comment on function public.join_waitlist(uuid, int, text) is
  'Appends the caller to the space waitlist. Any group member may call. Idempotent — if the caller has an active queue row (joined without later promotion), returns the existing atom id without duplicating. Emits spaceWaitlistJoined. Priority defaults to 0; founder / role-based bumps live in the rule engine. Plans/Active/Space.md §12.';

-- =============================================================================
-- 5. promote_space_from_waitlist — promote the top of the queue
-- =============================================================================

create or replace function public.promote_space_from_waitlist(
  p_space_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
  v_next_member_id uuid;
  v_next_joined_at timestamptz;
  v_event_id      uuid;
begin
  select group_id, resource_type
    into v_group_id, v_resource_type
  from public.resources
  where id = p_space_id;
  if v_group_id is null then
    raise exception 'space not found' using errcode = '02000';
  end if;
  if v_resource_type <> 'space' then
    raise exception 'resource is not a space' using errcode = '22023';
  end if;

  -- Either admin or service_role may promote. The cron path uses
  -- service_role; the manual override surfaces from the admin UI.
  if v_caller_id is not null and not public.is_group_admin(v_group_id, v_caller_id) then
    raise exception 'admin or service_role only' using errcode = '42501';
  end if;

  -- Top of waitlist: highest priority, then oldest join, that hasn't
  -- already been promoted.
  with joins as (
    select j.id, j.member_id,
           coalesce((j.payload->>'priority')::int, 0) as priority,
           j.occurred_at
    from public.system_events j
    where j.event_type = 'spaceWaitlistJoined'
      and j.resource_id = p_space_id
  ),
  active as (
    select j.*
    from joins j
    where not exists (
      select 1 from public.system_events p
      where p.event_type = 'spaceWaitlistPromoted'
        and p.resource_id = p_space_id
        and p.member_id = j.member_id
        and p.occurred_at > j.occurred_at
    )
  )
  select member_id, occurred_at
    into v_next_member_id, v_next_joined_at
  from active
  order by priority desc, occurred_at asc
  limit 1;

  if v_next_member_id is null then
    return null;
  end if;

  v_event_id := public.record_system_event(
    v_group_id,
    'spaceWaitlistPromoted',
    p_space_id,
    v_next_member_id,
    jsonb_build_object(
      'promoted_by',        coalesce(v_caller_id::text, 'service_role'),
      'original_joined_at', v_next_joined_at,
      'promoted_at',        now()
    )
  );

  return v_event_id;
end;
$$;

revoke execute on function public.promote_space_from_waitlist(uuid) from public, anon;
grant  execute on function public.promote_space_from_waitlist(uuid) to authenticated, service_role;

comment on function public.promote_space_from_waitlist(uuid) is
  'Promotes the top of the space waitlist (highest priority, oldest join, not yet promoted). Admin or service_role only — the cron flow is the canonical caller when capacity frees up after a cancellation / expiration. Returns the spaceWaitlistPromoted atom id, or null if the queue is empty. Plans/Active/Space.md §12.';

-- =============================================================================
-- 6. check_in_to_space — register presence at a space
-- =============================================================================
--
-- Reuses the existing check_in_actions atom (mig 00154) for storage so
-- attendance_view continues to work polymorphically. Emits checkInRecorded
-- (mig 00131 / 00154 atom name) — same atom that fires for event check-ins.
-- Projections distinguish space vs event check-ins by looking at the
-- resource_id's resource_type.

create or replace function public.check_in_to_space(
  p_space_id  uuid,
  p_booking_id uuid default null,
  p_notes      text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id        uuid := auth.uid();
  v_group_id         uuid;
  v_resource_type    text;
  v_caller_member_id uuid;
  v_action_id        uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type
    into v_group_id, v_resource_type
  from public.resources
  where id = p_space_id and archived_at is null;
  if v_group_id is null then
    raise exception 'space not found or archived' using errcode = '02000';
  end if;
  if v_resource_type <> 'space' then
    raise exception 'resource is not a space' using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  select id into v_caller_member_id
    from public.group_members
   where group_id = v_group_id and user_id = v_caller_id and active;
  if v_caller_member_id is null then
    raise exception 'caller not active member' using errcode = '42501';
  end if;

  -- Append to check_in_actions (mig 00154 atom). Same shape used by
  -- event check-ins; resource_id distinguishes target_type via the
  -- resources.resource_type join in attendance_view.
  insert into public.check_in_actions (
    group_id, resource_id, member_id, recorded_by, metadata
  )
  values (
    v_group_id,
    p_space_id,
    v_caller_member_id,
    v_caller_id,
    jsonb_strip_nulls(jsonb_build_object(
      'target_kind', 'space',
      'booking_id',  p_booking_id::text,
      'notes',       nullif(trim(coalesce(p_notes, '')), '')
    ))
  )
  returning id into v_action_id;

  -- Atom level: same event_type events use so existing rule engine
  -- triggers on checkInRecorded continue to apply to space check-ins.
  perform public.record_system_event(
    v_group_id,
    'checkInRecorded',
    p_space_id,
    v_caller_member_id,
    jsonb_strip_nulls(jsonb_build_object(
      'target_kind', 'space',
      'booking_id',  p_booking_id::text,
      'action_id',   v_action_id::text
    ))
  );

  return v_action_id;
end;
$$;

revoke execute on function public.check_in_to_space(uuid, uuid, text) from public, anon;
grant  execute on function public.check_in_to_space(uuid, uuid, text) to authenticated;

comment on function public.check_in_to_space(uuid, uuid, text) is
  'Records the caller''s arrival at a space. Reuses check_in_actions (mig 00154) for storage and emits checkInRecorded — same atom shape as event check-ins, with target_kind=space in the payload so projections can distinguish. Any group member may call; binding to a specific booking is optional. Plans/Active/Space.md §9.';

-- =============================================================================
-- 7. grant_space_access — admin override that bypasses normal gates
-- =============================================================================

create or replace function public.grant_space_access(
  p_space_id   uuid,
  p_member_id  uuid,
  p_until      timestamptz default null,
  p_reason     text        default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
  v_target_active boolean;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type
    into v_group_id, v_resource_type
  from public.resources
  where id = p_space_id and archived_at is null;
  if v_group_id is null then
    raise exception 'space not found or archived' using errcode = '02000';
  end if;
  if v_resource_type <> 'space' then
    raise exception 'resource is not a space' using errcode = '22023';
  end if;

  if not public.is_group_admin(v_group_id, v_caller_id) then
    raise exception 'admin only' using errcode = '42501';
  end if;

  select active into v_target_active
    from public.group_members
   where id = p_member_id and group_id = v_group_id;
  if v_target_active is null then
    raise exception 'target member not in this group' using errcode = '02000';
  end if;
  if not v_target_active then
    raise exception 'target member not active' using errcode = '22023';
  end if;

  perform public.record_system_event(
    v_group_id,
    'spaceAccessGranted',
    p_space_id,
    p_member_id,
    jsonb_strip_nulls(jsonb_build_object(
      'granted_by', v_caller_id,
      'until',      p_until,
      'reason',     nullif(trim(coalesce(p_reason, '')), '')
    ))
  );
end;
$$;

revoke execute on function public.grant_space_access(uuid, uuid, timestamptz, text) from public, anon;
grant  execute on function public.grant_space_access(uuid, uuid, timestamptz, text) to authenticated;

comment on function public.grant_space_access(uuid, uuid, timestamptz, text) is
  'Admin override granting a member access to a space outside the normal booking flow. Emits spaceAccessGranted; future space_access_view derives the active grant set. Optional p_until creates a time-boxed grant the cron can later auto-revoke. Plans/Active/Space.md §13.';

-- =============================================================================
-- 8. revoke_space_access — terminate a previously-granted access
-- =============================================================================

create or replace function public.revoke_space_access(
  p_space_id  uuid,
  p_member_id uuid,
  p_reason    text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type
    into v_group_id, v_resource_type
  from public.resources
  where id = p_space_id;
  if v_group_id is null then
    raise exception 'space not found' using errcode = '02000';
  end if;
  if v_resource_type <> 'space' then
    raise exception 'resource is not a space' using errcode = '22023';
  end if;

  if not public.is_group_admin(v_group_id, v_caller_id) then
    raise exception 'admin only' using errcode = '42501';
  end if;

  perform public.record_system_event(
    v_group_id,
    'spaceAccessRevoked',
    p_space_id,
    p_member_id,
    jsonb_strip_nulls(jsonb_build_object(
      'revoked_by', v_caller_id,
      'reason',     nullif(trim(coalesce(p_reason, '')), '')
    ))
  );
end;
$$;

revoke execute on function public.revoke_space_access(uuid, uuid, text) from public, anon;
grant  execute on function public.revoke_space_access(uuid, uuid, text) to authenticated;

comment on function public.revoke_space_access(uuid, uuid, text) is
  'Admin terminates a previously-granted space access. Emits spaceAccessRevoked; projection (space_access_view, follow-up) folds grant/revoke pairs into the current active set. Plans/Active/Space.md §13.';

-- =============================================================================
-- 9. update_space_metadata — patch name / capacity / location / description
-- =============================================================================

create or replace function public.update_space_metadata(
  p_space_id uuid,
  p_patch    jsonb
)
returns public.resources
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
  v_old_name      text;
  v_new_name      text;
  v_new_row       public.resources;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type, metadata->>'name'
    into v_group_id, v_resource_type, v_old_name
  from public.resources
  where id = p_space_id and archived_at is null;
  if v_group_id is null then
    raise exception 'space not found or archived' using errcode = '02000';
  end if;
  if v_resource_type <> 'space' then
    raise exception 'resource is not a space' using errcode = '22023';
  end if;

  if not public.is_group_admin(v_group_id, v_caller_id) then
    raise exception 'admin only' using errcode = '42501';
  end if;

  if p_patch is null or p_patch = '{}'::jsonb then
    select * into v_new_row from public.resources where id = p_space_id;
    return v_new_row;
  end if;

  -- Defensive validation on the canonical keys the patch may carry.
  if p_patch ? 'capacity' and (p_patch->>'capacity')::int < 0 then
    raise exception 'capacity must be non-negative' using errcode = '22023';
  end if;
  if p_patch ? 'name' and length(trim(p_patch->>'name')) = 0 then
    raise exception 'name cannot be empty' using errcode = '22023';
  end if;

  update public.resources
     set metadata   = metadata || p_patch,
         updated_at = now()
   where id = p_space_id
  returning * into v_new_row;

  v_new_name := v_new_row.metadata->>'name';
  if v_new_name is distinct from v_old_name then
    -- The resourceRenamed trigger (mig 00186) fires on UPDATE when
    -- metadata->>'name' changes — no manual emit needed here.
    null;
  end if;

  return v_new_row;
end;
$$;

revoke execute on function public.update_space_metadata(uuid, jsonb) from public, anon;
grant  execute on function public.update_space_metadata(uuid, jsonb) to authenticated;

comment on function public.update_space_metadata(uuid, jsonb) is
  'Patches space metadata (name / capacity / location_name / location_lat / location_lng / description). Admin only — mirrors update_event_metadata (mig 00159). Validates capacity ≥ 0 and name non-empty when present. resourceRenamed atom emits automatically via the mig 00186 trigger when name changes. Plans/Active/Space.md §7.';
