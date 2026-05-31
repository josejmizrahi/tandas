-- 00041 — Polymorphic resource_id on fines + fine_review_periods.
--
-- Audit doc § 5.3 items 9+11 (combined sprint, step 3/3). Adds the new
-- polymorphic foreign key column to both fine tables, enabling Phase 2
-- fines for non-event resources (slot decline, fund non-contribution,
-- etc.). Until V2 drops `event_id`, both columns coexist and writers
-- populate both.
--
-- Pre-requisites:
--   - 00039 dual-write trigger active (events → resources keep in sync)
--   - 00040 backfill complete (every existing event has a matching
--     resources row with the SAME id). Verifies via
--     `events_resources_parity_check()`.
--
-- Why nullable + ON DELETE SET NULL:
--   - Matches the existing `event_id` semantics on `fines` (legacy:
--     SET NULL on delete). Preserves audit trail when the source
--     resource is removed.
--   - For `fine_review_periods` we keep the original `ON DELETE
--     CASCADE` semantic (the review period is meaningless without the
--     resource it gates).
--
-- Backfill is trivial: `resource_id = event_id` because Migration B
-- (00040) preserved the same UUID across both tables.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS, UPDATE filtered to NULL slugs.

-- =============================================================================
-- fines
-- =============================================================================

alter table public.fines
  add column if not exists resource_id uuid
    references public.resources(id) on delete set null;

comment on column public.fines.resource_id is
  'Polymorphic resource the fine is associated with. V1 fines mirror event_id (resources.id = events.id post-00040). Phase 2 fines (slot decline, fund non-contribution, etc.) fill this column with non-event resource ids while event_id stays NULL. Drop event_id pre-Phase 2 cleanup.';

update public.fines
set    resource_id = event_id
where  resource_id is null
  and  event_id is not null;

create index if not exists fines_resource_id_idx
  on public.fines(resource_id)
  where resource_id is not null;

-- =============================================================================
-- fine_review_periods
-- =============================================================================

alter table public.fine_review_periods
  add column if not exists resource_id uuid
    references public.resources(id) on delete cascade;

comment on column public.fine_review_periods.resource_id is
  'Polymorphic resource the review period gates. Mirror of event_id during V1 cohabitation. Phase 2 review periods may attach to slot/fund resources.';

update public.fine_review_periods
set    resource_id = event_id
where  resource_id is null
  and  event_id is not null;

create index if not exists fine_review_periods_resource_id_idx
  on public.fine_review_periods(resource_id)
  where resource_id is not null;

-- Note: the existing UNIQUE(event_id) constraint stays on
-- fine_review_periods. A matching UNIQUE(resource_id) is NOT added in
-- this migration because:
--   1. event_id and resource_id are 1:1 today (same UUID), so the
--      existing constraint already enforces resource_id uniqueness
--      transitively.
--   2. Adding a second UNIQUE on a still-NULL column for some
--      resource-types (post-event_id drop) would block valid Phase 2
--      flows. Defer until event_id is dropped.

-- =============================================================================
-- Verification helper
-- =============================================================================

create or replace function public.fines_resource_id_parity_check()
returns table (
  fines_with_event_no_resource bigint,
  fines_with_resource_no_event bigint,
  fines_total bigint,
  review_periods_with_event_no_resource bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    (select count(*) from public.fines
       where event_id is not null and resource_id is null) as fines_with_event_no_resource,
    (select count(*) from public.fines
       where resource_id is not null and event_id is null) as fines_with_resource_no_event,
    (select count(*) from public.fines)                    as fines_total,
    (select count(*) from public.fine_review_periods
       where event_id is not null and resource_id is null) as review_periods_with_event_no_resource
$$;

comment on function public.fines_resource_id_parity_check() is
  'Audit doc § 5.3 items 9+11. Returns counts of fines/review_periods missing the polymorphic resource_id. fines_with_event_no_resource MUST be 0 after backfill; fines_with_resource_no_event is allowed (Phase 2 non-event fines).';

revoke execute on function public.fines_resource_id_parity_check() from public, anon;
grant  execute on function public.fines_resource_id_parity_check() to authenticated;
