-- Rollback for 00166_user_actions_resolution_guard.sql

drop trigger if exists user_actions_resolution_guard on public.user_actions;
drop function if exists public.user_actions_resolution_only_guard();
