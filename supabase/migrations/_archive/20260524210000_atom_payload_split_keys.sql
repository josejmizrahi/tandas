-- 00371 — Atom emit trigger surfaces split_mode + split_breakdown.
--
-- Adds two more keys to the ledgerEntryCreated payload so the iOS
-- activity detail view can render the per-member breakdown card
-- without fetching the raw ledger_entries row separately.

create or replace function public.on_ledger_entry_inserted_emit_atom()
returns trigger
language plpgsql security definer set search_path = 'public', 'pg_catalog'
as $$
declare
  v_resource_type text;
  v_fund_id       uuid;
  v_payload       jsonb;
begin
  if new.resource_id is not null then
    select r.resource_type
      into v_resource_type
      from public.resources r
     where r.id = new.resource_id;

    if v_resource_type = 'fund' then
      v_fund_id := new.resource_id;
    end if;
  end if;

  v_payload := jsonb_build_object(
    'entry_id',         new.id,
    'type',             new.type,
    'amount_cents',     new.amount_cents,
    'currency',         new.currency,
    'from_member_id',   new.from_member_id,
    'to_member_id',     new.to_member_id,
    'fund_id',          v_fund_id,
    'source_event_id',  nullif(new.metadata->>'source_event_id','')::uuid,
    'source_resource_id', new.source_resource_id,
    'paid_by_member_id',  nullif(new.metadata->>'paid_by_member_id','')::uuid,
    'in_kind',            nullif(new.metadata->>'in_kind','')::boolean,
    'note',               nullif(new.metadata->>'note',''),
    'recorded_by',        new.recorded_by,
    'reversed_ledger_entry_id',
      nullif(new.metadata->>'reversed_ledger_entry_id','')::uuid,
    -- mig 00371: Splitwise-style mode + canonical per-member breakdown.
    'split_mode',         new.metadata->>'split_mode',
    'split_breakdown',    new.metadata->'split_breakdown'
  );

  perform public.record_system_event(
    new.group_id,
    'ledgerEntryCreated',
    new.resource_id,
    null,
    v_payload
  );

  return new;
end;
$$;

comment on function public.on_ledger_entry_inserted_emit_atom() is
  'v4 (mig 00371): payload now carries split_mode + split_breakdown so the iOS detail view renders the per-member breakdown card without a separate fetch.';
