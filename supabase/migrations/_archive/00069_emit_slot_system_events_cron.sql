-- 00069 — Schedule emit-slot-system-events every 5 minutes.
--
-- Phase 2 Slice 2.2: drives slotExpired SystemEvent emission for slot
-- resources whose ends_at has passed without a booking. Rule engine
-- (process-system-events cron, Slice 2.1 evaluators) then materializes
-- consequences (e.g. shared_no_show fines).
--
-- Schedule rationale: 5 min matches emit-deadline-events (events module
-- equivalent). Slots aren't sub-minute critical — a 5-min lag between
-- expiry and fine emission is acceptable. Tighten to '* * * * *' if
-- product feedback wants near-realtime (cost: 12x more cron invocations
-- + 12x more idempotent no-op DB scans).
--
-- Auth: anon JWT hardcoded matches the project pattern (mig 00030 +
-- runtime-only crons for process-system-events / auto-close-events /
-- finalize-*). The function uses SERVICE_ROLE_KEY env internally for DB
-- access; the JWT only satisfies verify_jwt=true on the function gate.
--
-- Idempotency: cron.schedule is upsert-by-name. Re-applying replaces the
-- schedule + command without creating a duplicate job.

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'emit-slot-system-events-5min',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := 'https://fpfvlrwcskhgsjuhrjpz.supabase.co/functions/v1/emit-slot-system-events',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZwZnZscndjc2toZ3NqdWhyanB6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1MTU4NTIsImV4cCI6MjA5MzA5MTg1Mn0.Cy5fWfdPv1cqhPdy2UTI-cY7eApnG9UPoBv94EkGGBc'
    ),
    body := '{}'::jsonb
  );
  $$
);
