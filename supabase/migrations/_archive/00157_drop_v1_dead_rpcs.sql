-- 00157 — Drop dead V1 RPCs that have zero callers.
--
-- Constitution §14 step 5c-iii.C (scope-trimmed).
--
-- Audit (2026-05-13): grep across `supabase/`, `ios/Packages/`, plus
-- pg_proc.prosrc for SQL self-references found zero callers for:
--   - public.create_event(...)  — V1, replaced by create_event_v2 in mig 00012.
--   - public.set_rsvp(...)      — V1, replaced by set_rsvp_v2 in mig 00013.
--
-- Both predate the BigBang foundation (mig 00078) and write directly to
-- public.events / public.event_attendance using the V1 column shape
-- (without series_id, host rotation, plus_ones, etc). They sat in the
-- catalog as dead weight; dropping them removes two of the writers
-- 5c-iv needs to retire.
--
-- NOT dropped here (still have callers, in scope for a follow-up):
--   - evaluate_event_rules, roll_event_series — called by close_event.
--   - check_in_attendee, close_event_no_fines, promote_from_waitlist —
--     called by e2e tests and iOS EventRepository / RSVPRepository.
--   - create_event_v2, set_rsvp_v2, check_in_v2, cancel_event,
--     close_event — the V2 writers, still actively used by iOS + crons.
--
-- The V2 writers continue to target public.events / public.event_attendance.
-- The dual-write trigger (events_sync_to_resources, mig 00039) keeps
-- public.resources in lockstep so every consumer reading through the
-- 5c-iii.A/B drop-in views (events_view / attendance_view) sees fresh
-- data. Constitution §14 step 5c-iv will refactor the V2 writers and
-- drop the legacy tables in one focused move.

drop function if exists public.create_event(
  uuid,                       -- p_group_id
  timestamp with time zone,   -- p_starts_at
  timestamp with time zone,   -- p_ends_at
  text,                       -- p_location
  text,                       -- p_title
  uuid,                       -- p_host_id
  integer,                    -- p_cycle_number
  timestamp with time zone    -- p_rsvp_deadline
);

drop function if exists public.set_rsvp(
  uuid,  -- p_event_id
  text   -- p_status
);
