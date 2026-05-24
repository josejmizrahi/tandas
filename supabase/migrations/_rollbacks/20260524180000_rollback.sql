-- Rollback for 20260524180000_ledger_atom_richer_payload.sql.
-- Restores the pre-mig-00366 minimal payload. New ledger entries
-- emitted post-rollback won't carry source_resource_id, paid_by, or
-- in_kind in the system_event payload; iOS feed falls back to the
-- generic "X registró un movimiento de dinero" copy.

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
    'entry_id',       new.id,
    'type',           new.type,
    'amount_cents',   new.amount_cents,
    'currency',       new.currency,
    'from_member_id', new.from_member_id,
    'to_member_id',   new.to_member_id,
    'fund_id',        v_fund_id,
    'source_event_id', nullif(new.metadata->>'source_event_id','')::uuid,
    'note',            nullif(new.metadata->>'note',''),
    'recorded_by',     new.recorded_by
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
