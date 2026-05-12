-- Rollback for 00043_resolve_user_action_on_vote_cast.

drop trigger if exists vote_casts_resolve_user_action on public.vote_casts;
drop function if exists public.resolve_user_action_on_vote_cast();
