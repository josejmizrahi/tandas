-- 00328 — Restore finalize-appeal-votes-15min cron (revert of 00327 unschedule).
--
-- Why
-- ===
-- Mig 00327 mistakenly classified `finalize-appeal-votes` as a 404 endpoint
-- and unscheduled the cron pointing at it. That was wrong: the function
-- IS deployed to Supabase (slug `finalize-appeal-votes`, version 6, status
-- ACTIVE) — it's just absent from `supabase/functions/` source, which
-- gave the audit a false negative. The two endpoints are NOT equivalent:
--
--   finalize-appeal-votes  → reads `appeals` table, calls close_appeal_vote()
--                            which handles quorum/threshold + fine voiding +
--                            emits `appealResolved`. Appeals-specific.
--   finalize-votes         → reads `votes` table, calls finalize_vote()
--                            (passed/failed/quorum_failed). Generic.
--
-- Mig 00327 net effect was:
--   + ADDED `finalize-votes-every-15min` (good — votes had no cron)
--   - REMOVED `finalize-appeal-votes-15min` (bad — appeals lost their
--     15-min closer; only the 30-min DB reconciler covered them).
--
-- This migration restores `finalize-appeal-votes-15min` exactly as it was
-- pre-00327. The `finalize-votes-every-15min` cron added by 00327 stays
-- because it covers a real gap.
--
-- Follow-up debt
-- ==============
--   1. Restore source for the 3 deployed-but-not-in-repo edge functions:
--      `finalize-appeal-votes`, `evaluate-event-rules`, `export-user-data`.
--      Their source lives only in the Supabase dashboard today; the
--      cleanup audit (Plans/Active/CleanupAudit_2026-05-18) did not see
--      them because it grepped the repo.
--   2. Update CleanupAudit_2026-05-18/06_edge_functions.md to remove the
--      "404" claim and reflect that finalize-appeal-votes is a real
--      function, just unversioned.
--
-- Rollback
-- ========
-- _rollbacks/00328_rollback.sql

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
