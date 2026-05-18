-- 00327 rollback — restore the (broken) finalize-appeal-votes-15min cron.
--
-- This re-creates the historical, dashboard-set job exactly as it was
-- before mig 00327. Reapplying gives you back the 15-min 404 to a
-- non-existent endpoint; only useful if you need to bisect a regression
-- introduced by the rename.

do $$
begin
  begin
    perform cron.unschedule('finalize-votes-every-15min');
  exception when others then
    raise notice 'finalize-votes-every-15min already absent; skipping';
  end;
end$$;

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
