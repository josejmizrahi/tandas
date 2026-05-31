-- 00153 — Emit rsvp_actions atoms from event_attendance writes.
--
-- Constitution §14 step 5b.
--
-- Bug
-- ===
-- public.rsvp_actions was created in mig 00078 (atom table) and guarded
-- against mutation in mig 00103 (`rsvp_actions_atom_guard`), but no
-- writer was ever wired up. The table sat empty in prod (0 rows on
-- 2026-05-13) while public.event_attendance accumulated 13 rows of
-- canonical RSVP state. The mig 00145 trigger on event_attendance
-- (`trg_on_event_attendance_rsvp_action`) only emits Inbox
-- `user_actions` rows — not atoms. Net result: the constitution's
-- "atom = únicas verdad histórica" promise (§ art. 7) was not being
-- kept for RSVPs.
--
-- Fix
-- ===
-- Add a trigger on public.event_attendance that emits one
-- public.rsvp_actions row per:
--   - INSERT (every freshly-materialized roster slot, even when the
--     initial rsvp_status is 'pending'). Treating 'pending' as an
--     emitted atom keeps the atom log lossless — i.e. the future
--     `attendance_view` projection can reconstruct event_attendance
--     entirely from rsvp_actions + members + events without referring
--     back to event_attendance at all. That guarantee is needed for
--     step 5c (drop event_attendance) to be a no-data-loss move.
--   - UPDATE where rsvp_status actually transitions. Updates that only
--     touch arrived_at / plus_ones / etc. without changing rsvp_status
--     do not produce a new atom (those are check-in atoms, future).
--
-- Then backfill the 13 historical event_attendance rows so the atom
-- log holds the full pre-trigger history. Backfill uses direct INSERT
-- on rsvp_actions (the trigger is on event_attendance only, so no
-- cascade).
--
-- Member resolution
-- =================
-- rsvp_actions.member_id references group_members.id, while
-- event_attendance.user_id references auth.users.id. We resolve via
-- (events.group_id, event_attendance.user_id) → group_members.id.
-- The resolution lives inside the trigger so callers don't have to
-- thread member_id through every set_rsvp / create_event path.
--
-- Resource resolution
-- ===================
-- rsvp_actions.resource_id = event_attendance.event_id. Per mig 00039
-- `resources.id = events.id`, so the same UUID is valid in both
-- spaces. This stays true after step 5c flips writers to resources.
--
-- Idempotency
-- ===========
-- - The function uses CREATE OR REPLACE; the trigger DROPs IF EXISTS.
-- - The backfill is INSERT … SELECT … WHERE NOT EXISTS so re-running
--   the migration on a partially-backfilled environment is a no-op.
-- - The atom_no_mutation_guard from 00103 stays in force; we only
--   ever INSERT here.

-- =============================================================================
-- 1. Trigger function
-- =============================================================================

create or replace function public.emit_rsvp_action_from_attendance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id    uuid;
  v_member_id   uuid;
  v_recorded_at timestamptz;
begin
  -- UPDATE that doesn't move rsvp_status is not an RSVP atom event.
  if tg_op = 'UPDATE'
     and old.rsvp_status is not distinct from new.rsvp_status then
    return new;
  end if;

  -- Resolve group_id via events. Step 5c will swap this to resources
  -- (resources.id = events.id, so the read is interchangeable).
  select group_id into v_group_id
    from public.events
   where id = new.event_id;

  if v_group_id is null then
    -- Orphan attendance row (shouldn't happen given the FK); silently
    -- bail instead of failing the parent INSERT/UPDATE.
    return new;
  end if;

  -- Resolve member_id from (group, user). If the user isn't a current
  -- group_member (system actor, deleted membership) we skip atom
  -- emission — rsvp_actions.member_id is NOT NULL.
  select id into v_member_id
    from public.group_members
   where group_id = v_group_id
     and user_id  = new.user_id
   limit 1;

  if v_member_id is null then
    return new;
  end if;

  v_recorded_at := coalesce(new.rsvp_at, now());

  insert into public.rsvp_actions (
    resource_id, member_id, status, recorded_at, metadata
  ) values (
    new.event_id,
    v_member_id,
    new.rsvp_status,
    v_recorded_at,
    jsonb_strip_nulls(jsonb_build_object(
      'plus_ones',          new.plus_ones,
      'cancelled_same_day', new.cancelled_same_day,
      'waitlist_position',  new.waitlist_position,
      'attendance_id',      new.id
    ))
  );

  return new;
end;
$$;

revoke execute on function public.emit_rsvp_action_from_attendance() from public, anon;
grant  execute on function public.emit_rsvp_action_from_attendance() to authenticated, service_role;

comment on function public.emit_rsvp_action_from_attendance() is
  'Constitution §14 step 5b: emits a public.rsvp_actions atom on every event_attendance INSERT and on UPDATEs that change rsvp_status. Resolves member_id from (events.group_id, user_id). Resource resolution leans on resources.id = events.id from mig 00039.';

drop trigger if exists trg_emit_rsvp_action on public.event_attendance;
create trigger trg_emit_rsvp_action
  after insert or update on public.event_attendance
  for each row
  execute function public.emit_rsvp_action_from_attendance();

-- =============================================================================
-- 2. Backfill historical attendance → atoms
-- =============================================================================
-- 13 prod rows on 2026-05-13. The NOT EXISTS guard keeps re-runs a
-- no-op (per-(resource,member) one atom).

insert into public.rsvp_actions (resource_id, member_id, status, recorded_at, metadata)
select
  ea.event_id                                        as resource_id,
  gm.id                                              as member_id,
  ea.rsvp_status                                     as status,
  coalesce(ea.rsvp_at, e.created_at, now())          as recorded_at,
  jsonb_strip_nulls(jsonb_build_object(
    'plus_ones',          ea.plus_ones,
    'cancelled_same_day', ea.cancelled_same_day,
    'waitlist_position',  ea.waitlist_position,
    'attendance_id',      ea.id,
    'backfill',           true
  ))                                                 as metadata
from public.event_attendance ea
join public.events        e  on e.id = ea.event_id
join public.group_members gm on gm.group_id = e.group_id
                            and gm.user_id  = ea.user_id
where not exists (
  select 1
    from public.rsvp_actions ra
   where ra.resource_id = ea.event_id
     and ra.member_id   = gm.id
);
