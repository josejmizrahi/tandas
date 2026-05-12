-- 00110_resolve_governance_member_remove.sql
-- Extend governance resolution to handle `member.remove`:
--
--   1. resolve_governance: dispatch the `admin_only` permission check by
--      target_action (rule.* → modifyRules, member.remove → removeMember).
--      Add a legacy fallback for `member.remove` that reads
--      groups.governance.whoCanRemoveMembers (already populated on every
--      group via the recurring_dinner defaults).
--   2. seed_default_group_policies: also write a `member.remove` row,
--      derived from whoCanRemoveMembers via the same mapping the rule.*
--      seeder uses for whoCanModifyRules.
--   3. One-shot top-up: insert the missing `member.remove` row for every
--      pre-existing group. New groups get it via the seed_policies_on_group
--      _insert trigger (mig 00100), unchanged.
--
-- Why a separate migration instead of editing 00088 / 00100 in place:
--   - 00088 and 00100 are already applied live. Replacing them would
--     either require a rollback/re-apply (data risk on group_policies) or
--     duplicate the "create or replace" body across files. Cleaner to
--     layer the extension here and treat each migration as an immutable
--     historical artifact.
--
-- camelCase jsonb keys for governance reads — same pattern as 00088 /
-- 00100; iOS GovernanceRules uses default Swift Codable so the keys are
-- `whoCanRemoveMembers`, `votingQuorumPercent`, etc.

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
  -- 1. Active-member gate.
  select exists(
    select 1
      from public.group_members gm
     where gm.group_id = p_group_id
       and gm.user_id  = p_actor_user_id
       and gm.active   = true
  ) into v_is_member;

  if not v_is_member then
    return jsonb_build_object('decision', 'denied', 'reason', 'not_member');
  end if;

  -- 2. Most-specific matching policy row.
  select p.* into v_policy
    from public.group_policies p
   where p.group_id      = p_group_id
     and p.target_action = p_target_action
     and p.enabled       = true
     and (
           (p.target_scope = 'resource'
              and v_resource_id_text is not null
              and p.target_resource_id is not null
              and p.target_resource_id::text = v_resource_id_text)
        or (p.target_scope = 'resource_type'
              and v_resource_type is not null
              and p.target_resource_type is not null
              and p.target_resource_type = v_resource_type)
        or (p.target_scope = 'group')
         )
   order by case p.target_scope
              when 'resource'      then 1
              when 'resource_type' then 2
              when 'group'         then 3
              else 4
            end asc,
            p.priority asc,
            p.created_at asc
   limit 1;

  if found then
    v_policy_found := true;

    if v_policy.policy_type = 'direct' then
      return jsonb_build_object('decision', 'allowed');

    elsif v_policy.policy_type = 'vote_required' then
      v_quorum    := coalesce((v_policy.approval_config->>'quorum_percent')::int,    50);
      v_threshold := coalesce((v_policy.approval_config->>'threshold_percent')::int, 50);
      v_duration  := coalesce((v_policy.approval_config->>'duration_hours')::int,    72);
      return jsonb_build_object(
        'decision',          'vote_required',
        'quorum_percent',    v_quorum,
        'threshold_percent', v_threshold,
        'duration_hours',    v_duration
      );

    elsif v_policy.policy_type = 'admin_only' then
      -- Dispatch the permission name by target_action. New families
      -- (expense.*, fund.*, etc.) extend this case statement.
      v_required_permission := case
        when p_target_action like 'rule.%'        then 'modifyRules'
        when p_target_action = 'member.remove'    then 'removeMember'
        else 'modifyRules'  -- safe default for unknown actions
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

  -- 3a. Legacy fallback: rule.* reads whoCanModifyRules.
  if not v_policy_found and p_target_action like 'rule.%' then
    select g.governance, g.created_by
      into v_governance, v_created_by
      from public.groups g
     where g.id = p_group_id;

    v_who := coalesce(v_governance->>'whoCanModifyRules', 'founder');

    if v_who = 'anyMember' then
      return jsonb_build_object('decision', 'allowed');

    elsif v_who = 'majorityVote' then
      v_quorum    := coalesce((v_governance->>'votingQuorumPercent')::int,    50);
      v_threshold := coalesce((v_governance->>'votingThresholdPercent')::int, 50);
      v_duration  := coalesce((v_governance->>'votingDurationHours')::int,    72);
      return jsonb_build_object(
        'decision',          'vote_required',
        'quorum_percent',    v_quorum,
        'threshold_percent', v_threshold,
        'duration_hours',    v_duration
      );

    elsif v_who = 'supermajorityVote' then
      v_quorum    := coalesce((v_governance->>'votingQuorumPercent')::int, 50);
      v_threshold := 66;
      v_duration  := coalesce((v_governance->>'votingDurationHours')::int, 72);
      return jsonb_build_object(
        'decision',          'vote_required',
        'quorum_percent',    v_quorum,
        'threshold_percent', v_threshold,
        'duration_hours',    v_duration
      );

    else
      if v_created_by = p_actor_user_id then
        return jsonb_build_object('decision', 'allowed');
      else
        return jsonb_build_object('decision', 'denied', 'reason', 'not_founder');
      end if;
    end if;
  end if;

  -- 3b. Legacy fallback: member.remove reads whoCanRemoveMembers.
  -- Same shape as the rule.* fallback but consults a different jsonb key
  -- and uses Permission.removeMember for the founder/admin path.
  if not v_policy_found and p_target_action = 'member.remove' then
    select g.governance
      into v_governance
      from public.groups g
     where g.id = p_group_id;

    v_who := coalesce(v_governance->>'whoCanRemoveMembers', 'majorityVote');

    if v_who = 'anyMember' then
      return jsonb_build_object('decision', 'allowed');

    elsif v_who = 'majorityVote' then
      v_quorum    := coalesce((v_governance->>'votingQuorumPercent')::int,    50);
      v_threshold := coalesce((v_governance->>'votingThresholdPercent')::int, 50);
      v_duration  := coalesce((v_governance->>'votingDurationHours')::int,    72);
      return jsonb_build_object(
        'decision',          'vote_required',
        'quorum_percent',    v_quorum,
        'threshold_percent', v_threshold,
        'duration_hours',    v_duration
      );

    elsif v_who = 'supermajorityVote' then
      v_quorum    := coalesce((v_governance->>'votingQuorumPercent')::int, 50);
      v_threshold := 66;
      v_duration  := coalesce((v_governance->>'votingDurationHours')::int, 72);
      return jsonb_build_object(
        'decision',          'vote_required',
        'quorum_percent',    v_quorum,
        'threshold_percent', v_threshold,
        'duration_hours',    v_duration
      );

    else
      -- 'founder' or any other unknown value: admin gate via has_permission.
      if public.has_permission(p_group_id, p_actor_user_id, 'removeMember') then
        return jsonb_build_object('decision', 'allowed');
      else
        return jsonb_build_object('decision', 'admin_only');
      end if;
    end if;
  end if;

  return jsonb_build_object('decision', 'denied', 'reason', 'no_policy');
