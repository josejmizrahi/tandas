-- 00141 — Tier 6 slice 19c: emit `fundThresholdReached` when a fund's
-- cumulative deposits cross its target_amount_cents.
--
-- Background
-- ==========
-- `fundThresholdReached` was added to the SystemEventType whitelist in
-- 00117 but had no emitter — same forward-declaration pattern as
-- fundDeposit (mig 00140). With target_amount_cents now persisted on
-- the fund row (mig 00139, create_fund), and fundDeposit firing on
-- every contribution (mig 00140), this trigger fires the
-- threshold-cross event exactly once per fund.
--
-- Trigger contract
-- ================
-- Same AFTER INSERT trigger as fundDeposit — we extend the same
-- function so a single ledger_entries insert produces at most TWO
-- system_events (one fundDeposit, one fundThresholdReached on the
-- crossing contribution).
--
-- Conditions for fundThresholdReached emit:
--   1. The fundDeposit branch already fired (i.e. contribution to a
--      fund — gates everything below).
--   2. The fund has a target: resources.metadata.target_amount_cents
--      is not null and > 0.
--   3. The contribution currency matches the fund's currency.
--      Threshold tracking is per-currency; mixed-currency funds get
--      their threshold once for the canonical currency.
--   4. SUM(amount_cents WHERE type='contribution' AND currency=fund.currency)
--      across all this fund's ledger_entries is >= target_amount_cents.
--   5. No prior fundThresholdReached system_event exists for this fund.
--      Once-per-fund semantics; if the fund's target gets raised
--      later via a metadata edit, that's a future re-emit problem to
--      solve when that flow ships.
--
-- Payload:
--   {
--     fund_resource_id,
--     target_amount_cents,
--     accumulated_cents,
--     currency
--   }
--
-- Idempotency
-- ===========
-- The dedup-query gate at step 5 ensures exactly-one emit per fund.
-- Race condition: two concurrent contributions that cross the
-- threshold simultaneously would each see "no prior emit" → double
-- emit. pg_cron and direct iOS paths serialize ledger inserts
-- through the same trigger function context, so practical risk is
-- effectively zero for V1 group sizes. If concurrent writers ever
-- become a real concern, a UNIQUE index on
-- (resource_id, event_type) where event_type='fundThresholdReached'
-- would harden it.

create or replace function public.on_ledger_entry_inserted_fund_deposit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource_type   text;
  v_fund_metadata   jsonb;
  v_target_cents    bigint;
  v_fund_currency   text;
  v_accumulated     bigint;
  v_already_emitted boolean;
begin
  -- Bail fast on the common case (most ledger entries aren't contributions).
  if new.type <> 'contribution' or new.resource_id is null then
    return new;
  end if;

  -- Only fire for fund resources. Load resource_type + metadata in one shot.
  select r.resource_type, r.metadata
    into v_resource_type, v_fund_metadata
    from public.resources r
   where r.id = new.resource_id;

  if v_resource_type <> 'fund' then
    return new;
  end if;

  -- 1. fundDeposit: every contribution to a fund emits one.
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

  -- 2. fundThresholdReached: optional second emit when cumulative
  -- deposits cross the fund's target. Skip everything if there's no
  -- target, currency mismatch, or a prior threshold event already
  -- landed for this fund.
  v_target_cents  := nullif(v_fund_metadata->>'target_amount_cents', '')::bigint;
  v_fund_currency := coalesce(v_fund_metadata->>'currency', 'MXN');

  if v_target_cents is null or v_target_cents <= 0 then
    return new;
  end if;
  if new.currency <> v_fund_currency then
    return new;
  end if;

  -- Cumulative deposits in the fund's currency. The new row is already
  -- INSERTed by the time this AFTER trigger fires, so it counts.
  select coalesce(sum(amount_cents), 0)::bigint
    into v_accumulated
    from public.ledger_entries
   where resource_id = new.resource_id
     and type        = 'contribution'
     and currency    = v_fund_currency;

  if v_accumulated < v_target_cents then
    return new;
  end if;

  -- Dedup: once per fund. Check system_events for a prior threshold emit.
  select exists (
    select 1 from public.system_events
     where event_type = 'fundThresholdReached'
       and resource_id = new.resource_id
  ) into v_already_emitted;

  if v_already_emitted then
    return new;
  end if;

  perform public.record_system_event(
    new.group_id,
    'fundThresholdReached',
    new.resource_id,
    null,
    jsonb_build_object(
      'fund_resource_id',    new.resource_id,
      'target_amount_cents', v_target_cents,
      'accumulated_cents',   v_accumulated,
      'currency',            v_fund_currency
    )
  );

  return new;
end;
$$;

revoke execute on function public.on_ledger_entry_inserted_fund_deposit() from public, anon;
grant  execute on function public.on_ledger_entry_inserted_fund_deposit() to authenticated, service_role;

-- Trigger registration unchanged from 00140 — same trigger name, same
-- attachment point, the function body now handles both emits.

comment on function public.on_ledger_entry_inserted_fund_deposit() is
  'Tier 6 slice 19b+c (mig 00140 + 00141): emits fundDeposit on every contribution to a fund + optionally fundThresholdReached when cumulative deposits in the fund''s currency cross target_amount_cents. Once-per-fund threshold semantics via system_events dedup gate.';
