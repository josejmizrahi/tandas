-- R.5V.3A.event.fix2 (2026-06-08) — Founder doctrina extendida:
-- location es 100% opcional. La mig anterior (r5v3a_event_location_fully_optional)
-- relajó las RPCs pero quedó el CHECK CONSTRAINT a nivel tabla.
--
-- Drop calendar_events_location_required así el shape "no virtual + no location"
-- es válido también a nivel storage.
--
-- Constraint original (now removed):
--   CHECK ((is_virtual = true) OR (location_text IS NOT NULL AND length(btrim(location_text)) > 0))

ALTER TABLE public.calendar_events
  DROP CONSTRAINT IF EXISTS calendar_events_location_required;
