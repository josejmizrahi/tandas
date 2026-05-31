-- 00118 — Delegate event_attendance.rsvp_status validation to a
-- function-backed CHECK constraint, mirroring the pattern set by
-- 00092/00095 for system_events.event_type.
--
-- Today the CHECK enumerates 'pending'|'going'|'maybe'|'declined'|
-- 'waitlisted' inline. Phase 2 adding a new status (e.g. 'tentative')
-- requires ALTER TABLE + constraint replacement. With a function-backed
-- CHECK, future whitelist updates are a `create or replace function`
-- away — no table-level DDL.
--
-- Prod values right now: pending (7), declined (2), going (2). All
-- match the new whitelist; the NOT VALID + VALIDATE swap is therefore
-- safe.

create or replace function public.is_known_rsvp_status(p_status text)
returns boolean
language sql
immutable
parallel safe
set search_path = public
as $$
  -- Keep in sync with
  -- ios/Packages/RuulCore/Sources/RuulCore/Events/RSVPStatus.swift.
  -- A new case in Swift requires a follow-up migration to update this
  -- function. CI's vote/system-event sync tests have a sibling for
  -- rsvp_status (rsvp_status_whitelist_sync.test.ts).
  select p_status = any (array[
    'pending',
    'going',
    'maybe',
    'declined',
    'waitlisted'
  ]);
$$;

revoke execute on function public.is_known_rsvp_status(text) from public, anon;
grant  execute on function public.is_known_rsvp_status(text) to authenticated, service_role;

comment on function public.is_known_rsvp_status(text) is
  'Whitelist check for event_attendance.rsvp_status values. Mirrors the iOS RSVPStatus enum. Backed by event_attendance_rsvp_status_check CHECK constraint (00118).';

alter table public.event_attendance
  drop constraint if exists event_attendance_rsvp_status_check;

alter table public.event_attendance
  add constraint event_attendance_rsvp_status_check
  check (public.is_known_rsvp_status(rsvp_status)) not valid;

alter table public.event_attendance
  validate constraint event_attendance_rsvp_status_check;

comment on constraint event_attendance_rsvp_status_check on public.event_attendance is
  'Hard whitelist enforcement for rsvp_status via is_known_rsvp_status (00118). Update the function to add new statuses — the constraint picks up the new whitelist automatically.';
