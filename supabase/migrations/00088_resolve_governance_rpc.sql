-- 00088_resolve_governance_rpc.sql
-- resolve_governance: central decision RPC for Group Governance (Phase 1).
--
-- Given (group_id, actor, action, payload), returns one of five jsonb
-- decisions: allowed | vote_required | admin_only | denied (with reason).
--
-- Resolution order:
--   1. Active-member gate. Non-members get denied/not_member.
--   2. Most-specific matching row in public.group_policies (introduced
--      mig 00087). Specificity: resource (resource_id match) >
--      resource_type (resource_type match) > group. Within tier, smaller
--      `priority` wins, ties broken by `created_at asc`. Only enabled rows.
--   3. If no policy row matched AND action like 'rule.%', legacy fallback
--      reads public.groups.governance jsonb (whoCanModifyRules + vote knobs)
--      to preserve pre-policies behavior.
--   4. Otherwise denied/no_policy.
--
-- Project conventions adopted (verified, deviations from plan doc):
--   * public.group_members uses boolean `active` (mig 00001), not
--     `status='active'`. We filter `active = true`.
--   * public.has_permission(group_id, user_id, permission) takes three
--     args (mig 00063). The plan suggested two args — wrong.
--   * No new helpers introduced; SECURITY DEFINER + locked search_path
--     mirrors mig 00079 / 00086.

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
  v_is_member        boolean;
  v_policy           public.group_policies%rowtype;
  v_policy_found     boolean := false;
  v_quorum           int;
  v_threshold        int;
  v_duration         int;
  v_governance       jsonb;
  v_who              text;
  v_created_by       uuid;
  v_resource_id_text text := p_target_payload->>'resource_id';
  v_resource_type    text := p_target_payload->>'resource_type';
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
  -- Specificity ordering encoded in `tier`: 1 (resource) > 2 (resource_type) > 3 (group).
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
      if public.has_permission(p_group_id, p_actor_user_id, 'modifyRules') then
        return jsonb_build_object('decision', 'allowed');
      else
        return jsonb_build_object('decision', 'admin_only');
      end if;

    elsif v_policy.policy_type = 'denied' then
      return jsonb_build_object('decision', 'denied', 'reason', 'policy_denied');
    end if;
  end if;

  -- 3. Legacy fallback for rule.* actions when no policy row matched.
  if not v_policy_found and p_target_action like 'rule.%' then
    select g.governance, g.created_by
      into v_governance, v_created_by
      from public.groups g
     where g.id = p_group_id;

    v_who := coalesce(v_governance->>'whoCanModifyRules', 'founder');

    if v_who = 'anyMember' then
      return jsonb_build_object('decision', 'allowed');

    elsif v_who = 'majorityVote' then
      v_quorum    := coalesce((v_governance->>'quorum_percent')::int,    50);
      v_threshold := coalesce((v_governance->>'threshold_percent')::int, 50);
      v_duration  := coalesce((v_governance->>'duration_hours')::int,    72);
      return jsonb_build_object(
        'decision',          'vote_required',
        'quorum_percent',    v_quorum,
        'threshold_percent', v_threshold,
        'duration_hours',    v_duration
      );

    elsif v_who = 'supermajorityVote' then
      v_quorum    := coalesce((v_governance->>'quorum_percent')::int, 50);
      v_threshold := 66;
      v_duration  := coalesce((v_governance->>'duration_hours')::int, 72);
      return jsonb_build_object(
        'decision',          'vote_required',
        'quorum_percent',    v_quorum,
        'threshold_percent', v_threshold,
        'duration_hours',    v_duration
      );

    else
      -- 'founder' or anything else: only the group creator passes.
      if v_created_by = p_actor_user_id then
        return jsonb_build_object('decision', 'allowed');
      else
        return jsonb_build_object('decision', 'denied', 'reason', 'not_founder');
      end if;
    end if;
  end if;

  -- 4. Unmatched action with no fallback.
  return jsonb_build_object('decision', 'denied', 'reason', 'no_policy');
end;
$$;

comment on function public.resolve_governance(uuid, uuid, text, jsonb) is
  'Resolves whether an actor can perform target_action on a group, returning allowed / vote_required / admin_only / denied. Consults group_policies (most-specific wins) and falls back to groups.governance for rule.* actions.';

revoke execute on function public.resolve_governance(uuid, uuid, text, jsonb) from public, anon;
grant  execute on function public.resolve_governance(uuid, uuid, text, jsonb) to authenticated;
