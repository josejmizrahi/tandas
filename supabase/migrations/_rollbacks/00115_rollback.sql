-- 00115_rollback.sql
-- Reverts the leave_group / remove_member RPCs and the trigger's
-- emit path. group_members rows are left as-is — rolling back doesn't
-- reactivate soft-deleted memberships.

drop function if exists public.leave_group(uuid);
drop function if exists public.remove_member(uuid, uuid, text);

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
