-- 00092_seed_group_policies_on_create.sql
-- Auto-seed default `group_policies` for every newly created group.
--
-- Backfill 00090 only ran once, so groups created AFTER the migration
-- landed (Test, Familia at time of writing) have no policy rows — the
-- resolve_governance legacy fallback handles them safely, but the iOS
-- UI then can't tell which preset is "active" because nothing is in
-- the table. Fixed two ways:
--
--   1. Trigger on AFTER INSERT on public.groups seeds the same 4
--      rule.* policies the backfill writes, derived from the same
--      whoCanModifyRules → policy_type mapping. Idempotent via the
--      partial unique index ON CONFLICT DO NOTHING.
--   2. Backfill block at the end of this file tops up any pre-existing
--      group that's missing rule.* policies — same mapping.

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
      group_id,
      policy_type,
      target_action,
      target_scope,
      approval_config,
      created_by,
      priority
    )
    values (
      p_group_id,
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
      p_created_by,
      100
    )
    on conflict do nothing;
  end loop;
end;
$$;

revoke execute on function public.seed_default_group_policies(uuid, jsonb, uuid) from public, anon;

comment on function public.seed_default_group_policies(uuid, jsonb, uuid) is
  'Seeds the 4 default rule.* policies for a group from its governance jsonb. Idempotent via the partial unique index on group_policies. Called from the seed_policies_on_group_insert trigger and from the one-shot top-up below.';

-- Trigger
create or replace function public.seed_policies_on_group_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_default_group_policies(NEW.id, NEW.governance, NEW.created_by);
  return NEW;
end;
$$;

drop trigger if exists seed_policies_on_group_insert_trg on public.groups;
create trigger seed_policies_on_group_insert_trg
  after insert on public.groups
  for each row
  execute function public.seed_policies_on_group_insert();

-- One-shot top-up for groups that missed the 00090 backfill.
do $$
declare
  v_group public.groups%rowtype;
begin
  for v_group in
    select * from public.groups g
    where not exists (
      select 1 from public.group_policies p
      where p.group_id = g.id and p.target_action like 'rule.%'
    )
  loop
    perform public.seed_default_group_policies(v_group.id, v_group.governance, v_group.created_by);
  end loop;
end $$;
