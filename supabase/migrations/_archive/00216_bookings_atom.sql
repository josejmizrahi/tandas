-- 00216 — bookings atom table + book_slot refactor.
--
-- Closes Constitution §15 "Resource ≠ Action" for the slot/booking pair.
-- Today `book_slot` (mig 00070) writes into `public.resources` with
-- `resource_type='booking'`. That violates two invariants:
--
--   1. Doctrine — bookings are actions, not objects. Per Constitution
--      §7 they belong as an append-only atom (table `public.bookings`),
--      same shape as `ledger_entries` / `rsvp_actions` / `check_in_actions`.
--   2. Schema — mig 00147 froze `resources.resource_type` to the
--      canonical 6 values (`event, fund, asset, space, slot, right`).
--      'booking' is NOT in the CHECK, so every call to `book_slot` since
--      mig 00147 has failed with check_violation. The breakage is
--      currently invisible because prod has zero bookings (verified
--      2026-05-15), but slot lifecycle is broken end-to-end.
--
-- Changes
-- =======
--   1. New table `public.bookings`. Append-only atom: id, group_id,
--      slot_id (FK → resources), member_id (FK → group_members),
--      metadata jsonb, created_at, created_by. The atom records the
--      claim, never the lifecycle — cancellation / expiration land as
--      separate `system_events` rows (`bookingCancelled`,
--      `bookingExpired`; both already whitelisted).
--
--   2. Atom guard: `bookings_atom_guard` BEFORE UPDATE OR DELETE →
--      reuses `public.atom_no_mutation_guard()` (mig 00103) to enforce
--      append-only at the row level.
--
--   3. RLS: SELECT for group members (mirrors ledger_entries mig 00078).
--      No direct INSERT for clients — all writes flow through the
--      SECURITY DEFINER RPC `book_slot`.
--
--   4. Refactor `book_slot` to INSERT into `bookings` instead of
--      `resources`. Slot status update + `metadata.booking_id` stamping
--      and the `bookingCreated` emit are preserved. Same RPC name +
--      signature + return shape — callers don't change.
--
-- Out of scope (intentional, follow-up):
--   - `cancel_booking` / `expire_booking` writers. The `bookingCancelled`
--     and `bookingExpired` event types are whitelisted but no RPC fires
--     them today (and none existed pre-refactor either). When demand
--     pulls, they emit system_events; the projection `bookings_view`
--     joins to derive current status.
--   - `bookings_view` projection. Until cancellation atoms exist, every
--     bookings row is implicitly active; no derivation needed. View
--     lands with the cancel_booking slice.
--   - Stale `modules.slot_assignment.provided_resource_types` includes
--     'booking' (mig 00065 line 30). Cosmetic — that column is
--     documentation, not enforcement. Cleanup deferred.

-- =============================================================================
-- 1. bookings table
-- =============================================================================

create table if not exists public.bookings (
  id          uuid        primary key default gen_random_uuid(),
  group_id    uuid        not null references public.groups(id)        on delete cascade,
  slot_id     uuid        not null references public.resources(id)     on delete cascade,
  member_id   uuid        not null references public.group_members(id) on delete restrict,
  metadata    jsonb       not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  created_by  uuid        references auth.users(id) on delete set null
);

comment on table public.bookings is
  'Append-only atom: a booking claim placed on a slot resource. One row per booking, mutation rejected by bookings_atom_guard. Cancellation / expiration land as separate system_events rows (bookingCancelled / bookingExpired). Constitution §7 + §15 — booking is action, not object.';

create index if not exists bookings_group_created_idx
  on public.bookings (group_id, created_at desc);
create index if not exists bookings_slot_idx
  on public.bookings (slot_id);
create index if not exists bookings_member_idx
  on public.bookings (member_id);

-- =============================================================================
-- 2. Append-only guard
-- =============================================================================

drop trigger if exists bookings_atom_guard on public.bookings;
create trigger bookings_atom_guard
  before update or delete on public.bookings
  for each row execute function public.atom_no_mutation_guard();

-- =============================================================================
-- 3. RLS — SELECT for group members; no direct writes from clients
-- =============================================================================

alter table public.bookings enable row level security;

drop policy if exists "bookings_select_member" on public.bookings;
create policy "bookings_select_member" on public.bookings
  for select to authenticated
  using (public.is_group_member(group_id, auth.uid()));

-- INSERT/UPDATE/DELETE intentionally NOT granted to authenticated.
-- Writes flow through `book_slot` (SECURITY DEFINER); the guard blocks
-- UPDATE/DELETE on every role. service_role retains full access for
-- migrations + admin ops.
revoke insert, update, delete on public.bookings from authenticated, anon, public;

-- =============================================================================
-- 4. book_slot refactor — write to bookings instead of resources
-- =============================================================================

create or replace function public.book_slot(p_slot_id uuid)
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

  select id into v_caller_member_id
  from public.group_members
  where group_id = v_group_id and user_id = v_caller_id and active;
  if v_caller_member_id is null then
    raise exception 'caller not active member' using errcode = '42501';
  end if;

  v_assigned_member_id := nullif(v_metadata->>'assigned_member_id', '')::uuid;
  if v_assigned_member_id is not null and v_assigned_member_id <> v_caller_member_id then
    raise exception 'slot assigned to a different member' using errcode = '42501';
  end if;

  -- Atom write: append a row to bookings. Note this is the same
  -- semantic record that mig 00070 used to push into resources WHERE
  -- resource_type='booking' — only the storage moves.
  insert into public.bookings (group_id, slot_id, member_id, metadata, created_by)
  values (
    v_group_id,
    p_slot_id,
    v_caller_member_id,
    jsonb_build_object('booked_at', now()),
    v_caller_id
  )
  returning id into v_booking_id;

  -- Slot resource state update — same as before. The booking_id stamp
  -- in metadata gives the slot a back-reference to its active booking
  -- atom so the polymorphic ResourceRow decoder still works.
  update public.resources
     set status   = 'booked',
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
  'Books a slot for the caller. Validates slot exists + is bookable (unassigned or assigned-to-caller), caller has bookSlot permission. Inserts an append-only row in public.bookings (mig 00216), stamps slot.metadata.booking_id, flips slot.status to ''booked'', and emits bookingCreated. Returns the booking id. Refactored 00216: prior version wrote into public.resources WHERE resource_type=''booking'' which violated mig 00147''s frozen resource_type CHECK.';
