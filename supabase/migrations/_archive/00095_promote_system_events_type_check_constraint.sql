-- 00095 — Promote the system_events.event_type whitelist from soft NOTICE
-- (00092) to a hard CHECK constraint.
--
-- 00092 shipped soft validation while we audited zombie rows in prod.
-- That audit found zero: the live event_types are exactly the canonical
-- set (rsvpSubmitted, fineOfficialized, rsvpChangedSameDay). Every
-- direct insert in migrations / edge functions uses literals that
-- belong to the whitelist. The codegen sync test
-- (`_tests/system_event_whitelist_sync.test.ts`) guards drift between
-- the Swift enum and the SQL whitelist on PR.
--
-- Promoting now gets us hard rejection at insert time (instead of
-- NOTICE noise in logs) — typos surface immediately as transaction
-- failures, no silent acceptance into the queue.
--
-- The CHECK is `NOT VALID` first to avoid table scanning the existing
-- rows (none are out of whitelist per the audit, but NOT VALID +
-- VALIDATE is the standard Postgres pattern for adding a CHECK to a
-- populated table without an exclusive lock). Then we VALIDATE which
-- takes a shared lock only.

alter table public.system_events
  add constraint system_events_event_type_known_chk
  check (public.is_known_system_event_type(event_type)) not valid;

alter table public.system_events
  validate constraint system_events_event_type_known_chk;

comment on constraint system_events_event_type_known_chk on public.system_events is
  'Hard whitelist enforcement for event_type — must match a value in is_known_system_event_type. Promoted from 00092 soft NOTICE after the prod audit confirmed zero zombie rows. Update the SQL whitelist via a new migration whenever the SystemEventType Swift enum grows; the codegen sync test catches drift on PR.';
