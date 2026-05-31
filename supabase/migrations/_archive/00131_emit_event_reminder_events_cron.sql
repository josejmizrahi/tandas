-- 00131 — Tier 4: schedule emit-event-reminder-events every 5 minutes.
--
-- Closes the loop on `hoursBeforeEvent` SystemEventType:
--   - Type exists since 00014 (declared/validated/decoded/evaluated).
--   - Rules use it: `dinner_host_no_menu` seeded by templates 00015 /
--     00018 / 00035 / 00038 / 00058 / 00059.
--   - The rule engine's `hoursBeforeEvent` evaluator (ruleEngine.ts:271)
--     targets the host and projects `scheduled_hours` onto context.
--   - Until this migration, **no upstream emitter** wrote those rows —
--     the rule never fired in prod. iOS catalog's ReminderCapability
--     pinned this as the explicit `Tier 4` blocker.
--
-- This migration schedules the new edge function `emit-event-reminder-events`
-- (Tier 4) at the same cadence as `emit-slot-system-events` (mig 00069)
-- and `emit-deadline-events`. The function is rule-driven: scans active
-- rules to discover distinct N values, then for each N emits one
-- system_event per event whose `starts_at ∈ (now + (N-1)h, now + Nh]`,
-- deduped against any existing row with the same (resource_id, hours).
--
-- Idempotency: `cron.schedule` is upsert-by-name. Re-applying replaces
-- schedule + command without creating a duplicate job.
--
-- Auth: anon JWT matches the project pattern (00030 + 00069). The
-- function uses SERVICE_ROLE_KEY internally for DB access; the JWT
-- only satisfies the function's verify_jwt gate.

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'emit-event-reminder-events-5min',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := 'https://fpfvlrwcskhgsjuhrjpz.supabase.co/functions/v1/emit-event-reminder-events',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZwZnZscndjc2toZ3NqdWhyanB6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1MTU4NTIsImV4cCI6MjA5MzA5MTg1Mn0.Cy5fWfdPv1cqhPdy2UTI-cY7eApnG9UPoBv94EkGGBc'
    ),
    body := '{}'::jsonb
  );
  $$
);
