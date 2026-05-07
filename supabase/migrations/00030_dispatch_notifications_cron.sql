-- 00030 — Register dispatch-notifications cron (every 1 minute).
--
-- Drains notifications_outbox to APNs. Mirror of how the rest of the
-- crons are wired in this project (registered via SQL — process-system-
-- events, finalize-votes, finalize-fine-reviews, send-fine-reminders,
-- auto-close-events, auto-generate-events, emit-deadline-events all
-- live as rows in cron.job, not in repo migrations until now).
--
-- Anchoring it in a migration from this point forward keeps cron config
-- reviewable + reproducible. If Supabase ever prunes cron.job rows
-- (e.g. branch reset), re-applying this migration restores the schedule.
--
-- Idempotency: cron.schedule is upsert-by-name. Re-running this migration
-- replaces the schedule + command for 'dispatch-notifications-every-
-- minute' without creating a duplicate row.
--
-- Auth: pg_net injects the service_role JWT via the
-- `app.settings.service_role_key` GUC that Supabase's managed Postgres
-- exposes. The function's internal verify_jwt is permissive of service
-- role.

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'dispatch-notifications-every-minute',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://fpfvlrwcskhgsjuhrjpz.supabase.co/functions/v1/dispatch-notifications',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key', true),
      'Content-Type',  'application/json'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 50000
  );
  $$
);
