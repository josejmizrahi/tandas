begin;
drop function if exists public.merge_placeholder_into_user(uuid, uuid);
drop function if exists public._merge_group_members(uuid, uuid);
commit;
