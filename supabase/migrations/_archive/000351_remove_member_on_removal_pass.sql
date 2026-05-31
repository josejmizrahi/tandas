-- 00035_remove_member_on_removal_pass.sql
--
-- Mirror of `archive_rule_on_repeal_pass` (00026), for the `member_removal`
-- vote_type. When a member_removal vote resolves passed, this trigger
-- deletes the corresponding `group_members` row so the affected user
-- effectively loses access (RLS policies on dependent tables key off
-- group_members, so the deletion is sufficient — no cascade hand-roll
-- needed).
--
-- Schema contract for the vote (set by the iOS start-vote caller):
--   - vote_type      = 'member_removal'
--   - reference_id   = auth.users.id of the member being voted out
--   - payload        = { reason?: string }
--   - group_id       = the group losing the member
--
-- After the trigger fires, the deletion cascades any FK-protected rows
-- (turn_order, fines.user_id is nullable, etc.). We rely on the cascade
-- definitions in 00001+00002 — no extra cleanup here.
--
-- Idempotent: running this migration twice replaces the function and
-- recreates the trigger via DROP-IF-EXISTS + CREATE.

create or replace function public.remove_member_on_removal_pass()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.vote_type = 'member_removal'
     and new.status = 'resolved'
     and old.status = 'open'
     and (new.payload->>'resolution') = 'passed'
     and new.reference_id is not null then
    delete from public.group_members
    where group_id = new.group_id
      and user_id  = new.reference_id;
  end if;
  return new;
end;
$$;

comment on function public.remove_member_on_removal_pass() is
  'Removes a member when its member_removal vote resolves passed. Watches votes.status open→resolved. Mirrors archive_rule_on_repeal_pass (00026).';

drop trigger if exists remove_member_on_removal_pass on public.votes;
create trigger remove_member_on_removal_pass
after update on public.votes
for each row
execute function public.remove_member_on_removal_pass();
