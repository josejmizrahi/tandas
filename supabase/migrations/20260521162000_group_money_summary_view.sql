-- 00361 — group_money_summary_view (SharedMoney Phase 1, brick 6).
--
-- Why
-- ===
-- The Group Money UI in Phase 3 needs ONE projection per group that
-- answers: "how much money is in the shared pool, what's the activity?"
--
-- This view is intentionally scoped to the SHARED POOL only. Protected
-- funds (mig 00358 forward-compat flag) and legacy funds surface via
-- the existing `fund_balance_view` — they are NOT included here, so
-- the Group Money landing surface stays focused on the canonical pool.
--
-- Shape
-- =====
-- One row per (group_id, currency). For V1 single-currency groups
-- this is typically one row per group. Multi-currency activity in a
-- single group produces one row per currency (V1.5 case).
--
-- Columns:
--   * group_id              uuid
--   * currency              text
--   * shared_pool_id        uuid  — the canonical fund row (handy
--                                   for "open ledger" / write-paths)
--   * shared_pool_in_cents  bigint — sum of contributions
--   * shared_pool_out_cents bigint — sum of expenses
--   * shared_pool_balance_cents bigint — in - out
--   * entry_count           bigint
--   * last_activity_at      timestamptz NULL — most recent ledger entry
--
-- Math
-- ====
-- We aggregate `ledger_entries` filtered to `resource_id` matching a
-- shared pool row. Type-filtered:
--   in  := SUM amount WHERE type = 'contribution'
--   out := SUM amount WHERE type = 'expense'
-- Other types (settlement, payout, fine_*) are ignored — they don't
-- affect the SHARED POOL balance projection. Settlement net-of-debt
-- semantics will be handled by `member_obligations_view` in Phase 5.
--
-- Empty-state behavior
-- ====================
-- Every group has a shared pool (mig 00357 seed + mig 00359 backfill).
-- A pool with no ledger entries surfaces as: in=0, out=0, balance=0,
-- entry_count=0, last_activity_at=NULL. LEFT JOIN preserves the row.
--
-- RLS
-- ===
-- Postgres views run with `security invoker` semantics by default —
-- they enforce the underlying tables' RLS on the caller. The base
-- tables (`resources`, `ledger_entries`) already have RLS that
-- restricts reads to group members. The view inherits that — no
-- additional policy needed.
--
-- Rollback
-- ========
-- _rollbacks/20260521162000_rollback.sql drops the view. No data
-- side-effects.

create or replace view public.group_money_summary_view as
select
  r.group_id,
  coalesce(le.currency, r.metadata->>'currency', 'MXN') as currency,
  r.id as shared_pool_id,
  coalesce(sum(le.amount_cents) filter (where le.type = 'contribution'), 0)::bigint
    as shared_pool_in_cents,
  coalesce(sum(le.amount_cents) filter (where le.type = 'expense'), 0)::bigint
    as shared_pool_out_cents,
  (
    coalesce(sum(le.amount_cents) filter (where le.type = 'contribution'), 0)
    - coalesce(sum(le.amount_cents) filter (where le.type = 'expense'), 0)
  )::bigint as shared_pool_balance_cents,
  count(le.id)::bigint as entry_count,
  max(le.occurred_at) as last_activity_at
from public.resources r
left join public.ledger_entries le
  on le.resource_id = r.id
 and le.group_id    = r.group_id
where r.resource_type = 'fund'
  and (r.metadata->>'is_shared_pool') = 'true'
  and r.archived_at is null
group by r.group_id, r.id, r.metadata, le.currency;

comment on view public.group_money_summary_view is
  'SharedMoney Phase 1 (mig 00361): per-(group, currency) projection of the canonical shared pool. Scoped to is_shared_pool=true fund rows only — protected funds + legacy funds surface via fund_balance_view. Empty pools (no ledger activity) surface with all zeros. Other ledger types (settlement, payout, fine_*) are excluded from the balance math; obligations land in Phase 5.';

grant select on public.group_money_summary_view to authenticated;
