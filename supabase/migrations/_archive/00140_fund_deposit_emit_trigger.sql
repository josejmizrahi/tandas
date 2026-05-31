-- 00140 — Tier 6 slice 19b: emit `fundDeposit` system_event when a
-- contribution ledger_entry lands against a fund resource.
--
-- Background
-- ==========
-- Mig 00117 added `fundDeposit` to the SystemEventType whitelist, but
-- no edge function or trigger ever fired it. The type sat in the
-- catalog as a forward declaration. With Tier 6.19 shipping
-- `create_fund` (mig 00139), funds are now creatable; this migration
-- closes the loop by emitting `fundDeposit` whenever someone records a
-- contribution against one.
--
-- Trigger contract
-- ================
-- AFTER INSERT on `public.ledger_entries`, fire when ALL of:
--   - new.type        = 'contribution'
--   - new.resource_id IS NOT NULL
--   - the referenced `resources` row has resource_type = 'fund'
--
-- Other ledger types (expense, payout, settlement, fine_*) are
-- semantically different and don't represent "money flowed INTO the
-- fund", so they don't fire. A contribution scoped to a non-fund
-- resource (e.g. someone "contributes" to a specific event's pot —
-- valid but rare) also doesn't fire — the SystemEventType reads
-- specifically as "deposit into a fund", not generic ledger inflow.
--
-- Payload mirrors what the rule engine + iOS activity feed need to
-- render the event without joining back to ledger_entries / resources:
--   {
--     amount_cents,
--     currency,
--     from_member_id,   // who put the money in
--     fund_resource_id  // same as new.resource_id, named for clarity
--   }
--
-- Idempotency
-- ===========
-- `system_events` is append-only and `record_system_event` writes one
-- row per call. Each ledger_entry row inserts once → trigger fires
-- once → exactly one system_event. No dedup logic needed at the
-- emitter level; the rule engine's rule_firings table provides
-- downstream idempotency for actual rule execution.
--
-- Service-role inserts (from record_ledger_entry, fines flows, future
-- payout flows) all pass through this trigger. The trigger is SECURITY
-- DEFINER and bypasses RLS to read `resources.resource_type`; doesn't
-- need auth context because the emit-side `record_system_event`
-- accepts the trigger's discovered group_id.

create or replace function public.on_ledger_entry_inserted_fund_deposit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource_type text;
begin
  -- Bail fast on the common case (most ledger entries aren't contributions).
  if new.type <> 'contribution' or new.resource_id is null then
    return new;
  end if;

  -- Only fire for fund resources. A "contribution" attached to an
  -- event resource is meaningful in some templates ("each member
  -- chipped in for the dinner") but isn't a fundDeposit in the
  -- platform's vocabulary.
  select r.resource_type into v_resource_type
    from public.resources r
   where r.id = new.resource_id;

  if v_resource_type <> 'fund' then
    return new;
  end if;

  perform public.record_system_event(
    new.group_id,
    'fundDeposit',
    new.resource_id,   -- fund's resource_id is the natural anchor
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

revoke execute on function public.on_ledger_entry_inserted_fund_deposit() from public, anon;
grant  execute on function public.on_ledger_entry_inserted_fund_deposit() to authenticated, service_role;

drop trigger if exists trg_on_ledger_entry_inserted_fund_deposit on public.ledger_entries;
create trigger trg_on_ledger_entry_inserted_fund_deposit
  after insert on public.ledger_entries
  for each row
  execute function public.on_ledger_entry_inserted_fund_deposit();

comment on function public.on_ledger_entry_inserted_fund_deposit() is
  'Tier 6 slice 19b (mig 00140): emits fundDeposit system_event when a contribution ledger_entry lands against a fund resource. Skips when type != contribution, when resource_id is null, or when the resource isn''t a fund. Payload: amount_cents / currency / from_member_id / fund_resource_id.';
