-- 00160 — Outbox janitor: recover orphaned in-flight notification rows.
--
-- Why
-- ===
-- The dispatcher (`dispatch-notifications` edge fn) atomically claims
-- pending rows by setting `dispatched_at = now()` via
-- `claim_pending_outbox` (mig 00031). After APNs delivery it calls
-- `mark_outbox_sent` / `mark_outbox_failed` / `mark_outbox_skipped` to
-- finalize `dispatch_status`.
--
-- If the function dies, times out, or hits an uncaught error between
-- claim and finalize, the row is orphaned: `dispatched_at IS NOT NULL`
-- AND `dispatch_status = 'pending'`. It will never be re-claimed
-- because `claim_pending_outbox`'s WHERE filter requires
-- `dispatched_at IS NULL`. The result: ~1 push/day silently lost.
-- Documented at `dispatch-notifications/index.ts:13-18` as known debt.
--
-- What
-- ====
-- A SECURITY DEFINER function that resets `dispatched_at = NULL` for
-- rows stuck in the orphaned state for more than 5 minutes (well past
-- the dispatcher's per-row turnaround of <1s). The next minute's
-- `dispatch-notifications-every-minute` cron will then re-claim them
-- via the existing `claim_pending_outbox` path.
--
-- It does NOT touch `dispatch_status`: that's already `'pending'` for
-- the in-flight set, and overwriting `'sent'` / `'failed'` rows would
-- erase delivery state.
--
-- Scheduled every 5 minutes. cron.schedule is upsert-by-name so
-- re-applying this migration is idempotent.
--
-- Per Plans/Active/Beta1Consolidation.md §6 W1 item E-1.2 +
-- §5 Risk Matrix "Outbox crash → push perdido sin recuperación" (Alta).

create or replace function public.reset_stale_outbox_claims()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  reset_count int;
begin
  with reset as (
    update public.notifications_outbox
    set    dispatched_at = null
    where  dispatch_status = 'pending'
      and  dispatched_at is not null
      and  dispatched_at < now() - interval '5 minutes'
    returning id
  )
  select count(*) into reset_count from reset;

  if reset_count > 0 then
    raise notice 'reset_stale_outbox_claims: re-queued % orphan row(s)', reset_count;
  end if;

  return reset_count;
end;
$$;

comment on function public.reset_stale_outbox_claims is
  'Recovers orphaned in-flight outbox rows. A row claimed by claim_pending_outbox but never finalized (dispatched_at set, dispatch_status still pending) gets dispatched_at reset to NULL after 5 min, so the next dispatch cron re-claims it. Beta 1 W1 E-1.2.';

-- Lock down execution. Per Supabase linter rule 0029
-- (authenticated_security_definer_function_executable) we must revoke
-- from `authenticated` too, not just `public` / `anon` — otherwise any
-- signed-in user could call this via /rest/v1/rpc and rewind the
-- dispatch state for every group.
revoke execute on function public.reset_stale_outbox_claims() from public, anon, authenticated;
grant  execute on function public.reset_stale_outbox_claims() to service_role;

-- Schedule every 5 minutes — well above the dispatcher's per-row latency
-- but small enough that worst-case loss before janitor recovery is one
-- pass. cron.schedule is upsert-by-name (mig 00030 pattern).
select cron.schedule(
  'reset-stale-outbox-every-5-minutes',
  '*/5 * * * *',
  $$ select public.reset_stale_outbox_claims(); $$
);
