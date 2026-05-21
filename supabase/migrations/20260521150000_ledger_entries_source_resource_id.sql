-- 00356 — ledger_entries.source_resource_id column (SharedMoney Phase 1, brick 1).
--
-- Why
-- ===
-- Shared Money doctrine (founder 2026-05-21, doctrine_shared_money.md):
-- every money movement *relates to* something humans can name — a cena,
-- an asset, a viaje. Today that "something" is mashed into
-- ledger_entries.metadata->>'source_event_id' (mig 00344), which:
--
--   1. Is event-only (the field name lies — it can never point to an
--      asset or space).
--   2. Lives in jsonb, so the new per-resource projections we need in
--      Phase 1 (resource_money_view, group_money_summary_view) can't
--      cleanly index it.
--   3. Conflates "money relates to" with "money lives in" (the latter
--      is `resource_id`, which is the fund the row debits/credits).
--
-- This migration promotes source_event_id → first-class
-- `source_resource_id` column, FK-validated to `public.resources(id)`,
-- with two indexes covering the views Phase 1 will create.
--
-- Backfill posture
-- ================
-- Audited 2026-05-21: prod has 31 ledger_entries rows, ZERO of them
-- carry metadata.source_event_id. No backfill needed. New column lands
-- as NULL on existing rows — semantically correct (those rows had no
-- intent to attribute to a source resource).
--
-- Compat for source_event_id
-- ==========================
-- This migration ONLY adds the column. It does NOT yet:
--   * change fund_contribute / fund_record_expense to write the column
--     (that's mig 00359 in the Phase 1 plan).
--   * remove the metadata.source_event_id key (a future cycle, after
--     iOS callers switch to p_source_resource_id).
--
-- Why split: keeping the schema change isolated from RPC behavior
-- changes means this brick is reversible without coordinating an
-- iOS client release. The column can exist + sit empty + be ignored
-- by the RPC until mig 00359 wires it in.
--
-- FK behavior
-- ===========
-- ON DELETE SET NULL: the ledger is append-only — if the source
-- resource is hard-deleted (rare; soft-delete via archived_at is the
-- norm), the entry row stays but its source pointer detaches. Choice
-- preserves history; archived_at soft-deletes don't fire the FK
-- anyway. NO ON UPDATE clause — resource ids are uuid surrogate keys
-- and never change.
--
-- Indexes
-- =======
-- 1. `idx_ledger_source_resource` (partial, WHERE NOT NULL): direct
--    "show me everything tied to this event" queries. Tiny — most
--    Phase 1 rows will leave it NULL.
-- 2. `idx_ledger_group_source_resource` (composite (group_id,
--    source_resource_id) WHERE NOT NULL): backs the Phase 1
--    `resource_money_view` aggregation pattern (filter by group, group
--    by source). Composite leading on group_id mirrors the existing
--    `idx_ledger_group_time` shape.
--
-- Both partial: `WHERE source_resource_id IS NOT NULL` keeps the index
-- size proportional to actual usage, not the total ledger size.
--
-- Rollback
-- ========
-- _rollbacks/20260521150000_rollback.sql drops the two indexes, the
-- FK, then the column. Safe — no code reads the column yet (mig 00359
-- is what wires it in). Existing rows lose only a NULL column.

alter table public.ledger_entries
  add column if not exists source_resource_id uuid;

comment on column public.ledger_entries.source_resource_id is
  'Context, not flow. The event/asset/space/etc. that this movement RELATES TO. Distinct from resource_id (the fund the money LIVES IN). Mig 00356 (SharedMoney Phase 1). Was metadata->>source_event_id (mig 00344) — promoted to a column for projection indexability + genericized beyond events.';

-- FK to resources(id). ON DELETE SET NULL preserves append-only ledger
-- history even if the source resource is later hard-deleted.
alter table public.ledger_entries
  add constraint ledger_entries_source_resource_id_fkey
  foreign key (source_resource_id)
  references public.resources(id)
  on delete set null;

create index if not exists idx_ledger_source_resource
  on public.ledger_entries (source_resource_id)
  where source_resource_id is not null;

create index if not exists idx_ledger_group_source_resource
  on public.ledger_entries (group_id, source_resource_id)
  where source_resource_id is not null;

comment on index public.idx_ledger_source_resource is
  'SharedMoney Phase 1 (mig 00356): partial index for "all movements tied to <resource>" queries. Backs resource_money_view (mig 00361).';

comment on index public.idx_ledger_group_source_resource is
  'SharedMoney Phase 1 (mig 00356): composite (group_id, source_resource_id) for per-group aggregation by source. Backs resource_money_view + group_money_summary_view (migs 00360-00361).';
