-- Rollback for 00164_rsvp_check_in_realtime_publication.sql

alter publication supabase_realtime drop table public.check_in_actions;
alter publication supabase_realtime drop table public.rsvp_actions;

alter table public.check_in_actions replica identity default;
alter table public.rsvp_actions     replica identity default;
