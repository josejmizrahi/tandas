-- Rollback for 00014_platform_foundation.sql
-- NOT applied automatically.

drop function if exists public.close_appeal_vote(uuid);
drop function if exists public.cast_appeal_vote(uuid, text);
drop function if exists public.start_appeal(uuid, text);
drop function if exists public.record_system_event(uuid, text, uuid, uuid, jsonb);

drop view if exists public.appeal_vote_counts;
drop view if exists public.events_view;

drop table if exists public.fine_review_periods;
drop table if exists public.appeal_votes;
drop table if exists public.appeals;
drop table if exists public.user_actions;
drop table if exists public.system_events;
drop table if exists public.resources;

alter table public.rules
  drop column if exists consequences,
  drop column if exists conditions,
  drop column if exists is_active,
  drop column if exists name;
