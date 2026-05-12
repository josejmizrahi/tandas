-- 00118_rollback.sql
-- Reverts the function-backed CHECK to the inline enum CHECK and
-- drops is_known_rsvp_status.

alter table public.event_attendance
  drop constraint if exists event_attendance_rsvp_status_check;

alter table public.event_attendance
  add constraint event_attendance_rsvp_status_check
  check (rsvp_status = any (array['pending'::text, 'going'::text, 'maybe'::text, 'declined'::text, 'waitlisted'::text]));

drop function if exists public.is_known_rsvp_status(text);
