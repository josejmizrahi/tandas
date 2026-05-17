-- Rollback for 00239_reconcile_stuck_fine_states.sql.

select cron.unschedule('reconcile-stuck-appeals-30min');

drop function if exists public.reconcile_stuck_appeals();
drop function if exists public.advise_stuck_fines(int);
