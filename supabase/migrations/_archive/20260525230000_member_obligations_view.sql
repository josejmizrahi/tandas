-- 20260525230000 — member_obligations_view (FASE 4 Wave 4, Phase 5
-- foundation).
--
-- Why
-- ===
-- `member_balances_per_group` (mig 00136) computes a single `net_cents
-- = received - sent` across ALL ledger types. That conflates 3 distinct
-- concepts and produces misleading numbers:
--
--   * STAKE (capital injected via contributions) — NOT a debt, but
--     the math reads it as a negative net (i.e. "le debes al grupo").
--   * RECEIVABLE (pool owes me for expenses I fronted) — correctly
--     positive net.
--   * OBLIGATION (I owe the group via fines) — naïve sent/received
--     math double-counts paid fines (fine_issued + fine_paid both
--     write from=member, to=NULL).
--
-- The greedy settlement plan reads `net_cents` and ends up suggesting
-- peer payments that COMPOUND the debt instead of liquidating it — a
-- real bug surfaced 2026-05-25 by the founder.
--
-- What this view does
-- ===================
-- Per (group, member, currency), break apart the polymorphism into
-- clean columns:
--
--   stake_cents             — cash contributions from this member
--                             (factual capital, NOT debt)
--   stake_in_kind_cents     — non-cash assets contributed
--                             (terrenos, equipo, etc; mig 00364)
--   receivable_cents        — pool owes member for expenses fronted
--                             minus payouts/reimbursements already
--                             received (or self-issued via mig
--                             20260525221500 convention)
--   obligation_cents        — member owes group via fines outstanding
--                             (issued − paid − voided)
--   settlement_received_cents — incoming peer settlements
--   settlement_sent_cents   — outgoing peer settlements
--   net_peer_position_cents — receivable + settlement_received
--                             − obligation − settlement_sent
--                             (positive = peers/pool owe me,
--                              negative = I owe peers/pool;
--                              EXCLUDES contributions — that's stake)
--
-- This is the projection the greedy peer-settlement plan should read
-- (NOT `net_cents` from `member_balances_per_group`) and the
-- projection iOS "Tu posición" should read for accurate 3-dim breakdown.
--
-- Reimbursement direction policy
-- ==============================
-- iOS (FASE 4 Wave 4) writes `reimbursement` with
-- `from_member_id = member, to_member_id = NULL` — math-correct
-- direction to cancel the receivable via `member_balances_per_group`
-- (sent_cents += amount). We accept BOTH directions in
-- `receivable_cents` math for backward-compat with any legacy
-- entries that wrote `to=member`.
--
-- RLS
-- ===
-- `security invoker` (the default for views) — enforces underlying
-- `ledger_entries` RLS on the caller. Group members only see their
-- own group's rows.
--
-- Performance
-- ===========
-- The view does one scan of ledger_entries per per-type CTE (7 CTEs).
-- For V1 group sizes (<10K entries per group), this is fast. If it
-- becomes a hotspot, materialize via incremental triggers — Phase 6
-- consideration.
--
-- Rollback
-- ========
-- drop view public.member_obligations_view;
-- iOS gracefully falls back to client-side `recentEntries`
-- computation (limit 200) when the view is absent.

create or replace view public.member_obligations_view as
with stake_cash as (
  select group_id,
         from_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'contribution'
     and coalesce((metadata->>'in_kind'), 'false') <> 'true'
     and from_member_id is not null
   group by group_id, from_member_id, currency
),
stake_in_kind as (
  select group_id,
         from_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'contribution'
     and (metadata->>'in_kind') = 'true'
     and from_member_id is not null
   group by group_id, from_member_id, currency
),
expense_owed as (
  select group_id,
         to_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'expense'
     and to_member_id is not null
   group by group_id, to_member_id, currency
),
reimbursed as (
  -- Pool payments back to a member. Accept BOTH directions:
  --   * iOS convention (FASE 4 Wave 4): from=member, to=NULL
  --   * Legacy: to=member (pre-mig)
  -- and `payout` (to=member, canonical pool→member outflow).
  select group_id,
         coalesce(from_member_id, to_member_id) as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where (type = 'reimbursement'
            and (from_member_id is not null or to_member_id is not null))
      or (type = 'payout' and to_member_id is not null)
   group by group_id, coalesce(from_member_id, to_member_id), currency
),
fines_issued as (
  select group_id,
         from_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'fine_issued'
     and from_member_id is not null
   group by group_id, from_member_id, currency
),
fines_paid as (
  select group_id,
         from_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'fine_paid'
     and from_member_id is not null
   group by group_id, from_member_id, currency
),
fines_voided as (
  -- fine_voided writes from=member, to=NULL (mig 00148).
  select group_id,
         from_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'fine_voided'
     and from_member_id is not null
   group by group_id, from_member_id, currency
),
settlements_received as (
  select group_id,
         to_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'settlement'
     and to_member_id is not null
   group by group_id, to_member_id, currency
),
settlements_sent as (
  select group_id,
         from_member_id as member_id,
         currency,
         sum(amount_cents) as cents
    from public.ledger_entries
   where type = 'settlement'
     and from_member_id is not null
   group by group_id, from_member_id, currency
),
all_keys as (
  select group_id, member_id, currency from stake_cash
  union
  select group_id, member_id, currency from stake_in_kind
  union
  select group_id, member_id, currency from expense_owed
  union
  select group_id, member_id, currency from reimbursed
  union
  select group_id, member_id, currency from fines_issued
  union
  select group_id, member_id, currency from fines_paid
  union
  select group_id, member_id, currency from fines_voided
  union
  select group_id, member_id, currency from settlements_received
  union
  select group_id, member_id, currency from settlements_sent
)
select
  k.group_id,
  k.member_id,
  k.currency,
  coalesce(sc.cents,  0)::bigint as stake_cents,
  coalesce(sk.cents,  0)::bigint as stake_in_kind_cents,
  greatest(
    coalesce(eo.cents, 0) - coalesce(re.cents, 0),
    0
  )::bigint as receivable_cents,
  greatest(
    coalesce(fi.cents, 0) - coalesce(fp.cents, 0) - coalesce(fv.cents, 0),
    0
  )::bigint as obligation_cents,
  coalesce(sr.cents,  0)::bigint as settlement_received_cents,
  coalesce(ss.cents,  0)::bigint as settlement_sent_cents,
  (
    greatest(coalesce(eo.cents, 0) - coalesce(re.cents, 0), 0)
    + coalesce(sr.cents, 0)
    - greatest(coalesce(fi.cents, 0) - coalesce(fp.cents, 0) - coalesce(fv.cents, 0), 0)
    - coalesce(ss.cents, 0)
  )::bigint as net_peer_position_cents
from all_keys k
left join stake_cash         sc on (sc.group_id, sc.member_id, sc.currency) = (k.group_id, k.member_id, k.currency)
left join stake_in_kind      sk on (sk.group_id, sk.member_id, sk.currency) = (k.group_id, k.member_id, k.currency)
left join expense_owed       eo on (eo.group_id, eo.member_id, eo.currency) = (k.group_id, k.member_id, k.currency)
left join reimbursed         re on (re.group_id, re.member_id, re.currency) = (k.group_id, k.member_id, k.currency)
left join fines_issued       fi on (fi.group_id, fi.member_id, fi.currency) = (k.group_id, k.member_id, k.currency)
left join fines_paid         fp on (fp.group_id, fp.member_id, fp.currency) = (k.group_id, k.member_id, k.currency)
left join fines_voided       fv on (fv.group_id, fv.member_id, fv.currency) = (k.group_id, k.member_id, k.currency)
left join settlements_received sr on (sr.group_id, sr.member_id, sr.currency) = (k.group_id, k.member_id, k.currency)
left join settlements_sent     ss on (ss.group_id, ss.member_id, ss.currency) = (k.group_id, k.member_id, k.currency);

comment on view public.member_obligations_view is
  'FASE 4 Wave 4 / Phase 5 foundation (mig 20260525230000): per (group, member, currency) breakdown of stake / receivable / obligation / settlement net. Replaces the naïve `net_cents` from `member_balances_per_group` for surfaces that need to distinguish capital injection from debt. iOS "Tu posición" + greedy settlement plan should read from THIS view, not from member_balances_per_group.';

grant select on public.member_obligations_view to authenticated;
