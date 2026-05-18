-- 00327 — Repoint stale finalize-appeal-votes cron to finalize-votes.
--
-- Why
-- ===
-- pg_cron job `finalize-appeal-votes-15min` was scheduled in the Supabase
-- dashboard pre-mig-00030 and was never tracked in version control. It
-- POSTs to `/functions/v1/finalize-appeal-votes`, but that edge function
-- was merged into the generic `finalize-votes` (which resolves every
-- vote_type, appeals included) at some point and no migration updated
-- the cron command. Net: every 15 minutes prod calls a non-existent
-- endpoint and receives 404 silently. The in-DB safety net
-- `reconcile_stuck_appeals()` (cron `reconcile-stuck-appeals-30min`,
-- introduced mig 00240) has been masking the failure — appeal votes are
-- currently being finalized at 30-min latency instead of the intended
-- 15-min cadence.
--
-- What
-- ====
-- 1. Unschedule the broken `finalize-appeal-votes-15min` job.
-- 2. Schedule a correctly named `finalize-votes-every-15min` calling the
--    real `/functions/v1/finalize-votes` endpoint.
-- The name change makes the intent unambiguous: this resolves ALL open
-- votes past `closes_at`, not just appeal votes.
--
-- The 30-min `reconcile-stuck-appeals` cron stays — it remains a
-- defense-in-depth for the case the edge function itself errors.
--
-- Idempotency
-- ===========
-- cron.unschedule is idempotent (returns true on success, raises on
-- unknown name). We guard with a DO block so a re-apply after the job
-- is already gone is a no-op. cron.schedule is upsert-by-name.
--
-- Pattern
-- =======
-- Mirrors mig 00030_dispatch_notifications_cron.sql — same anon-JWT
-- Authorization header pattern (anon key is public per CLAUDE.md
-- TANDAS_SUPABASE_ANON_KEY), function internally uses SERVICE_ROLE_KEY
-- via env. The anon JWT only satisfies the verify_jwt=true gate.
--
-- Rollback
-- ========
-- _rollbacks/00327_rollback.sql

create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
begin
  -- Remove the broken job. Wrapped because cron.unschedule raises if the
  -- job name doesn't exist (e.g. clean install or after rollback ran).
  begin
    perform cron.unschedule('finalize-appeal-votes-15min');
  exception when others then
    raise notice 'finalize-appeal-votes-15min already absent; skipping';
  end;
end$$;

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
