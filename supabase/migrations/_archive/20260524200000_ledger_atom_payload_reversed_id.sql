-- 00369 — Atom emit trigger surfaces reversed_ledger_entry_id.
--
-- Why
-- ===
-- Mig 00368 introduced reverse_ledger_entry. The reverse appends a
-- settlement entry whose `metadata.reversed_ledger_entry_id` points at
-- the original — that pointer is what makes the pair visible to the
-- projection views. But the atom-emit trigger (mig 00366) doesn't
-- surface that key in the system_event payload, so the iOS activity
-- feed can't tell a reverse from a regular settlement (or know that
-- a row has been reversed).
--
-- This mig is additive: payload gains one nullable uuid key. Pre-mig
-- consumers ignore it; the iOS feed reads it to render the "Revertido"
-- badge on originals and hide the contextMenu on both sides of a
-- reversed pair.

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
    -- mig 00369: the pointer to the original ledger_entry when this
    -- row IS a reverse. NULL for primary entries.
    'reversed_ledger_entry_id',
      nullif(new.metadata->>'reversed_ledger_entry_id','')::uuid
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
  'v3 (mig 00369): payload now carries reversed_ledger_entry_id so the iOS feed can detect reverse pairs without scanning ledger_entries. Earlier: v2 (00366) source_resource_id/paid_by/in_kind; v1 (00366) initial.';
