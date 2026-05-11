-- 00090_backfill_legacy_governance.sql
-- One-shot backfill: materialize the legacy whoCanModifyRules policy as
-- explicit group_policies rows for every existing group, for the four V1
-- target_actions (rule.toggle / rule.update_amount / rule.create / rule.delete).
--
-- After this runs, the resolve_governance legacy fallback path becomes
-- effectively dead code for any group that existed at migration time — the
-- table lookup short-circuits before the fallback ever fires. The fallback
-- stays in 00088 as a defensive net for groups that get created in the
-- future without explicit policy rows (e.g. legacy create_group_with_admin
-- callers that don't seed policies yet).
--
-- Mapping (whoCanModifyRules → policy_type):
--   anyMember         → direct
--   majorityVote      → vote_required (50/50/72 from groups.governance jsonb)
--   supermajorityVote → vote_required (50/66/72 — threshold hardcoded)
--   founder / *       → admin_only (founder is the V1 role that grants
--                        Permission.modifyRules per mig 00063)
--
-- Approval-config keys are written as snake_case because they live on
-- group_policies (whose Swift Codable model defines explicit CodingKeys).
-- Source jsonb (groups.governance) is read with camelCase keys because
-- Swift's GovernanceRules struct uses default Codable (property names
-- verbatim). See 00088 header for the same distinction.

do $$
declare
  v_group       public.groups%rowtype;
  v_who         text;
  v_policy_type text;
  v_quorum      int;
  v_threshold   int;
  v_duration    int;
  v_action      text;
  v_actions     text[] := array[
    'rule.toggle',
    'rule.update_amount',
    'rule.create',
    'rule.delete'
  ];
begin
  for v_group in select * from public.groups loop
    v_who := coalesce(v_group.governance->>'whoCanModifyRules', 'founder');

    if v_who = 'anyMember' then
      v_policy_type := 'direct';
    elsif v_who in ('majorityVote', 'supermajorityVote') then
      v_policy_type := 'vote_required';
    else
      -- 'founder' (or unknown): admin_only collapses founder + any future
      -- role that grants Permission.modifyRules.
      v_policy_type := 'admin_only';
    end if;

    v_quorum    := coalesce((v_group.governance->>'votingQuorumPercent')::int, 50);
    v_threshold := case
                     when v_who = 'supermajorityVote' then 66
                     else coalesce((v_group.governance->>'votingThresholdPercent')::int, 50)
                   end;
    v_duration  := coalesce((v_group.governance->>'votingDurationHours')::int, 72);

    foreach v_action in array v_actions loop
      insert into public.group_policies (
        group_id,
        policy_type,
        target_action,
        target_scope,
        approval_config,
        created_by,
        priority
      )
      values (
        v_group.id,
        v_policy_type,
        v_action,
        'group',
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
        v_group.created_by,
        100
      )
      on conflict do nothing;  -- partial unique index on (group, action, scope, …) where enabled
    end loop;
  end loop;
end $$;
