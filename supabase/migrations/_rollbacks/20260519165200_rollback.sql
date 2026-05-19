-- Rollback for 20260519165200_drop_reconcile_stuck_appeals.sql.
-- Recreates the SQL function and re-schedules the 30-min cron. Same body
-- as the original mig 00240 install — defense-in-depth for fine_appeal
-- vote closing, redundant with finalize-votes-every-15min.

create extension if not exists pg_cron;

create or replace function public.reconcile_stuck_appeals()
returns integer
language plpgsql
security definer
set search_path = 'public'
as $function$
declare
  v_count int := 0;
  v_id    uuid;
begin
  for v_id in
    select v.id from public.votes v
     where v.vote_type = 'fine_appeal'
       and v.status    = 'open'
       and v.closes_at < now()
     order by v.closes_at asc
  loop
    perform public.finalize_vote(v_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$function$;

comment on function public.reconcile_stuck_appeals() is
  'Finalizes appeal votes that are still open past closes_at — protects against silent fails in the finalize-appeal-votes edge function. Idempotent (finalize_vote handles already-resolved). Returns count finalized.';

select cron.schedule(
  'reconcile-stuck-appeals-30min',
  '*/30 * * * *',
  $$ select public.reconcile_stuck_appeals(); $$
);
