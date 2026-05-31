-- 00025_unique_open_vote_per_reference.sql
-- Prevents two open votes simultaneously for the same (vote_type, reference_id).
-- Protects rule_repeal, fine_appeal, and any other reference-based vote_type
-- from accidental double-opens (race condition in start_vote).
-- General-proposal votes without reference_id are exempt.
--
-- Pre-flight: zero violators in production verified 2026-05-05.

create unique index uniq_open_vote_per_reference
on public.votes (vote_type, reference_id)
where status = 'open' and reference_id is not null;

comment on index public.uniq_open_vote_per_reference is
  'Prevents simultaneous open votes for the same (vote_type, reference_id). '
  'Added 2026-05-05 as part of EditRulesView (Plan UI P0 #1).';
