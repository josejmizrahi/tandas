-- 00345 — Flow 3 slice 2: emit `ledgerEntryCreated` atom on every
-- ledger_entries INSERT.
--
-- `ledgerEntryCreated` lives in the known_event_types whitelist (mig
-- 00293 line 179) but nothing emits it. Activity feed therefore can't
-- humanize expenses or contributions; only `fundDeposit` fires (00140)
-- for contributions to funds, and that's silent on expenses entirely.
--
-- This trigger fires once per insert with enough payload for the
-- humanizer to render variants like:
--   "Jose registró un gasto de $500 en Bhuiii desde Fondo bros"
--   "Jose aportó $200 a Fondo bros"
--   "Eduardo cobró $300 de Fondo bros"
--
-- Payload (intentionally flat, no joins required by consumers):
--   {
--     entry_id,                      -- the new ledger_entries.id
--     type,                          -- contribution / expense / payout / ...
--     amount_cents, currency,
--     from_member_id, to_member_id,  -- raw group_members.id
--     fund_id,                       -- alias of resource_id when it's a fund
--     source_event_id,               -- from metadata.source_event_id (00344)
--     note,                          -- from metadata.note when present
--     recorded_by                    -- the auth.users.id who wrote it
--   }
--
-- Idempotency
-- ===========
-- One row per insert; AFTER INSERT FOR EACH ROW. ledger_entries is
-- append-only (mig 00103 atom_no_mutation_guard), so an entry can never
-- be re-emitted. Co-exists with the fund_deposit / fund_threshold
-- triggers (00140/00141) because they emit DIFFERENT event_types.

create or replace function public.on_ledger_entry_inserted_emit_atom()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
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

revoke execute on function public.on_ledger_entry_inserted_emit_atom() from public, anon;
grant  execute on function public.on_ledger_entry_inserted_emit_atom() to authenticated, service_role;

drop trigger if exists trg_on_ledger_entry_inserted_emit_atom on public.ledger_entries;
create trigger trg_on_ledger_entry_inserted_emit_atom
  after insert on public.ledger_entries
  for each row
  execute function public.on_ledger_entry_inserted_emit_atom();

comment on function public.on_ledger_entry_inserted_emit_atom() is
  'Mig 00345: emits ledgerEntryCreated atom on every ledger_entries insert. Co-exists with 00140 (fundDeposit) and 00141 (fundThresholdReached) — different event types so no duplication. Payload flattens fund_id alias + source_event_id + note + recorded_by so the activity humanizer renders without joins.';;
