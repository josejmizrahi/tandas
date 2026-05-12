-- 00119_rollback.sql
-- Reverts both group_policies CHECKs to their inline-enum form and
-- drops the helper functions.

alter table public.group_policies
  drop constraint if exists group_policies_policy_type_check;

alter table public.group_policies
  add constraint group_policies_policy_type_check
  check (policy_type = any (array['direct'::text, 'vote_required'::text, 'admin_only'::text, 'denied'::text]));

alter table public.group_policies
  drop constraint if exists group_policies_target_scope_check;

alter table public.group_policies
  add constraint group_policies_target_scope_check
  check (target_scope = any (array['group'::text, 'resource_type'::text, 'resource'::text]));

drop function if exists public.is_known_policy_type(text);
drop function if exists public.is_known_policy_target_scope(text);
