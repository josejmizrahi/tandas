-- 00328 rollback — undo the restore (puts you back in the broken 00327 state).

do $$
begin
  begin
    perform cron.unschedule('finalize-appeal-votes-15min');
  exception when others then
    raise notice 'finalize-appeal-votes-15min already absent; skipping';
  end;
end$$;
