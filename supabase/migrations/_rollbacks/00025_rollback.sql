-- Rollback for 00025_unique_open_vote_per_reference.sql

drop index if exists public.uniq_open_vote_per_reference;