end;
$$;

comment on function public.resolve_governance(uuid, uuid, text, jsonb) is
  'Resolves whether an actor can perform target_action on a group. Returns allowed / vote_required / admin_only / denied. Consults group_policies first (most-specific scope wins), then falls back to groups.governance for rule.* (whoCanModifyRules) and member.remove (whoCanRemoveMembers). admin_only checks dispatch the Permission name by target_action.';

-- =============================================================================
-- Extend seed_default_group_policies to include member.remove
-- =============================================================================

create or replace function public.seed_default_group_policies(
  p_group_id uuid,
  p_governance jsonb,
  p_created_by uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_who                text;
  v_policy_type        text;
  v_quorum             int;
  v_threshold          int;
  v_duration           int;
  v_action             text;
  v_actions            text[] := array[
    'rule.toggle',
    'rule.update_amount',
    'rule.create',
    'rule.delete'
  ];
  v_member_who         text;
  v_member_policy_type text;
  v_member_quorum      int;
  v_member_threshold   int;
  v_member_duration    int;
begin
  -- rule.* family — derived from whoCanModifyRules
  v_who := coalesce(p_governance->>'whoCanModifyRules', 'founder');

  if v_who = 'anyMember' then
    v_policy_type := 'direct';
  elsif v_who in ('majorityVote', 'supermajorityVote') then
    v_policy_type := 'vote_required';
  else
    v_policy_type := 'admin_only';
  end if;

  v_quorum    := coalesce((p_governance->>'votingQuorumPercent')::int, 50);
  v_threshold := case
                   when v_who = 'supermajorityVote' then 66
                   else coalesce((p_governance->>'votingThresholdPercent')::int, 50)
                 end;
  v_duration  := coalesce((p_governance->>'votingDurationHours')::int, 72);

  foreach v_action in array v_actions loop
    insert into public.group_policies (
      group_id, policy_type, target_action, target_scope,
      approval_config, created_by, priority
    )
    values (
      p_group_id, v_policy_type, v_action, 'group',
      case
        when v_policy_type = 'vote_required' then
          jsonb_build_object(
            'quorum_percent',    v_quorum,
            'threshold_percent', v_threshold,
            'duration_hours',    v_duration,
            'eligible_voters',   'group_members'
          )
        else '{}'::jsonb
      end,
      p_created_by, 100
    )
    on conflict do nothing;
  end loop;

  -- member.remove — derived from whoCanRemoveMembers (default majorityVote
  -- per recurring_dinner template; existing groups all have it set).
  v_member_who := coalesce(p_governance->>'whoCanRemoveMembers', 'majorityVote');

  if v_member_who = 'anyMember' then
    v_member_policy_type := 'direct';
  elsif v_member_who in ('majorityVote', 'supermajorityVote') then
    v_member_policy_type := 'vote_required';
  else
    v_member_policy_type := 'admin_only';
  end if;

  v_member_quorum    := coalesce((p_governance->>'votingQuorumPercent')::int, 50);
  v_member_threshold := case
                          when v_member_who = 'supermajorityVote' then 66
                          else coalesce((p_governance->>'votingThresholdPercent')::int, 50)
                        end;
  v_member_duration  := coalesce((p_governance->>'votingDurationHours')::int, 72);

  insert into public.group_policies (
    group_id, policy_type, target_action, target_scope,
    approval_config, created_by, priority
  )
  values (
    p_group_id, v_member_policy_type, 'member.remove', 'group',
    case
      when v_member_policy_type = 'vote_required' then
        jsonb_build_object(
          'quorum_percent',    v_member_quorum,
          'threshold_percent', v_member_threshold,
          'duration_hours',    v_member_duration,
          'eligible_voters',   'group_members'
        )
      else '{}'::jsonb
    end,
    p_created_by, 100
  )
  on conflict do nothing;
end;
$$;

revoke execute on function public.seed_default_group_policies(uuid, jsonb, uuid) from public, anon;

-- =============================================================================
-- One-shot top-up for groups missing the member.remove policy row.
-- =============================================================================

do $$
declare
  v_group public.groups%rowtype;
begin
  for v_group in
    select * from public.groups g
    where not exists (
      select 1 from public.group_policies p
      where p.group_id = g.id
        and p.target_action = 'member.remove'
    )
  loop
    perform public.seed_default_group_policies(
      v_group.id, v_group.governance, v_group.created_by
    );
  end loop;
end $$;
