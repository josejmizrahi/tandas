-- 00346 — Unschedule finalize-appeal-votes-15min cron (it points at a dead function).
--
-- Background
-- ==========
-- Mig 00328 restored `finalize-appeal-votes-15min` (every 15 min) after
-- mig 00327 unscheduled it. 00328's premise was wrong:
--
--   - The edge function `finalize-appeal-votes` SELECTs from
--     `public.appeals` and calls `close_appeal_vote()`.
--   - Both `appeals` (table) and `close_appeal_vote()` (function) were
--     dropped by mig 00053 on 2026-05-08, as part of the appeals→votes
--     migration. iOS `LiveAppealRepository` moved to votes/vote_casts
--     before that, so the dead function had no callers.
--
-- Net effect: since 2026-05-08 the cron has POSTed to a function that
-- returns HTTP 500 every 15 minutes. Confirmed in prod edge-function
-- logs 2026-05-19 (status_code=500, error "relation public.appeals does
-- not exist"). No data corruption — just noise + wasted cron ticks +
-- misleading "ACTIVE" status in the dashboard.
--
-- This migration
-- ==============
-- Unschedules `finalize-appeal-votes-15min`. The edge function itself is
-- left ACTIVE in the Supabase dashboard for now — it gets deleted only
-- after this migration is applied and prod logs confirm the 500s have
-- stopped. Sequenced cleanup so we can revert cheaply if surprises show
-- up.
--
-- Generic vote closing (including fine_appeal votes) is supposed to live
-- in `finalize-votes-every-5min` (added by mig 00327). That function
-- reads `votes` and calls `finalize_vote()` — which exists and emits
-- `appealResolved` for fine_appeal votes via mig 00123.
--
-- Known follow-up: `finalize-votes` is currently returning HTTP 401 in
-- prod (separate bug, tracked as V1-04 PR #2). The doctrine fix is to
-- make `finalize-votes` work, NOT to resurrect `finalize-appeal-votes`.
-- One closer, generic.
--
-- Rollback
-- ========
-- _rollbacks/20260519145824_rollback.sql re-schedules the cron with the
-- same command as mig 00328. WARNING: that puts the broken state back.
-- Use only for emergency revert of this migration, not as a fix path.

do $$
begin
  begin
    perform cron.unschedule('finalize-appeal-votes-15min');
  exception when others then
    raise notice 'finalize-appeal-votes-15min already absent; skipping';
  end;
end$$;
