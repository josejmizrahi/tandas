-- 00095_rollback.sql
-- Drops the hard CHECK constraint on system_events.event_type, returning
-- enforcement to the 00094 soft-NOTICE path inside record_system_event.
-- Only run if 00095 starts rejecting legitimate inserts because the
-- whitelist function lags a new SystemEventType case (regenerate the
-- whitelist via a new migration instead, when possible).

alter table public.system_events
  drop constraint if exists system_events_event_type_known_chk;
