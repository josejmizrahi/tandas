-- Rollback for 00013_events_robustness.sql
-- NOT applied automatically.

drop function if exists public.promote_from_waitlist(uuid);
drop function if exists public.set_rsvp_v2(uuid, text, int, text);
drop function if exists public.event_seat_count(uuid);

drop index if exists public.idx_attendance_waitlist;

alter table public.event_attendance
  drop column if exists waitlist_position,
  drop column if exists plus_ones;

-- Restore the original rsvp_status check (drop 'waitlisted').
-- WARNING: this will fail if there are any rows with rsvp_status='waitlisted'.
alter table public.event_attendance
  drop constraint if exists event_attendance_rsvp_status_check;
alter table public.event_attendance
  add constraint event_attendance_rsvp_status_check
  check (rsvp_status in ('pending','going','maybe','declined'));

alter table public.events
  drop column if exists max_plus_ones_per_member,
  drop column if exists allow_plus_ones,
  drop column if exists capacity_max;
