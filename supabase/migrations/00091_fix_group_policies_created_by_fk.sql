-- 00091_fix_group_policies_created_by_fk.sql
-- Bring the live group_policies.created_by FK into alignment with the
-- canonical 00087 file. The first apply of 00087 against the live DB
-- happened mid-iteration with an earlier version that did NOT include
-- `on delete set null`; the polish commit landed locally afterward.
-- On fresh DBs, 00087 already creates the FK with the correct action;
-- this migration is a no-op for those (the DROP/ADD just re-emits the
-- same constraint).

alter table public.group_policies
  drop constraint if exists group_policies_created_by_fkey;

alter table public.group_policies
  add constraint group_policies_created_by_fkey
  foreign key (created_by) references auth.users(id) on delete set null;
