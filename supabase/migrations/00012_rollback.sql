-- Rollback for 00012_event_layer_v1.sql
-- NOT applied automatically. Run manually in case of emergency.
-- Note: column drops on event_attendance/events would lose data; documented
-- but commented out by default.

drop function if exists public.next_event_for_group(uuid);
drop function if exists public.close_event_no_fines(uuid);
drop function if exists public.cancel_event(uuid, text);
drop function if exists public.check_in_v2(uuid, uuid, text, boolean, timestamptz);
drop function if exists public.create_event_v2(
  uuid, text, timestamptz, int, text, numeric, numeric, uuid, text, text, text, boolean, boolean
);

drop table if exists public.notification_tokens;

-- alter table public.event_attendance
--   drop column if exists check_in_method,
--   drop column if exists check_in_location_verified;

-- alter table public.events
--   drop column if exists duration_minutes,
--   drop column if exists cancellation_reason,
--   drop column if exists closed_at,
--   drop column if exists is_recurring_generated,
--   drop column if exists apply_rules,
--   drop column if exists location_lng,
--   drop column if exists location_lat,
--   drop column if exists description,
--   drop column if exists cover_image_url,
--   drop column if exists cover_image_name;

-- alter table public.groups
--   drop column if exists auto_generate_events;
