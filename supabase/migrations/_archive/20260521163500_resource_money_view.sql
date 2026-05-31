-- 00362 — resource_money_view (SharedMoney Phase 1, brick 7, FINAL).
--
-- Why
-- ===
-- Phase 4 will land a "Money Block" on Event / Asset / Space detail
-- pages showing money movements attributed to that specific resource
-- via `ledger_entries.source_resource_id`. That UI needs ONE
-- projection it can read with `eq('source_resource_id', X)` to render:
--
--   "Gastos de Cena Shabbat:
--      total gastado · contribuciones · quién pagó · última actividad"
--
-- This view aggregates ledger_entries per (group_id, source_resource_id,
-- currency). It is intentionally INDEPENDENT of which fund the
-- movement lives in — a contribution to the shared pool tagged with
-- source_resource_id=<event> and an expense from a protected fund
-- tagged with the same source_resource_id both surface here.
--
-- Reasoning: from the resource's perspective, "money I'm responsible
-- for" doesn't care which compartment it came from. The compartment
-- info is in `resource_id` (the fund row) — already projected by
-- `fund_balance_view` and `group_money_summary_view` if needed.
--
-- Shape
-- =====
-- One row per (group_id, source_resource_id, currency). Columns:
--   * group_id            uuid
--   * source_resource_id  uuid
--   * currency            text
--   * spent_cents         bigint — SUM(expense)
--   * contributed_cents   bigint — SUM(contribution)
--   * entry_count         bigint
--   * last_activity_at    timestamptz
--   * payer_count         bigint — distinct metadata.paid_by_member_id
--                                  (counts unique people who fronted
--                                  cash; 0 when no entries carry the
--                                  paid_by annotation)
--   * latest_recorded_by  uuid — `recorded_by` of the most-recent entry
--                                (used for "last activity by X" hints
--                                in the Money Block header)
--
-- Math posture
-- ============
-- Only `expense` and `contribution` types feed the totals. Other
-- types (settlement, payout, fine_*, reimbursement) are silent on
-- this view — Phase 5 obligations / settle-up has its own surface.
--
-- Empty state
-- ===========
-- Rows only appear when at least one ledger entry exists with that
-- source_resource_id. A resource with zero attributed movements
-- has no row — Phase 4 UI must handle the "no movements yet" copy.
-- Intentional: a view over LEFT-joined resources would explode in
-- size (every event × every group, mostly zeros).
--
-- RLS
-- ===
-- Inherits ledger_entries RLS via `security invoker` semantics.
-- Members read movements for their groups only.
--
-- Indexes
-- =======
-- Already covered by mig 00356:
--   * idx_ledger_group_source_resource (composite filter) — backs the
--     WHERE source_resource_id IS NOT NULL + GROUP BY pattern.
--   * idx_ledger_source_resource — backs per-resource WHERE filter
--     when Phase 4 UI does `eq('source_resource_id', X)`.
--
-- Rollback
-- ========
-- _rollbacks/20260521163500_rollback.sql drops the view. No data
-- side-effects.

create or replace view public.resource_money_view as
select
  le.group_id,
  le.source_resource_id,
  le.currency,
  coalesce(sum(le.amount_cents) filter (where le.type = 'expense'), 0)::bigint
    as spent_cents,
  coalesce(sum(le.amount_cents) filter (where le.type = 'contribution'), 0)::bigint
    as contributed_cents,
  count(*)::bigint as entry_count,
  max(le.occurred_at) as last_activity_at,
  count(distinct (le.metadata->>'paid_by_member_id'))
    filter (where le.metadata ? 'paid_by_member_id')::bigint
    as payer_count,
  (
    array_agg(le.recorded_by order by le.occurred_at desc nulls last)
  )[1] as latest_recorded_by
from public.ledger_entries le
where le.source_resource_id is not null
  and le.type in ('expense', 'contribution')
group by le.group_id, le.source_resource_id, le.currency;

comment on view public.resource_money_view is
  'SharedMoney Phase 1 (mig 00362): per-(group, source_resource_id, currency) projection of all expense+contribution ledger movements attributed to a specific resource (event/asset/space/etc.). Backed by idx_ledger_group_source_resource. Phase 4 Money Block reads with eq(source_resource_id, X). Other ledger types (settlement/payout/fine_*) are excluded — Phase 5 surfaces them via obligations. Resources with zero movements have NO row (empty state handled by UI).';

grant select on public.resource_money_view to authenticated;
