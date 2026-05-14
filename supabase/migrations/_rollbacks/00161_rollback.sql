-- Rollback for 00161_realtime_publication_for_multidevice.sql
--
-- Removes the four tables from the supabase_realtime publication and
-- reverts replica identity to DEFAULT. Run only if E-3.1 rolls back
-- entirely — leaving the publication populated is harmless and the iOS
-- client tolerates Realtime being unavailable.

alter publication supabase_realtime drop table public.fines;
alter publication supabase_realtime drop table public.vote_casts;
alter publication supabase_realtime drop table public.votes;
alter publication supabase_realtime drop table public.user_actions;

alter table public.fines        replica identity default;
alter table public.vote_casts   replica identity default;
alter table public.votes        replica identity default;
alter table public.user_actions replica identity default;
