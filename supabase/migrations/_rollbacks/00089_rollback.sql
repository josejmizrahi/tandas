-- 00089_rollback.sql — undo apply_pending_change function + trigger.

drop trigger if exists votes_apply_on_pass_trg on public.votes;
drop function if exists public.votes_apply_on_pass();
drop function if exists public.apply_pending_change(uuid);
