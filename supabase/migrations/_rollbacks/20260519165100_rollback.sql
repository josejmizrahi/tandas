-- Rollback for 20260519165100_refix_finalize_votes_cron_jwt.sql.
-- WARNING: this restores the broken state (cron with corrupted JWT) by
-- unscheduling the fixed job. Use only for emergency revert.

do $$
begin
  begin
    perform cron.unschedule('finalize-votes-every-15min');
  exception when others then
    raise notice 'finalize-votes-every-15min already absent; skipping';
  end;
end$$;
