-- 00114_resolve_governance_member_invite.sql
-- Extend governance to handle `member.invite`:
--
--   1. resolve_governance: admin_only dispatches to
--      Permission.modifyMembers for member.invite. Legacy fallback
--      reads governance.whoCanInviteMembers (default 'founder' per
--      recurring_dinner template) and maps it the same way the
--      member.remove fallback maps whoCanRemoveMembers.
--   2. seed_default_group_policies: write a member.invite row with
--      policy_type derived from whoCanInviteMembers.
--   3. One-shot top-up: every existing group gets the row.
--
-- Mapping:
--   anyMember         → direct           (any member can share the code)
--   majorityVote      → vote_required    (50/50/72)
--   supermajorityVote → vote_required    (50/66/72)
--   founder / other   → admin_only       (Permission.modifyMembers)
--
-- The current iOS flow surfaces invite-sharing via a header icon on
-- Home (the person.badge.plus). MainTabView gates that icon on the
-- resolver's decision — direct + admin_only with modifyMembers
-- shows it; admin_only without permission + vote_required + denied
-- hides it. Vote-required has no apply path for invites in V1
-- ("the group votes whether you can share the invite code" doesn't
-- really make sense semantically, so it collapses to hidden for
-- the actor) — left as data in case V2 reuses the row shape for a
-- different invite flow.

create or replace function public.resolve_governance(
  p_group_id        uuid,
  p_actor_user_id   uuid,
  p_target_action   text,
  p_target_payload  jsonb default '{}'::jsonb
) returns jsonb
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
  select exists(
    select 1 from public.group_members gm
     where gm.group_id = p_group_id and gm.user_id = p_actor_user_id and gm.active = true
  ) into v_is_member;
  if not v_is_member then
    return jsonb_build_object('decision', 'denied', 'reason', 'not_member');
  end if;

  select p.* into v_policy
    from public.group_policies p
   where p.group_id = p_group_id and p.target_action = p_target_action and p.enabled = true
     and ((p.target_scope = 'resource' and v_resource_id_text is not null and p.target_resource_id is not null and p.target_resource_id::text = v_resource_id_text)
       or (p.target_scope = 'resource_type' and v_resource_type is not null and p.target_resource_type is not null and p.target_resource_type = v_resource_type)
       or (p.target_scope = 'group'))
   order by case p.target_scope when 'resource' then 1 when 'resource_type' then 2 when 'group' then 3 else 4 end asc,
            p.priority asc, p.created_at asc
   limit 1;

  if found then
    v_policy_found := true;
    if v_policy.policy_type = 'direct' then
      return jsonb_build_object('decision', 'allowed');
    elsif v_policy.policy_type = 'vote_required' then
      v_quorum    := coalesce((v_policy.approval_config->>'quorum_percent')::int, 50);
      v_threshold := coalesce((v_policy.approval_config->>'threshold_percent')::int, 50);
      v_duration  := coalesce((v_policy.approval_config->>'duration_hours')::int, 72);
      return jsonb_build_object('decision', 'vote_required',
        'quorum_percent', v_quorum, 'threshold_percent', v_threshold, 'duration_hours', v_duration);
    elsif v_policy.policy_type = 'admin_only' then
      v_required_permission := case
        when p_target_action like 'rule.%'           then 'modifyRules'
        when p_target_action = 'member.remove'       then 'removeMember'
        when p_target_action = 'member.invite'       then 'modifyMembers'
        when p_target_action = 'expense.create'      then 'expenseSubmit'
        when p_target_action = 'capability.enable'   then 'modifyGovernance'
        else 'modifyRules'
      end;
      if public.has_permission(p_group_id, p_actor_user_id, v_required_permission) then
        return jsonb_build_object('decision', 'allowed');
      else
        return jsonb_build_object('decision', 'admin_only');
      end if;
    elsif v_policy.policy_type = 'denied' then
      return jsonb_build_object('decision', 'denied', 'reason', 'policy_denied');
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

-- =============================================================================
-- Extend seed_default_group_policies with member.invite
-- =============================================================================

