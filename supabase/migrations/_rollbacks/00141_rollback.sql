-- Rollback 00141 — restore the 00140 trigger function body (fundDeposit
-- emit only, no threshold check). Existing fundThresholdReached
-- system_events stay (append-only audit).

create or replace function public.on_ledger_entry_inserted_fund_deposit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource_type text;
begin
  if new.type <> 'contribution' or new.resource_id is null then
    return new;
  end if;

  select r.resource_type into v_resource_type
    from public.resources r
   where r.id = new.resource_id;

  if v_resource_type <> 'fund' then
    return new;
  end if;

  perform public.record_system_event(
    new.group_id,
    'fundDeposit',
    new.resource_id,
    null,
    jsonb_build_object(
      'amount_cents',     new.amount_cents,
      'currency',         new.currency,
      'from_member_id',   new.from_member_id,
      'fund_resource_id', new.resource_id
    )
  );

  return new;
end;
$$;

comment on function public.on_ledger_entry_inserted_fund_deposit() is
  'Tier 6 slice 19b (mig 00140): emits fundDeposit system_event when a contribution ledger_entry lands against a fund resource.';
