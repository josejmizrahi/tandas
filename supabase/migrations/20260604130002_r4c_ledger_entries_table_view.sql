-- =============================================================================
-- R.4C · ledger_entries + actor_money_balances view
-- =============================================================================
-- Doubled-entry shadow ledger that tracks every money movement.
-- Trigger on money_splits emits ledger rows; RLS allows context members to
-- read; writes only via the trigger (bypasses RLS as table owner).
-- =============================================================================

create table if not exists public.ledger_entries (
  id                uuid primary key default gen_random_uuid(),
  context_actor_id  uuid not null references public.actors(id) on delete cascade,
  transaction_id    uuid references public.money_transactions(id) on delete cascade,
  actor_id          uuid not null references public.actors(id) on delete cascade,
  entry_type        text not null check (entry_type in ('debit','credit')),
  amount            numeric not null check (amount > 0),
  currency          text not null,
  occurred_at       timestamptz not null default now(),
  metadata          jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now()
);

comment on table public.ledger_entries is
  'R.4C: doubled-entry shadow ledger. credit = actor is owed / put in; debit = actor owes / took out. Sum across actors per (context, currency) is zero.';

create index if not exists idx_ledger_context_actor_currency
  on public.ledger_entries(context_actor_id, actor_id, currency);
create index if not exists idx_ledger_transaction
  on public.ledger_entries(transaction_id);
create index if not exists idx_ledger_actor_time
  on public.ledger_entries(actor_id, occurred_at desc);

-- RLS: members of the context can read. Writes only via the trigger (which
-- runs as table owner and bypasses RLS) — no public policy granted.
alter table public.ledger_entries enable row level security;

drop policy if exists "ledger_entries_read" on public.ledger_entries;
create policy "ledger_entries_read"
  on public.ledger_entries
  for select
  to authenticated, service_role
  using (public.is_context_member(context_actor_id) or context_actor_id = public.current_actor_id());

revoke all on public.ledger_entries from anon;
grant select on public.ledger_entries to authenticated, service_role;

-- View ----------------------------------------------------------------------
create or replace view public.actor_money_balances as
select
  context_actor_id,
  actor_id,
  currency,
  coalesce(sum(amount) filter (where entry_type = 'credit'), 0) as total_credit,
  coalesce(sum(amount) filter (where entry_type = 'debit'),  0) as total_debit,
  coalesce(sum(amount) filter (where entry_type = 'credit'), 0)
    - coalesce(sum(amount) filter (where entry_type = 'debit'), 0) as net_balance,
  max(occurred_at) as last_movement_at
from public.ledger_entries
group by context_actor_id, actor_id, currency;

comment on view public.actor_money_balances is
  'R.4C: net balance per (context, actor, currency). Positive = creditor (is owed). Negative = debtor (owes).';

revoke all on public.actor_money_balances from anon;
grant select on public.actor_money_balances to authenticated, service_role;

-- =============================================================================
-- Trigger: emit ledger entries when a money_split is inserted.
-- =============================================================================
create or replace function public._emit_ledger_from_split()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_txn public.money_transactions%rowtype;
  v_entry_type text;
begin
  select * into v_txn from public.money_transactions where id = new.transaction_id;
  if v_txn.id is null then
    return new;  -- transaction may not exist yet (defensive); skip
  end if;
  if v_txn.context_actor_id is null then
    return new;  -- can't post to ledger without a context (defensive)
  end if;

  -- Mapping (transaction_type, split_role) → entry_type
  v_entry_type := case
    when v_txn.transaction_type = 'expense' and new.split_role = 'payer'       then 'credit'
    when v_txn.transaction_type = 'expense' and new.split_role = 'beneficiary' then 'debit'
    when v_txn.transaction_type = 'payment' and new.split_role = 'debtor'      then 'credit'
    when v_txn.transaction_type = 'payment' and new.split_role = 'creditor'    then 'debit'
    -- Future transaction types (settlement, payout, fine, etc.) can be added
    -- here. Unknown combinations are silently ignored to avoid breaking
    -- writers; future R.4C.x slices wire them.
    else null
  end;

  if v_entry_type is null then
    return new;
  end if;

  insert into public.ledger_entries(
    context_actor_id, transaction_id, actor_id, entry_type, amount, currency,
    occurred_at, metadata
  )
  values (
    v_txn.context_actor_id, v_txn.id, new.actor_id, v_entry_type, new.amount,
    new.currency, v_txn.occurred_at,
    jsonb_build_object(
      'transaction_type', v_txn.transaction_type,
      'split_role', new.split_role,
      'source_split_id', new.id
    )
  );

  return new;
end;
$$;

drop trigger if exists money_splits_emit_ledger on public.money_splits;
create trigger money_splits_emit_ledger
  after insert on public.money_splits
  for each row execute function public._emit_ledger_from_split();

-- =============================================================================
-- Backfill: emit ledger rows for every existing money_splits row.
-- Idempotent guard: skip splits that already have a corresponding ledger entry
-- (matched by transaction_id + actor_id + amount + currency + entry_type).
-- =============================================================================
insert into public.ledger_entries (
  context_actor_id, transaction_id, actor_id, entry_type, amount, currency,
  occurred_at, metadata
)
select
  t.context_actor_id, t.id, s.actor_id,
  case
    when t.transaction_type = 'expense' and s.split_role = 'payer'       then 'credit'
    when t.transaction_type = 'expense' and s.split_role = 'beneficiary' then 'debit'
    when t.transaction_type = 'payment' and s.split_role = 'debtor'      then 'credit'
    when t.transaction_type = 'payment' and s.split_role = 'creditor'    then 'debit'
  end as entry_type,
  s.amount, s.currency, t.occurred_at,
  jsonb_build_object(
    'transaction_type', t.transaction_type,
    'split_role', s.split_role,
    'source_split_id', s.id,
    'backfill', true
  )
from public.money_splits s
join public.money_transactions t on t.id = s.transaction_id
where t.context_actor_id is not null
  and case
        when t.transaction_type = 'expense' and s.split_role = 'payer'       then true
        when t.transaction_type = 'expense' and s.split_role = 'beneficiary' then true
        when t.transaction_type = 'payment' and s.split_role = 'debtor'      then true
        when t.transaction_type = 'payment' and s.split_role = 'creditor'    then true
        else false
      end
  and not exists (
    select 1 from public.ledger_entries le
    where le.transaction_id = t.id
      and le.actor_id = s.actor_id
      and le.amount = s.amount
      and le.currency = s.currency
  );
