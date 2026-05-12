-- 00091_rollback.sql
-- Reverts the FK to NO ACTION (the state that lived before the fix-up).
alter table public.group_policies
  drop constraint if exists group_policies_created_by_fkey;

alter table public.group_policies
  add constraint group_policies_created_by_fkey
  foreign key (created_by) references auth.users(id);
