-- Rollback for 20260519194012_drop_legacy_fund_writers_overloads.sql.
-- Recreates the 5-arg legacy overloads of fund_contribute + fund_record_expense.
-- WARNING: leaves the system in two-overload limbo where PostgREST may
-- route to the wrong version depending on the JSON body shape. Use only
-- in coordination with rolling back mig 00351.

create or replace function public.fund_contribute(
  p_fund_id         uuid,
  p_amount_cents    bigint,
  p_currency        text default null,
  p_note            text default null,
  p_source_event_id uuid default null
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_entry public.ledger_entries;
begin
  -- Delegate to the 6-arg version with p_client_id => null.
  v_entry := public.fund_contribute(
    p_fund_id, p_amount_cents, p_currency, p_note, p_source_event_id, null
  );
  return v_entry;
end;
$$;

create or replace function public.fund_record_expense(
  p_fund_id         uuid,
  p_amount_cents    bigint,
  p_to_member_id    uuid,
  p_currency        text default null,
  p_note            text default null,
  p_source_event_id uuid default null
)
returns public.ledger_entries
language plpgsql
security definer
set search_path = 'public', 'pg_catalog'
as $$
declare
  v_entry public.ledger_entries;
begin
  v_entry := public.fund_record_expense(
    p_fund_id, p_amount_cents, p_to_member_id, p_currency, p_note, p_source_event_id, null
  );
  return v_entry;
end;
$$;
