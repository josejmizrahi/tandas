-- Rollback for 00239_resolve_governance_rule_fallback_uses_has_permission.sql
--
-- Restores the prior body from mig 00114 (last functional rewrite of
-- resolve_governance): the rule.% fallback compares created_by to
-- actor rather than consulting has_permission(modifyRules).

create or replace function public.resolve_governance(
  p_group_id        uuid,
  p_actor_user_id   uuid,
  p_target_action   text,
  p_target_payload  jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_is_member            boolean;
  v_policy               public.group_policies%rowtype;
  v_policy_found         boolean := false;
  v_quorum               int;
  v_threshold            int;
  v_duration             int;
  v_governance           jsonb;
  v_who                  text;
  v_created_by           uuid;
  v_resource_id_text     text := p_target_payload->>'resource_id';
  v_resource_type        text := p_target_payload->>'resource_type';
  v_required_permission  text;
begin
  select exists(select 1 from public.group_members gm where gm.group_id = p_group_id and gm.user_id = p_actor_user_id and gm.active = true) into v_is_member;
  if not v_is_member then return jsonb_build_object('decision', 'denied', 'reason', 'not_member'); end if;
  select p.* into v_policy from public.group_policies p
   where p.group_id = p_group_id and p.target_action = p_target_action and p.enabled = true
     and ((p.target_scope = 'resource' and v_resource_id_text is not null and p.target_resource_id is not null and p.target_resource_id::text = v_resource_id_text)
       or (p.target_scope = 'resource_type' and v_resource_type is not null and p.target_resource_type is not null and p.target_resource_type = v_resource_type)
       or (p.target_scope = 'group'))
   order by case p.target_scope when 'resource' then 1 when 'resource_type' then 2 when 'group' then 3 else 4 end asc, p.priority asc, p.created_at asc limit 1;
  if found then
    v_policy_found := true;
    if v_policy.policy_type = 'direct' then return jsonb_build_object('decision', 'allowed');
    elsif v_policy.policy_type = 'vote_required' then
      v_quorum := coalesce((v_policy.approval_config->>'quorum_percent')::int, 50);
      v_threshold := coalesce((v_policy.approval_config->>'threshold_percent')::int, 50);
      v_duration := coalesce((v_policy.approval_config->>'duration_hours')::int, 72);
      return jsonb_build_object('decision', 'vote_required', 'quorum_percent', v_quorum, 'threshold_percent', v_threshold, 'duration_hours', v_duration);
    elsif v_policy.policy_type = 'admin_only' then
      v_required_permission := case
        when p_target_action like 'rule.%'           then 'modifyRules'
        when p_target_action = 'member.remove'       then 'removeMember'
        when p_target_action = 'member.invite'       then 'modifyMembers'
        when p_target_action = 'expense.create'      then 'expenseSubmit'
        when p_target_action = 'capability.enable'   then 'modifyGovernance'
        else 'modifyRules' end;
      if public.has_permission(p_group_id, p_actor_user_id, v_required_permission) then return jsonb_build_object('decision', 'allowed');
      else return jsonb_build_object('decision', 'admin_only'); end if;
    elsif v_policy.policy_type = 'denied' then return jsonb_build_object('decision', 'denied', 'reason', 'policy_denied');
    end if;
  end if;
  if not v_policy_found and p_target_action like 'rule.%' then
    select g.governance, g.created_by into v_governance, v_created_by from public.groups g where g.id = p_group_id;
    v_who := coalesce(v_governance->>'whoCanModifyRules', 'founder');
    if v_who = 'anyMember' then return jsonb_build_object('decision', 'allowed');
    elsif v_who = 'majorityVote' then
      return jsonb_build_object('decision', 'vote_required',
        'quorum_percent', coalesce((v_governance->>'votingQuorumPercent')::int, 50),
        'threshold_percent', coalesce((v_governance->>'votingThresholdPercent')::int, 50),
        'duration_hours', coalesce((v_governance->>'votingDurationHours')::int, 72));
    elsif v_who = 'supermajorityVote' then
      return jsonb_build_object('decision', 'vote_required',
        'quorum_percent', coalesce((v_governance->>'votingQuorumPercent')::int, 50),
        'threshold_percent', 66,
        'duration_hours', coalesce((v_governance->>'votingDurationHours')::int, 72));
    else
      if v_created_by = p_actor_user_id then return jsonb_build_object('decision', 'allowed');
      else return jsonb_build_object('decision', 'denied', 'reason', 'not_founder'); end if;
    end if;
  end if;
  if not v_policy_found and p_target_action = 'member.remove' then
    select g.governance into v_governance from public.groups g where g.id = p_group_id;
    v_who := coalesce(v_governance->>'whoCanRemoveMembers', 'majorityVote');
    if v_who = 'anyMember' then return jsonb_build_object('decision', 'allowed');
    elsif v_who = 'majorityVote' then
      return jsonb_build_object('decision', 'vote_required',
        'quorum_percent', coalesce((v_governance->>'votingQuorumPercent')::int, 50),
        'threshold_percent', coalesce((v_governance->>'votingThresholdPercent')::int, 50),
        'duration_hours', coalesce((v_governance->>'votingDurationHours')::int, 72));
    elsif v_who = 'supermajorityVote' then
      return jsonb_build_object('decision', 'vote_required',
        'quorum_percent', coalesce((v_governance->>'votingQuorumPercent')::int, 50),
        'threshold_percent', 66,
        'duration_hours', coalesce((v_governance->>'votingDurationHours')::int, 72));
    else
      if public.has_permission(p_group_id, p_actor_user_id, 'removeMember') then return jsonb_build_object('decision', 'allowed');
      else return jsonb_build_object('decision', 'admin_only'); end if;
    end if;
  end if;
  if not v_policy_found and p_target_action = 'member.invite' then
    select g.governance into v_governance from public.groups g where g.id = p_group_id;
    v_who := coalesce(v_governance->>'whoCanInviteMembers', 'founder');
    if v_who = 'anyMember' then return jsonb_build_object('decision', 'allowed');
    elsif v_who = 'majorityVote' then
      return jsonb_build_object('decision', 'vote_required',
        'quorum_percent', coalesce((v_governance->>'votingQuorumPercent')::int, 50),
        'threshold_percent', coalesce((v_governance->>'votingThresholdPercent')::int, 50),
        'duration_hours', coalesce((v_governance->>'votingDurationHours')::int, 72));
    elsif v_who = 'supermajorityVote' then
      return jsonb_build_object('decision', 'vote_required',
        'quorum_percent', coalesce((v_governance->>'votingQuorumPercent')::int, 50),
        'threshold_percent', 66,
        'duration_hours', coalesce((v_governance->>'votingDurationHours')::int, 72));
    else
      if public.has_permission(p_group_id, p_actor_user_id, 'modifyMembers') then return jsonb_build_object('decision', 'allowed');
      else return jsonb_build_object('decision', 'admin_only'); end if;
    end if;
  end if;
  return jsonb_build_object('decision', 'denied', 'reason', 'no_policy');
end;
$$;
