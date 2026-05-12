-- Rollback for 00020_platform_votes_generic.sql
-- NOT applied automatically. Drops generic vote tables; data lives only in
-- legacy appeals/appeal_votes after rollback.

drop function if exists public.finalize_vote(uuid);
drop function if exists public.cast_vote(uuid, text);
drop function if exists public.start_vote(uuid, text, uuid, text, text, jsonb, int, int, int, boolean);

drop policy if exists vote_casts_update_own_open on public.vote_casts;
drop policy if exists vote_casts_select_own on public.vote_casts;
drop policy if exists votes_select_members on public.votes;

drop view if exists public.vote_counts_view;

drop index if exists public.vote_casts_member_idx;
drop index if exists public.vote_casts_vote_idx;
drop table if exists public.vote_casts;

drop index if exists public.votes_open_closing_idx;
drop index if exists public.votes_type_idx;
drop index if exists public.votes_reference_idx;
drop index if exists public.votes_group_status_idx;
drop table if exists public.votes;
