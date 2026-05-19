-- 20260519145824 rollback (mig 00346) — re-schedule finalize-appeal-votes-15min cron.
--
-- WARNING: This restores the broken state. The cron POSTs to a function
-- that returns HTTP 500 every 15 minutes because the underlying `appeals`
-- table and `close_appeal_vote()` function were dropped by mig 00053
-- (2026-05-08). Use ONLY for emergency revert of mig 00346, not as a fix
-- path. The forward fix is making `finalize-votes` (added by mig 00327)
-- work — see V1-04 PR #2.
--
-- Command body mirrors mig 00328 verbatim so a rollback returns the
-- prod state to exactly what 00328 left behind.

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'finalize-appeal-votes-15min',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := 'https://fpfvlrwcskhgsjuhrjpz.supabase.co/functions/v1/finalize-appeal-votes',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZwZnZscndjc2toZ3NqdWhyanB6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1MTU4NTIsImV4cCI6MjA5MzA5MTg1Mn0.Cy5fWfdPv1cqhPdy2UTI-cY7eApnG9UPoBv94EkGGBc'
    ),
    body := '{}'::jsonb
  );
  $$
);
