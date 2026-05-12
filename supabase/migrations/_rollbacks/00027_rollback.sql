-- Rollback for 00027_can_modify_rules_use_roles_jsonb.sql
-- Reverts can_modify_rules to the original 00024 implementation
-- (uses legacy `role` TEXT column).

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
    when 'founder'   then v_member.role = 'founder'
    when 'anyMember' then true
    else false
  end;
end;
$$;
