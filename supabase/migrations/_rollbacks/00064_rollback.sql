-- 00064 rollback — Restore the 6 orphan V1 tables dropped by 00064.
--
-- Restores empty shells matching the original V1 shape (mig 00001).
-- Data is not recoverable; all 6 tables were empty at drop time per
-- the verification documented in 00064.
--
-- If you need the actual columns/constraints/RLS from V1, copy from
-- the corresponding `create table` statements in
-- `00001_core_schema.sql` rather than relying on this skeleton — V1
-- shapes are not what Phase 3+ should use anyway (per
-- Plans/Active/AtomProjection.md, Phase 3 designs fresh
-- LedgerEntry / Contribution / Payout atoms).

create table if not exists public.vote_ballots (
  id uuid primary key default gen_random_uuid(),
  vote_id uuid not null,
  user_id uuid not null,
  choice text not null,
  cast_at timestamptz not null default now()
);

create table if not exists public.pots (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  event_id uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.pot_entries (
  id uuid primary key default gen_random_uuid(),
  pot_id uuid not null,
  user_id uuid not null,
  amount numeric not null,
  created_at timestamptz not null default now()
);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  paid_by uuid not null,
  amount numeric not null,
  description text,
  created_at timestamptz not null default now()
);

create table if not exists public.expense_shares (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null,
  user_id uuid not null,
  share numeric not null
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  from_user uuid not null,
  to_user uuid not null,
  amount numeric not null,
  created_at timestamptz not null default now()
);
