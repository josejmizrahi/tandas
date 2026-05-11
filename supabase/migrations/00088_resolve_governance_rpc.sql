-- 00088_resolve_governance_rpc.sql
-- resolve_governance: pure decision function for "can actor perform action?"
--
-- Returns a json with shape:
--   {"decision":"allowed"}
--   {"decision":"vote_required","quorum_percent":50,"threshold_percent":50,"duration_hours":72}
--   {"decision":"admin_only"}
--   {"decision":"denied","reason":"..."}
--
-- Resolution order:
--   1. Look up enabled rows in group_policies for (group_id, target_action).
--      Prefer rows with target_resource_id matching p_target_payload->>'resource_id',
--      then rows with target_resource_type matching p_target_payload->>'resource_type',
--      then group-scoped rows. Within a tier, smaller priority wins.
--   2. If no row matches: fall back to groups.governance.whoCanModifyRules for
--      legacy actions (rule.*) so groups predating mig 00090 backfill still work.
--   3. If still no match: deny.

create or replace function public.resolve_governance(
  p_group_id uuid,
  p_actor_user_id uuid,
  p_target_action text,
  p_target_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_policy public.group_policies%rowtype;
  v_legacy_level text;
  v_governance jsonb;
  v_quorum int;
  v_threshold int;
  v_duration int;
  v_is_member boolean;
  v_is_founder boolean;
  v_has_modify_rules boolean;
begin
  -- Membership check first. Non-members get a hard deny.
  -- (group_members has an `active BOOLEAN` column, not `status text`.)
  select exists(
    select 1 from public.group_members
    where group_id = p_group_id and user_id = p_actor_user_id and active = true
  ) into v_is_member;
  if not v_is_member then
    return jsonb_build_object('decision', 'denied', 'reason', 'not_member');
  end if;

  -- Most-specific policy match.
  select * into v_policy
  from public.group_policies p
  where p.group_id = p_group_id
    and p.target_action = p_target_action
    and p.enabled
    and (
      (p.target_scope = 'resource'
        and p.target_resource_id::text = (p_target_payload->>'resource_id'))
      or
      (p.target_scope = 'resource_type'
        and p.target_resource_type = (p_target_payload->>'resource_type'))
      or
      p.target_scope = 'group'
    )
  order by
    case p.target_scope when 'resource' then 1 when 'resource_type' then 2 else 3 end,
    p.priority asc,
    p.created_at asc
  limit 1;

  if found then
    -- Dispatch on policy_type.
    if v_policy.policy_type = 'direct' then
      return jsonb_build_object('decision', 'allowed');
    elsif v_policy.policy_type = 'vote_required' then
      v_quorum    := coalesce((v_policy.approval_config->>'quorum_percent')::int, 50);
      v_threshold := coalesce((v_policy.approval_config->>'threshold_percent')::int, 50);
      v_duration  := coalesce((v_policy.approval_config->>'duration_hours')::int, 72);
      return jsonb_build_object(
        'decision', 'vote_required',
        'quorum_percent', v_quorum,
        'threshold_percent', v_threshold,
        'duration_hours', v_duration
      );
    elsif v_policy.policy_type = 'admin_only' then
      -- has_permission(group_id, user_id, permission) per current schema.
      v_has_modify_rules := public.has_permission(p_group_id, p_actor_user_id, 'modifyRules');
      if v_has_modify_rules then
        return jsonb_build_object('decision', 'allowed');
      end if;
      return jsonb_build_object('decision', 'admin_only');
    elsif v_policy.policy_type = 'denied' then
      return jsonb_build_object('decision', 'denied', 'reason', 'policy_denied');
    end if;
  end if;

  -- Legacy fallback: rule.* actions read groups.governance.whoCanModifyRules.
  if p_target_action like 'rule.%' then
    select governance into v_governance from public.groups where id = p_group_id;
    v_legacy_level := coalesce(v_governance->>'whoCanModifyRules', 'founder');

    if v_legacy_level = 'anyMember' then
      return jsonb_build_object('decision', 'allowed');
    elsif v_legacy_level = 'majorityVote' then
      return jsonb_build_object(
        'decision', 'vote_required',
        'quorum_percent',    coalesce((v_governance->>'votingQuorumPercent')::int, 50),
        'threshold_percent', coalesce((v_governance->>'votingThresholdPercent')::int, 50),
        'duration_hours',    coalesce((v_governance->>'votingDurationHours')::int, 72)
      );
    elsif v_legacy_level = 'supermajorityVote' then
      return jsonb_build_object(
        'decision', 'vote_required',
        'quorum_percent',    coalesce((v_governance->>'votingQuorumPercent')::int, 50),
        'threshold_percent', 66,
        'duration_hours',    coalesce((v_governance->>'votingDurationHours')::int, 72)
      );
    end if;

    -- founder.
    select (created_by = p_actor_user_id) into v_is_founder
    from public.groups where id = p_group_id;
    if v_is_founder then
      return jsonb_build_object('decision', 'allowed');
    end if;
    return jsonb_build_object('decision', 'denied', 'reason', 'not_founder');
  end if;

  -- Truly unknown action: deny.
  return jsonb_build_object('decision', 'denied', 'reason', 'no_policy');
end;
$$;

revoke execute on function public.resolve_governance(uuid, uuid, text, jsonb) from public, anon;
grant  execute on function public.resolve_governance(uuid, uuid, text, jsonb) to authenticated;

comment on function public.resolve_governance(uuid, uuid, text, jsonb) is
  'Returns the governance decision for an actor attempting target_action. Pure / no side effects.';
