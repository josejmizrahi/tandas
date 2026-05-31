-- 00347 — Re-schedule finalize-votes-every-15min with the correct anon JWT.
--
-- Why
-- ===
-- Mig 00327 originally scheduled `finalize-votes-every-15min` with a valid
-- anon JWT. At some point after, the cron command in `cron.job` was
-- hand-edited via the Supabase Dashboard SQL editor (or `cron.alter_job()`)
-- and the JWT payload got corrupted: the project `ref` and the `role`
-- fields were stripped, leaving `{"iss":"supabase","ref":"anon","iat":...,
-- "exp":...}` — 47 bytes shorter than the valid one. Supabase rejects it
-- with HTTP 401 `UNAUTHORIZED_LEGACY_JWT`, so the cron has been a no-op
-- since the corruption.
--
-- Today (2026-05-19) `public.votes` is empty, so no data was lost — only
-- the closing path was silently dead for any future votes (rule_change,
-- fine_appeal, etc.). The 30-min DB safety net
-- `reconcile_stuck_appeals()` masked fine_appeal closing only; other
-- vote_types had no closer at all.
--
-- Verification
-- ============
--   Pre-fix:  POST /functions/v1/finalize-votes with corrupted JWT → 401
--   Post-fix: POST /functions/v1/finalize-votes with valid anon JWT  → 200 {"processed":0}
--
-- This migration re-runs the schedule clause from mig 00327 verbatim.
-- `cron.schedule` is upsert-by-name, so it overwrites the corrupted
-- command in place.
--
-- Rollback
-- ========
-- _rollbacks/20260519165100_rollback.sql unschedules the job. Use only to
-- revert this migration — the prior state was broken (401).

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'finalize-votes-every-15min',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := 'https://fpfvlrwcskhgsjuhrjpz.supabase.co/functions/v1/finalize-votes',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZwZnZscndjc2toZ3NqdWhyanB6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1MTU4NTIsImV4cCI6MjA5MzA5MTg1Mn0.Cy5fWfdPv1cqhPdy2UTI-cY7eApnG9UPoBv94EkGGBc'
    ),
    body := '{}'::jsonb
  );
  $$
);