create or replace function public.seed_default_group_policies(
  p_group_id uuid, p_governance jsonb, p_created_by uuid
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_who text; v_policy_type text;
  v_quorum int; v_threshold int; v_duration int;
  v_action text;
  v_actions text[] := array['rule.toggle','rule.update_amount','rule.create','rule.delete'];
  v_member_who text; v_member_policy_type text;
  v_member_quorum int; v_member_threshold int; v_member_duration int;
  v_invite_who text; v_invite_policy_type text;
  v_invite_quorum int; v_invite_threshold int; v_invite_duration int;
begin
  -- rule.* family
  v_who := coalesce(p_governance->>'whoCanModifyRules', 'founder');
  if v_who = 'anyMember' then v_policy_type := 'direct';
  elsif v_who in ('majorityVote','supermajorityVote') then v_policy_type := 'vote_required';
  else v_policy_type := 'admin_only'; end if;
  v_quorum := coalesce((p_governance->>'votingQuorumPercent')::int, 50);
  v_threshold := case when v_who = 'supermajorityVote' then 66
                      else coalesce((p_governance->>'votingThresholdPercent')::int, 50) end;
  v_duration := coalesce((p_governance->>'votingDurationHours')::int, 72);
  foreach v_action in array v_actions loop
    insert into public.group_policies (group_id, policy_type, target_action, target_scope, approval_config, created_by, priority)
    values (p_group_id, v_policy_type, v_action, 'group',
      case when v_policy_type = 'vote_required' then
        jsonb_build_object('quorum_percent', v_quorum, 'threshold_percent', v_threshold, 'duration_hours', v_duration, 'eligible_voters', 'group_members')
      else '{}'::jsonb end,
      p_created_by, 100)
    on conflict do nothing;
  end loop;

  -- member.remove
  v_member_who := coalesce(p_governance->>'whoCanRemoveMembers', 'majorityVote');
  if v_member_who = 'anyMember' then v_member_policy_type := 'direct';
  elsif v_member_who in ('majorityVote','supermajorityVote') then v_member_policy_type := 'vote_required';
  else v_member_policy_type := 'admin_only'; end if;
  v_member_quorum := coalesce((p_governance->>'votingQuorumPercent')::int, 50);
  v_member_threshold := case when v_member_who = 'supermajorityVote' then 66
                              else coalesce((p_governance->>'votingThresholdPercent')::int, 50) end;
  v_member_duration := coalesce((p_governance->>'votingDurationHours')::int, 72);
  insert into public.group_policies (group_id, policy_type, target_action, target_scope, approval_config, created_by, priority)
  values (p_group_id, v_member_policy_type, 'member.remove', 'group',
    case when v_member_policy_type = 'vote_required' then
      jsonb_build_object('quorum_percent', v_member_quorum, 'threshold_percent', v_member_threshold, 'duration_hours', v_member_duration, 'eligible_voters', 'group_members')
    else '{}'::jsonb end,
    p_created_by, 100)
  on conflict do nothing;

  -- member.invite — from whoCanInviteMembers (default 'founder' per
  -- recurring_dinner; existing groups all have it set).
  v_invite_who := coalesce(p_governance->>'whoCanInviteMembers', 'founder');
  if v_invite_who = 'anyMember' then v_invite_policy_type := 'direct';
  elsif v_invite_who in ('majorityVote','supermajorityVote') then v_invite_policy_type := 'vote_required';
  else v_invite_policy_type := 'admin_only'; end if;
  v_invite_quorum := coalesce((p_governance->>'votingQuorumPercent')::int, 50);
  v_invite_threshold := case when v_invite_who = 'supermajorityVote' then 66
                              else coalesce((p_governance->>'votingThresholdPercent')::int, 50) end;
  v_invite_duration := coalesce((p_governance->>'votingDurationHours')::int, 72);
  insert into public.group_policies (group_id, policy_type, target_action, target_scope, approval_config, created_by, priority)
  values (p_group_id, v_invite_policy_type, 'member.invite', 'group',
    case when v_invite_policy_type = 'vote_required' then
      jsonb_build_object('quorum_percent', v_invite_quorum, 'threshold_percent', v_invite_threshold, 'duration_hours', v_invite_duration, 'eligible_voters', 'group_members')
    else '{}'::jsonb end,
    p_created_by, 100)
  on conflict do nothing;

  -- expense.create
  insert into public.group_policies (group_id, policy_type, target_action, target_scope, approval_config, created_by, priority)
  values (p_group_id, 'direct', 'expense.create', 'group', '{}'::jsonb, p_created_by, 100)
  on conflict do nothing;

  -- capability.enable
  insert into public.group_policies (group_id, policy_type, target_action, target_scope, approval_config, created_by, priority)
  values (p_group_id, 'admin_only', 'capability.enable', 'group', '{}'::jsonb, p_created_by, 100)
  on conflict do nothing;
end;
$$;

revoke execute on function public.seed_default_group_policies(uuid, jsonb, uuid) from public, anon;

do $$
declare v_group public.groups%rowtype;
begin
  for v_group in
    select * from public.groups g
    where not exists (
      select 1 from public.group_policies p
      where p.group_id = g.id and p.target_action = 'member.invite'
    )
  loop
    perform public.seed_default_group_policies(v_group.id, v_group.governance, v_group.created_by);
  end loop;
end $$;
