-- 00053 — Drop legacy appeals/appeal_votes/appeal_vote_counts surface area.
-- (Originally 00047; renamed in repo. Prod migration name remains
-- "00047_drop_appeals_legacy" — applied 2026-05-08 22:26 UTC.)
--
-- Audit § 2.2 (obsoleto) + § 5.2 item 7. Pre-req: iOS LiveAppealRepository
-- has shipped using the votes-only path (start_fine_appeal helper from
-- 00046, plus generic cast_vote/finalize_vote and direct SELECTs from
-- votes/vote_casts).
--
-- Server-side cohabitation cleanup:
--   - drop view appeal_vote_counts
--   - drop triggers on appeal_votes (appeal_votes_after_insert,
--     appeal_votes_after_choice_change) plus their function
--     on_appeal_vote_cast
--   - drop trigger appeals_set_updated_at + appeal_votes_set_updated_at
--   - drop legacy RPCs start_appeal, cast_appeal_vote, close_appeal_vote
--   - drop tables appeal_votes, appeals
--   - drop policies (RLS) on those tables (cascaded by drop table)
--
-- Data audit before this migration:
-- ---------------------------------
-- prod has 1 row in appeals (test row from 00020 backfill validation) and
-- 0 actual ballots in appeal_votes. No live fine_appeal flows ever closed
-- via the legacy path; the audit § 2.2 update on 2026-05-07 confirmed
-- this. Backfill 00020 already mirrored that 1 row into votes/vote_casts.
--
-- After this migration, all fine_appeal data lives ONLY in votes/vote_casts.

-- =========================================================
-- 1. Triggers + functions
-- =========================================================
drop trigger if exists appeal_votes_after_insert        on public.appeal_votes;
drop trigger if exists appeal_votes_after_choice_change on public.appeal_votes;
drop trigger if exists appeal_votes_set_updated_at      on public.appeal_votes;
drop trigger if exists appeals_set_updated_at           on public.appeals;

drop function if exists public.on_appeal_vote_cast() cascade;

-- =========================================================
-- 2. Legacy RPCs
-- =========================================================
drop function if exists public.start_appeal(uuid, text)   cascade;
drop function if exists public.cast_appeal_vote(uuid, text) cascade;
drop function if exists public.close_appeal_vote(uuid)    cascade;

-- =========================================================
-- 3. Aggregate view
-- =========================================================
drop view if exists public.appeal_vote_counts cascade;

-- =========================================================
-- 4. Tables (cascades RLS policies + remaining FKs)
-- =========================================================
drop table if exists public.appeal_votes cascade;
drop table if exists public.appeals      cascade;
