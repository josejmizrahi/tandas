-- 20260525221500 — split shared pool in-cents into cash vs in-kind.
--
-- FASE 4 Wave 4 audit (founder 2026-05-25): the shared pool balance
-- today (`shared_pool_in_cents = SUM contribution`) mixes cash and
-- in-kind (terrenos, equipo, etc) contributions in a single number.
-- Users read the pool number as "cash en caja" and get confused when
-- it jumps after someone aportó un activo en especie.
--
-- This migration narrows the existing columns' semantics + appends
-- two new columns:
--
--   * shared_pool_in_cents          (existing) — cash contributions
--                                     only (metadata.in_kind != 'true')
--   * shared_pool_balance_cents     (existing) — cash_in − cash_out
--                                     (no in-kind)
--   * shared_pool_in_kind_cents     (new, appended) — in-kind sum
--   * shared_pool_total_value_cents (new, appended) — gross value
--                                     (cash balance + in-kind)
--
-- Why CREATE OR REPLACE keeps prior column order
-- ==============================================
-- Postgres rejects reordering columns in a view via CREATE OR REPLACE
-- (`cannot change name of view column ...`). We APPEND the new
-- columns at the end and keep `shared_pool_in_cents` / `out_cents` /
-- `balance_cents` in their original positions. Backwards-compatible
-- for any consumer that selects by name.
--
-- Backwards compat
-- ================
-- `shared_pool_in_cents` keeps its name but its semantic narrows to
-- cash-only. Groups without in-kind contributions see no change.
-- Groups WITH in-kind contributions get a smaller pool balance —
-- correctly, since assets are now surfaced separately via
-- `shared_pool_in_kind_cents`.
--
-- Math reference
-- ==============
-- Old: in_cents = SUM(amount) WHERE type='contribution'
-- New: in_cents = SUM(amount) WHERE type='contribution'
--                              AND COALESCE(metadata->>'in_kind','false') != 'true'
--      in_kind_cents = SUM(amount) WHERE type='contribution'
--                                  AND metadata->>'in_kind' = 'true'
-- Other types (settlement, payout, fine_*) still excluded — Phase 5.
--
-- Rollback
-- ========
-- _rollbacks/20260525221500_rollback.sql re-creates the old view
-- definition. Non-destructive — view-only change, no data touched.

create or replace view public.group_money_summary_view as
with le_typed as (
  select
    le.*,
    coalesce((le.metadata->>'in_kind'), 'false') = 'true' as is_in_kind
  from public.ledger_entries le
)
select
  r.group_id,
  coalesce(le.currency, r.metadata->>'currency', 'MXN') as currency,
  r.id as shared_pool_id,
  coalesce(
    sum(le.amount_cents) filter (
      where le.type = 'contribution' and le.is_in_kind = false
    ), 0
  )::bigint as shared_pool_in_cents,
  coalesce(
    sum(le.amount_cents) filter (where le.type = 'expense'), 0
  )::bigint as shared_pool_out_cents,
  (
    coalesce(sum(le.amount_cents) filter (
      where le.type = 'contribution' and le.is_in_kind = false
    ), 0)
    - coalesce(sum(le.amount_cents) filter (where le.type = 'expense'), 0)
  )::bigint as shared_pool_balance_cents,
  count(le.id)::bigint as entry_count,
  max(le.occurred_at) as last_activity_at,
  -- New columns appended at end (CREATE OR REPLACE preserves prior order):
  coalesce(
    sum(le.amount_cents) filter (
      where le.type = 'contribution' and le.is_in_kind = true
    ), 0
  )::bigint as shared_pool_in_kind_cents,
  (
    coalesce(sum(le.amount_cents) filter (where le.type = 'contribution'), 0)
    - coalesce(sum(le.amount_cents) filter (where le.type = 'expense'), 0)
  )::bigint as shared_pool_total_value_cents
from public.resources r
left join le_typed le
  on le.resource_id = r.id
 and le.group_id    = r.group_id
where r.resource_type = 'fund'
  and (r.metadata->>'is_shared_pool') = 'true'
  and r.archived_at is null
group by r.group_id, r.id, r.metadata, le.currency;

comment on view public.group_money_summary_view is
  'Updated 2026-05-25 (FASE 4 Wave 4): splits in-cents into cash vs in-kind contributions. `shared_pool_in_cents` is now cash only; `shared_pool_balance_cents` excludes in-kind. New `shared_pool_in_kind_cents` and `shared_pool_total_value_cents` columns appended at the end (CREATE OR REPLACE preserves prior column order). Other ledger types (settlement, payout, fine_*) still excluded — Phase 5 will surface obligations.';

grant select on public.group_money_summary_view to authenticated;
