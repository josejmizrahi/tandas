-- 00030 — Register dispatch-notifications cron (every 1 minute).
--
-- Drains notifications_outbox to APNs. Mirror del patrón usado por los
-- otros crons del proyecto (process-system-events-every-minute,
-- finalize-fine-reviews-hourly, auto-close-events-hourly,
-- finalize-appeal-votes-15min): pg_net.http_post con anon JWT
-- hardcoded en Authorization. La función internamente usa
-- SUPABASE_SERVICE_ROLE_KEY env para acceso DB; el JWT del request solo
-- pasa el verify_jwt=true gate.
--
-- El anon JWT es público (el iOS app lo expone como TANDAS_SUPABASE_ANON_KEY).
-- Hardcodearlo aquí no es leak — solo es el patrón que el proyecto adoptó
-- para que los crons puedan invocar functions sin Vault.
--
-- Idempotency: cron.schedule es upsert-by-name. Re-aplicar reemplaza
-- schedule + command de 'dispatch-notifications-every-minute' sin
-- crear duplicado.

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'dispatch-notifications-every-minute',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://fpfvlrwcskhgsjuhrjpz.supabase.co/functions/v1/dispatch-notifications',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZwZnZscndjc2toZ3NqdWhyanB6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1MTU4NTIsImV4cCI6MjA5MzA5MTg1Mn0.Cy5fWfdPv1cqhPdy2UTI-cY7eApnG9UPoBv94EkGGBc'
    ),
    body := '{}'::jsonb
  );
  $$
);
