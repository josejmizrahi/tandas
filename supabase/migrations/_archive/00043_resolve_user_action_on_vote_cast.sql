-- 00043 — Auto-resolve `user_actions` when a vote ballot is cast.
--
-- Bug discovered during Beta 1 smoke: after casting a vote, the
-- `votePending` (or `appealVotePending`) inbox row stayed visible in
-- HomeView's Pendientes section forever. `cast_vote` RPC only updates
-- the ballot + emits a `voteCast` system event — it never resolved the
-- corresponding user_action.
--
-- Fix: AFTER UPDATE trigger on `vote_casts` that, when `cast_at` flips
-- from NULL to a timestamp (or changes), resolves any matching
-- unresolved user_action for the casting member's user.
--
-- `appealVotePending` and `votePending` are the two action_types that
-- reference a vote_id. Both should resolve when the user casts.
--
-- Idempotent: trigger uses CREATE OR REPLACE; trigger uses DROP IF
-- EXISTS / CREATE.

create or replace function public.resolve_user_action_on_vote_cast()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
begin
  if NEW.cast_at is not null and (OLD.cast_at is null or OLD.cast_at <> NEW.cast_at) then
    select user_id into v_user_id
    from public.group_members
    where id = NEW.member_id;

    if v_user_id is not null then
      update public.user_actions
      set resolved_at = now()
      where action_type in ('votePending', 'appealVotePending')
        and reference_id = NEW.vote_id
        and user_id = v_user_id
        and resolved_at is null;
    end if;
  end if;
  return NEW;
end;
$$;

comment on function public.resolve_user_action_on_vote_cast() is
  'Auto-resolves votePending / appealVotePending user_actions when a member casts (cast_at flips). Companion to cast_vote RPC.';

drop trigger if exists vote_casts_resolve_user_action on public.vote_casts;

create trigger vote_casts_resolve_user_action
  after update on public.vote_casts
  for each row execute function public.resolve_user_action_on_vote_cast();
