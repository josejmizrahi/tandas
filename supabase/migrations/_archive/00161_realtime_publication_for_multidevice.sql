-- 00161 — Realtime publication + REPLICA IDENTITY for multi-device sync.
--
-- Why
-- ===
-- Beta 1 Consolidation §6 W3 item E-3.1 ("RSVP/voto/multa cambia en
-- device A → device B refresca automáticamente"). Audit Track E
-- "Multi-device sync verdict: Read state not synced" (Plans/Active/
-- Beta1Consolidation_Audit.md:398).
--
-- Current state (verified 2026-05-13 evening):
--   - `supabase_realtime` publication exists with `puballtables=false`
--     and ZERO tables registered. Result: the iOS SDK opens channels
--     successfully but never receives any postgres_changes event.
--   - All four target tables (user_actions, votes, vote_casts, fines)
--     are at REPLICA IDENTITY DEFAULT (PK only in WAL old-row image).
--
-- For Supabase Realtime to deliver postgres_changes events past RLS,
-- the published WAL row must contain every column the RLS quals
-- reference — not just the primary key. Our RLS quals key off
-- non-PK columns:
--   - user_actions: user_id = auth.uid()
--   - votes:        EXISTS (...gm.group_id = votes.group_id...)
--   - vote_casts:   EXISTS (...gm.id = vote_casts.member_id...)
--   - fines:        is_group_member(group_id, auth.uid())
-- Without REPLICA IDENTITY FULL, RLS evaluation on the dispatched row
-- fails silently and the event is dropped. Setting FULL is the
-- standard Supabase Realtime + RLS configuration.
--
-- What
-- ====
-- 1. ALTER REPLICA IDENTITY FULL on the four tables.
-- 2. ALTER PUBLICATION supabase_realtime ADD TABLE for the same four.
--    Wrapped in a DO block per table so re-applying the migration is
--    idempotent (Postgres has no ADD TABLE IF NOT EXISTS for
--    publications).
--
-- Cost
-- ====
-- REPLICA IDENTITY FULL increases WAL volume because every UPDATE
-- writes the full old row. At Beta 1 scale (≤10 groups × ≤10 members
-- × low write frequency) the increase is negligible. For reference,
-- Supabase's official guidance treats FULL as the default for
-- realtime-published tables.
--
-- vote_casts replica identity is required even though the table is
-- write-once after start_vote (every cast UPDATEs an existing row from
-- start_vote's pre-seeded `pending` set, see mig 00020 line 402). The
-- UPDATE path is the multi-device signal.
--
-- Rollback
-- ========
-- See `_rollbacks/00161_rollback.sql`.
--
-- Verification (post-deploy)
-- ==========================
--   select schemaname, tablename from pg_publication_tables
--   where pubname = 'supabase_realtime'
--   order by tablename;
--   -- expect: user_actions, votes, vote_casts, fines (plus anything
--   --         a future migration may add)
--
--   select relname, relreplident from pg_class
--   where relname in ('user_actions','votes','vote_casts','fines')
--     and relnamespace = 'public'::regnamespace;
--   -- expect: relreplident = 'f' (FULL) for all four

-- =========================================================================
-- 1. REPLICA IDENTITY FULL
-- =========================================================================

alter table public.user_actions replica identity full;
alter table public.votes        replica identity full;
alter table public.vote_casts   replica identity full;
alter table public.fines        replica identity full;

-- =========================================================================
-- 2. Publication membership (idempotent)
-- =========================================================================

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'user_actions'
  ) then
    alter publication supabase_realtime add table public.user_actions;
  end if;
end$$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'votes'
  ) then
    alter publication supabase_realtime add table public.votes;
  end if;
end$$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'vote_casts'
  ) then
    alter publication supabase_realtime add table public.vote_casts;
  end if;
end$$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'fines'
  ) then
    alter publication supabase_realtime add table public.fines;
  end if;
end$$;

comment on table public.user_actions is
  'Inbox actions. Realtime-published (mig 00161) so device B refreshes when device A resolves.';
comment on table public.votes is
  'Votes header rows. Realtime-published (mig 00161) so status transitions (open→resolved) propagate cross-device.';
comment on table public.vote_casts is
  'One ballot per member per vote. Realtime-published (mig 00161) so the caster''s other device updates when they vote.';
comment on table public.fines is
  'Fines header rows. Realtime-published (mig 00161) so paid/voided/appealed transitions propagate cross-device.';
