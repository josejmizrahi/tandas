-- 20260527235000 — Realtime publication for V2-A1 stores.
--
-- Why
-- ===
-- V2Plan §V2-A1 ("Real-time subscriptions"). The iOS app needs the
-- three high-traffic canonical surfaces (timeline / disputes /
-- decisions) to refresh in-place when a remote write lands, so users
-- on a second device or a co-member's device see new state without
-- pull-to-refresh.
--
-- Follows the canonical pattern set by mig 00161
-- (`realtime_publication_for_multidevice`): REPLICA IDENTITY FULL +
-- idempotent ALTER PUBLICATION. Required because Supabase Realtime
-- re-evaluates RLS quals against the WAL row image, and our RLS keys
-- off `group_id` (non-PK), so the publisher must ship the full row.
--
-- What
-- ====
-- 1. REPLICA IDENTITY FULL on the three canonical tables.
-- 2. ALTER PUBLICATION supabase_realtime ADD TABLE (idempotent).
--
-- Cost
-- ====
-- Same calculus as 00161 — Beta-1 scale write volume is negligible.
-- group_events is the heaviest of the three (append-only audit log,
-- ~130 rows in dev today), but inserts are small JSON envelopes.
--
-- Rollback
-- ========
-- See `_rollbacks/20260527235000_rollback.sql`.

-- =========================================================================
-- 1. REPLICA IDENTITY FULL
-- =========================================================================

alter table public.group_events    replica identity full;
alter table public.group_disputes  replica identity full;
alter table public.group_decisions replica identity full;

-- =========================================================================
-- 2. Publication membership (idempotent)
-- =========================================================================

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'group_events'
  ) then
    alter publication supabase_realtime add table public.group_events;
  end if;
end$$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'group_disputes'
  ) then
    alter publication supabase_realtime add table public.group_disputes;
  end if;
end$$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'group_decisions'
  ) then
    alter publication supabase_realtime add table public.group_decisions;
  end if;
end$$;

comment on table public.group_events is
  'Primitive 13 (Memory). Universal append-only audit log. id is a monotonic database cursor for order/pagination/replay, NOT a gapless sequence and NOT a strict commit-time clock. uuid_id is the stable public identifier for cross-entity references. Use occurred_at/created_at for human chronology. Realtime-published (mig 20260527235000) so live timelines update without pull-to-refresh.';
comment on table public.group_disputes is
  'Primitive 14 (Conflict resolution). State machine: open → mediation → resolved | escalated_to_vote. Realtime-published (mig 20260527235000) so new disputes / state transitions surface live.';
comment on table public.group_decisions is
  'Primitive 16 (Decisions) + 22 (Legitimacy) — every decision records what method made it legitimate. Realtime-published (mig 20260527235000) so vote open/close transitions propagate live.';
