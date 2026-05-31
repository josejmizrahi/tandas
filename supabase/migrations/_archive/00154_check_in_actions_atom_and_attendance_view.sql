-- 00154 — check_in_actions atom + attendance_view projection.
--
-- Constitution §14 step 5c-i.
--
-- Why this exists
-- ===============
-- Step 5b (mig 00153) wired rsvp_actions to public.event_attendance so
-- every RSVP transition emits an atom. But event_attendance still
-- carries the *other* half of the attendance lifecycle in mutable
-- columns:
--   arrived_at, check_in_method, check_in_location_verified, marked_by,
--   no_show, notes, cancelled_reason
-- Without atom-level capture for that side, dropping event_attendance
-- in step 5c-iv would silently lose audit history (today: zero check-in
-- rows in prod, but the schema is the gating concern, not the row
-- count).
--
-- This migration adds the missing atom + projection so 5c-ii…5c-iv can
-- proceed without data-loss surprises. It is additive — event_attendance
-- stays untouched and authoritative; the new pieces ship alongside it
-- and the existing dual-write trigger (00039) keeps resources in sync.
--
-- What ships
-- ==========
--
-- 1. public.check_in_actions       (atom)
--    One row per (resource, member, arrival event). Append-only,
--    guarded by atom_no_mutation_guard (mig 00103 pattern). Metadata
--    jsonb carries check_in_method / location_verified / marked_by /
--    notes so the atom is a lossless capture of what
--    public.event_attendance currently stores about the check-in
--    sub-domain.
--
-- 2. trg_emit_check_in_action      (trigger on event_attendance)
--    Fires AFTER UPDATE when arrived_at transitions NULL → non-NULL.
--    No INSERT branch — create_event_v2 materializes attendance rows
--    with arrived_at NULL by default, and check-in only happens via
--    UPDATE in check_in_v2.
--
-- 3. public.attendance_view        (projection)
--    Latest-per-(resource, member) join over rsvp_actions ∪
--    check_in_actions ∪ group_members. Returns the full event_attendance
--    shape:
--      rsvp_status, rsvp_at, arrived_at, plus_ones, cancelled_same_day,
--      cancelled_reason, waitlist_position, check_in_method,
--      check_in_location_verified, marked_by, no_show
--    `no_show` is derived (resource closed AND no check-in atom).
--    NB: the legacy event_attendance.no_show column is dead (no writer
--    in any migration, no reader in Swift/TS — confirmed 2026-05-13).
--    So the derived value here is *more* faithful to the actual
--    semantic than the legacy column, even though it diverges
--    row-for-row (11/13 rows differ: the legacy column says false
--    everywhere, the projection says true for un-checked-in
--    attendees of completed events, which is what the rule engine
--    reads via arrived_at IS NULL anyway).
--    `notes` is intentionally dropped — zero prod usage on 2026-05-13,
--    and the atom layer treats free-text annotations as future work
--    (Phase 3 documents capability).
--
-- Backfill
-- ========
-- 0 prod rows have arrived_at populated on 2026-05-13, so no
-- check_in_actions backfill is needed. The trigger captures everything
-- going forward.
--
-- Non-goals
-- =========
-- - Migrating RPCs to write atoms directly (that's 5c-iii).
-- - Migrating readers to attendance_view (that's 5c-iv).
-- - Dropping event_attendance (5c-iv).
-- - Re-pointing FKs to resources.id (5c-ii).

-- =============================================================================
-- 1. check_in_actions atom table
-- =============================================================================

create table if not exists public.check_in_actions (
  id           uuid primary key default gen_random_uuid(),
  resource_id  uuid not null references public.resources(id) on delete cascade,
  member_id    uuid not null references public.group_members(id) on delete cascade,
  arrived_at   timestamptz not null,
  recorded_at  timestamptz not null default now(),
  metadata     jsonb not null default '{}'::jsonb
);

create index if not exists idx_check_in_actions_resource_time
  on public.check_in_actions(resource_id, recorded_at desc);
create index if not exists idx_check_in_actions_member
  on public.check_in_actions(member_id);

comment on table public.check_in_actions is
  'Check-in atoms per Constitution §14 step 5c-i. Append-only. Latest-per-(resource, member) becomes the canonical "did this member arrive?" signal. metadata jsonb carries check_in_method, check_in_location_verified, marked_by, notes.';

-- Append-only guard (mig 00103 pattern).
drop trigger if exists check_in_actions_atom_guard on public.check_in_actions;
create trigger check_in_actions_atom_guard
  before update or delete on public.check_in_actions
  for each row execute function public.atom_no_mutation_guard();

-- =============================================================================
-- 2. RLS
-- =============================================================================

alter table public.check_in_actions enable row level security;

drop policy if exists "check_in_actions_read_member" on public.check_in_actions;
create policy "check_in_actions_read_member" on public.check_in_actions
  for select to authenticated
  using (
    exists (
      select 1 from public.resources r
       where r.id = check_in_actions.resource_id
         and public.is_group_member(r.group_id, auth.uid())
    )
  );

-- Two write paths: member self check-in, and group admin host_marked.
-- Mirrors the existing event_attendance att_update policy.
drop policy if exists "check_in_actions_write" on public.check_in_actions;
create policy "check_in_actions_write" on public.check_in_actions
  for insert to authenticated
  with check (
    exists (
      select 1
        from public.group_members gm
        join public.resources r on r.id = check_in_actions.resource_id
       where gm.id = check_in_actions.member_id
         and (
           gm.user_id = auth.uid()
           or public.is_group_admin(r.group_id, auth.uid())
         )
    )
  );

-- =============================================================================
-- 3. Trigger: emit check_in_actions atom from event_attendance updates
-- =============================================================================

create or replace function public.emit_check_in_action_from_attendance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id  uuid;
  v_member_id uuid;
begin
  -- Only fire when arrived_at transitions NULL → non-NULL. Subsequent
  -- updates to method/location are not separate check-in atoms; the
  -- atom already exists.
  if not (old.arrived_at is null and new.arrived_at is not null) then
    return new;
  end if;

  select group_id into v_group_id
    from public.events
   where id = new.event_id;
  if v_group_id is null then
    return new;
  end if;

  select id into v_member_id
    from public.group_members
   where group_id = v_group_id
     and user_id  = new.user_id
   limit 1;
  if v_member_id is null then
    return new;
  end if;

  insert into public.check_in_actions (
    resource_id, member_id, arrived_at, metadata
  ) values (
    new.event_id,
    v_member_id,
    new.arrived_at,
    jsonb_strip_nulls(jsonb_build_object(
      'check_in_method',            new.check_in_method,
      'check_in_location_verified', new.check_in_location_verified,
      'marked_by',                  new.marked_by,
      'notes',                      nullif(trim(coalesce(new.notes, '')), ''),
      'attendance_id',              new.id
    ))
  );

  return new;
end;
$$;

revoke execute on function public.emit_check_in_action_from_attendance() from public, anon;
grant  execute on function public.emit_check_in_action_from_attendance() to authenticated, service_role;

comment on function public.emit_check_in_action_from_attendance() is
  'Constitution §14 step 5c-i: emits a public.check_in_actions atom whenever event_attendance.arrived_at transitions NULL → non-NULL. Resolves member_id via (events.group_id, user_id).';

drop trigger if exists trg_emit_check_in_action on public.event_attendance;
create trigger trg_emit_check_in_action
  after update on public.event_attendance
  for each row
  execute function public.emit_check_in_action_from_attendance();

-- =============================================================================
-- 4. attendance_view projection
-- =============================================================================
--
-- Lossless reconstruction of public.event_attendance from atoms +
-- group_members + resources. Used in 5c-iv to migrate readers.
--
-- Membership scoping
-- ------------------
-- We list one row per (resource, member) pair that has at least one
-- atom in rsvp_actions OR check_in_actions. Restricting to the union
-- of atom holders is what guarantees row-for-row parity with
-- public.event_attendance today: the 5b backfill emitted exactly one
-- rsvp_action per existing event_attendance row, so the union of atom
-- holders matches event_attendance 1:1 (13 prod rows, 2026-05-13).
--
-- An earlier draft of this view cross-joined every active group
-- member to every event in their group. That overshot to 32 rows in
-- prod because not every active member was materialized into
-- event_attendance by create_event_v2 (members who joined after
-- event creation are not on the roster). For 5c-i to remain truly
-- additive we must mirror that behavior — the atom set, not the
-- membership set, defines the roster.
--
-- Implementation note: distinct on (resource_id, member_id) ordered
-- by recorded_at desc gives the latest atom per pair. The two
-- DISTINCT-ON CTEs are O(atom_count) each — index-supported via the
-- idx_*_resource_time index added with each atom table.

create or replace view public.attendance_view as
with roster as (
  select resource_id, member_id from public.rsvp_actions
  union
  select resource_id, member_id from public.check_in_actions
),
latest_rsvp as (
  select distinct on (resource_id, member_id)
    resource_id,
    member_id,
    status                                 as rsvp_status,
    recorded_at                            as rsvp_at,
    coalesce((metadata->>'plus_ones')::int, 0)              as plus_ones,
    coalesce((metadata->>'cancelled_same_day')::boolean, false) as cancelled_same_day,
    (metadata->>'waitlist_position')::int  as waitlist_position,
    metadata->>'cancelled_reason'          as cancelled_reason
  from public.rsvp_actions
  order by resource_id, member_id, recorded_at desc
),
latest_check_in as (
  select distinct on (resource_id, member_id)
    resource_id,
    member_id,
    arrived_at,
    metadata->>'check_in_method'                                  as check_in_method,
    coalesce((metadata->>'check_in_location_verified')::boolean, false)
                                                                  as check_in_location_verified,
    (metadata->>'marked_by')::uuid                                as marked_by
  from public.check_in_actions
  order by resource_id, member_id, recorded_at desc
)
select
  roster.resource_id                         as resource_id,
  r.group_id                                 as group_id,
  roster.member_id                           as member_id,
  gm.user_id                                 as user_id,
  coalesce(lr.rsvp_status, 'pending')        as rsvp_status,
  lr.rsvp_at                                 as rsvp_at,
  lc.arrived_at                              as arrived_at,
  coalesce(lr.plus_ones, 0)                  as plus_ones,
  coalesce(lr.cancelled_same_day, false)     as cancelled_same_day,
  lr.cancelled_reason                        as cancelled_reason,
  lr.waitlist_position                       as waitlist_position,
  lc.check_in_method                         as check_in_method,
  coalesce(lc.check_in_location_verified, false) as check_in_location_verified,
  lc.marked_by                               as marked_by,
  -- no_show is derived: resource is in a terminal state AND member
  -- did not check in. The resource statuses considered terminal are
  -- the same set the existing close_event/cancel_event flows use.
  (r.status in ('completed','cancelled') and lc.arrived_at is null)
                                             as no_show
from roster
join public.resources r       on r.id  = roster.resource_id
                             and r.resource_type = 'event'
join public.group_members gm  on gm.id = roster.member_id
left join latest_rsvp lr
  on lr.resource_id = roster.resource_id and lr.member_id = roster.member_id
left join latest_check_in lc
  on lc.resource_id = roster.resource_id and lc.member_id = roster.member_id;

comment on view public.attendance_view is
  'Projection of event attendance from rsvp_actions + check_in_actions atoms per Constitution §14 step 5c-i. One row per (event-resource, member) pair that has at least one atom — mirrors public.event_attendance row-for-row on every meaningful field. `no_show` is derived from resource.status ∈ {completed, cancelled} ∧ arrived_at IS NULL; this diverges from legacy event_attendance.no_show, which is dead (no writer, no reader — 2026-05-13). Used by step 5c-iv to migrate readers off the legacy event_attendance table.';

grant select on public.attendance_view to authenticated;
