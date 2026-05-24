-- 00366 — Richer payload on ledger_entry_created system_event (P2).
--
-- Today the atom emitter for ledger_entries stamps a minimal payload:
-- entry_id, type, amount_cents, currency, from/to_member_id, fund_id,
-- source_event_id (legacy alias), note, recorded_by. That's enough for
-- a generic "X registró un movimiento de dinero" but loses the rich
-- tri-role context (mig 00355 paid_by + mig 00356 source_resource_id +
-- mig 00364 in_kind) that the activity feed should surface.
--
-- After this mig, the iOS feed (HistoryItemPresentation) can render
-- "Daniel registró $500 pagado por María" when paid_by ≠ recorded_by,
-- and "Aporte en especie" / "Aporte de María a Cena Shabbat" copy
-- once a resource-name resolver lands client-side.
--
-- Backwards-compat: payload is additive jsonb — pre-mig consumers
-- (rule engine, other readers) keep working. New keys are nullable so
-- legacy entries that pre-date the metadata fields render as nil.
--
-- Rollback drops the new keys; payload reverts to the prior shape.

create or replace function public.on_ledger_entry_inserted_emit_atom()
returns trigger
language plpgsql security definer set search_path = 'public', 'pg_catalog'
as $$
declare
  v_resource_type text;
  v_fund_id       uuid;
  v_payload       jsonb;
begin
  -- Resolve fund_id alias: if the entry is scoped to a fund resource,
  -- expose that as `fund_id` so the humanizer doesn't have to think
  -- about polymorphism. Otherwise the alias is null.
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
    -- legacy alias kept for one cycle (clients still read it)
    'source_event_id',  nullif(new.metadata->>'source_event_id','')::uuid,
    -- P2 enrichment: structured tri-role + source context
    'source_resource_id', new.source_resource_id,
    'paid_by_member_id',  nullif(new.metadata->>'paid_by_member_id','')::uuid,
    'in_kind',            nullif(new.metadata->>'in_kind','')::boolean,
    'note',               nullif(new.metadata->>'note',''),
    'recorded_by',        new.recorded_by
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
  'v2 (P2, mig 00366): payload now carries source_resource_id (mig 00356), paid_by_member_id (mig 00355) + in_kind (mig 00364) so the activity feed can render rich tri-role copy ("Daniel registró $500 pagado por María"). Legacy keys (source_event_id, fund_id alias) preserved for one cycle.';
