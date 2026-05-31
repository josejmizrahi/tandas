-- Mig 00172: Data-rights janitor for stuck pending/executing requests
--
-- Why
-- ===
-- The data-rights flow (mig 00168) is synchronous: the iOS client calls
-- `request_data_export` (which inserts a pending row + returns an id) and
-- then immediately invokes the `export-user-data` edge function with that
-- id. The function flips the row through `executing` → `completed` /
-- `failed` in a single round-trip.
--
-- If the client crashes / loses connectivity between the RPC and the
-- function invocation, the row stays `pending` forever. The user sees
-- a never-finishing entry in DataRightsSheet history, and they can't
-- distinguish that from a row currently in flight.
--
-- What
-- ====
-- A janitor that flips rows stuck in `pending` or `executing` for more
-- than 1 hour to `failed` with a synthetic error message. 1 hour is
-- generous: the export function returns in <2s even for active users.
--
-- We mark only the status; we do NOT touch `data_deletion_log` (that
-- table is for executed deletions, not for fail-paths).
--
-- Scheduled every 5 minutes — same cadence as the outbox janitor.

create or replace function public.fail_stale_data_rights_requests()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  failed_count int;
begin
  with stuck as (
    update public.data_subject_rights_requests
       set status = 'failed',
           executed_at = now(),
           error_message = coalesce(error_message, 'janitor: stuck >1h without completion')
     where status in ('pending', 'executing')
       and requested_at < now() - interval '1 hour'
     returning id
  )
  select count(*) into failed_count from stuck;

  if failed_count > 0 then
    raise notice 'fail_stale_data_rights_requests: marked % row(s) failed', failed_count;
  end if;

  return failed_count;
end;
$$;

comment on function public.fail_stale_data_rights_requests is
  'Marks data_subject_rights_requests rows that have been pending/executing for >1h as failed. Recovers from client-side disconnects between request_data_export RPC and edge function invoke. Mig 00172.';

revoke execute on function public.fail_stale_data_rights_requests() from public, anon, authenticated;
grant  execute on function public.fail_stale_data_rights_requests() to service_role;

select cron.schedule(
  'fail-stale-data-rights-every-5-minutes',
  '*/5 * * * *',
  $$ select public.fail_stale_data_rights_requests(); $$
);
