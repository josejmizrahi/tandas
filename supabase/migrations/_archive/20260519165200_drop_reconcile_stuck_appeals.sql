-- 00348 — Drop redundant reconcile-stuck-appeals cron + function.
--
-- Why
-- ===
-- `reconcile_stuck_appeals()` was introduced (mig 00240) as a defense-in-depth
-- SQL-cron safety net for `fine_appeal` votes specifically, while
-- `finalize-appeal-votes-15min` (since unscheduled by mig 00346) was the
-- HTTP cron supposed to close those votes.
--
-- After mig 00327 the canonical HTTP cron is `finalize-votes-every-15min`,
-- which closes ALL open expired votes (every `vote_type`, fine_appeal
-- included) via `public.finalize_vote()`. With mig 00347 the corrupted
-- JWT that had been masking this cron's invocation is fixed.
--
-- That leaves `reconcile_stuck_appeals()`:
--   - Reads from `public.votes` (modern, not legacy `appeals`).
--   - Calls the canonical `public.finalize_vote()`.
--   - But ONLY for `vote_type = 'fine_appeal'`.
--
-- Per the V1 closer doctrine ("`finalize-votes` is the single canonical
-- closer; no legacy crons live"), this becomes redundant double-work the
-- moment `finalize-votes-every-15min` is healthy. Keep one closer.
--
-- Today (2026-05-19) `public.votes` is empty, so we are not interrupting
-- any in-flight work.
--
-- What
-- ====
-- 1. Unschedule `reconcile-stuck-appeals-30min` (idempotent DO block).
-- 2. Drop the SQL function `public.reconcile_stuck_appeals()`.
--
-- Rollback
-- ========
-- _rollbacks/20260519165200_rollback.sql restores both.

do $$
begin
  begin
    perform cron.unschedule('reconcile-stuck-appeals-30min');
  exception when others then
    raise notice 'reconcile-stuck-appeals-30min already absent; skipping';
  end;
end$$;

drop function if exists public.reconcile_stuck_appeals();
