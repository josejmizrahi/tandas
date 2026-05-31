-- 00027_can_modify_rules_use_roles_jsonb.sql
-- Fix discovered during EditRulesView QA prep on a real device 2026-05-05.
--
-- Original 00024_rule_mutation_audit.sql checked
--   v_member.role = 'founder'
-- against the legacy `group_members.role` TEXT column. Production data
-- has 'admin' for every active membership in that column; the
-- founder/member distinction lives in the newer `group_members.roles`
-- JSONB array (per Platform v2 in 00019). Result: founders never
-- passed the gate even when they should — pencil never appeared.
--
-- This patch swaps the predicate to `roles ? 'founder'` (jsonb-array
-- contains operator), matching the canonical role storage. The
-- 'anyMember' branch is unchanged.

create or replace function public.can_modify_rules(p_group_id uuid, p_user_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_governance_value text;
  v_member group_members;
begin
  select * into v_member
  from public.group_members
  where group_id = p_group_id and user_id = p_user_id and active
  limit 1;
  if not found then return false; end if;

  select governance->>'whoCanModifyRules' into v_governance_value
  from public.groups where id = p_group_id;

  return case v_governance_value
    when 'founder'   then v_member.roles ? 'founder'
    when 'anyMember' then true
    -- 'majorityVote' / 'supermajorityVote' / 'host' / 'treasurer' all
    -- require routing through a vote (or a non-V1 path); direct UPDATE
    -- is denied so client checks must funnel users to the vote flow.
    else false
  end;
end;
$$;

comment on function public.can_modify_rules(uuid, uuid) is
  'Returns true if the user may UPDATE rules in the group, per governance.whoCanModifyRules and roles JSONB array. Patched 2026-05-05 in 00027 to read roles instead of legacy role column.';
