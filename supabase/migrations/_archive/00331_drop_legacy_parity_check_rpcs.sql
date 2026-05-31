-- 00331 — Drop 3 stale legacy RPCs flagged by the cleanup audit.
--
-- Plans/Active/CleanupAudit_2026-05-18/07_sql_rpcs.md §3 + §11 flagged
-- "~12 legacy RPC names never DROP'd" as low-severity surface noise.
-- Audit-stale: most of the 12 were already dropped in prior cleanups.
-- The 3 still present in pg_proc as of 2026-05-18:
--
--   - advise_stuck_fines(p_hours_to_stuck integer)
--     Mig 00240 reconcile-stuck-fine-states helper. The cron job
--     `reconcile-stuck-appeals-30min` calls `reconcile_stuck_appeals()`
--     instead, not this. Zero Swift callers, zero edge-fn callers,
--     zero pg_depend entries.
--   - events_resources_parity_check()
--     Migs 00039/00040/00152 one-shot parity check post events→resources
--     migration. Has not been called since the migration landed; was
--     supposed to be dropped in the §14 step 5c-iii.C cleanup but
--     survived.
--   - fines_resource_id_parity_check()
--     Mig 00041 one-shot parity check post fines.event_id →
--     fines.resource_id consolidation. Same shape as above —
--     post-migration self-check, never re-invoked.
--
-- Verified zero dependents via pg_depend (0 dependent_count for each)
-- + zero Swift callers + zero supabase/functions/ callers.
--
-- Rollback
-- ========
-- _rollbacks/00331_rollback.sql restores all three from their original
-- definitions; they're parity checks so re-introducing them has no
-- runtime effect (caller has to invoke them deliberately).

drop function if exists public.advise_stuck_fines(integer);
drop function if exists public.events_resources_parity_check();
drop function if exists public.fines_resource_id_parity_check();
