-- V3-D.18 FASE D (cont) — finalize_vote ya no hace side effects inline.
-- Decide outcome + escribe status='passed'/'rejected'. Si execution_mode='auto'
-- y la decisión pasó, llama execute_decision (que sí gates por permission).
-- Si manual / secondary_approval, queda en 'passed' esperando call explícita.
-- decision.finalized event sigue saliendo + engine re-evalúa.

CREATE OR REPLACE FUNCTION public.finalize_vote(p_decision_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_d                public.group_decisions%rowtype;
  v_yes              numeric := 0;
  v_no               numeric := 0;
  v_abstain          numeric := 0;
  v_block            numeric := 0;
  v_total            numeric;
  v_outcome          text;
  v_quorum_total     numeric;
  v_threshold        numeric;
  v_option_tally     jsonb := '{}'::jsonb;
  v_winner_option    uuid;
  v_winner_points    numeric;
  v_runner_points    numeric;
  v_voter_count      bigint;
  v_result           jsonb;
  v_event_uuid       uuid;
  v_should_auto      boolean;
begin
  select * into v_d from public.group_decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found'; end if;
  if v_d.status <> 'open' then return v_d.status; end if;

  if v_d.method = 'ranked_choice' then
    with per_option as (
      select option_id, sum(weight) as points
        from public.group_votes v
        join (
          select voter_membership_id, max(cast_at) as latest_cast
            from public.group_votes
           where decision_id = p_decision_id
           group by voter_membership_id
        ) lb using (voter_membership_id)
       where v.decision_id = p_decision_id
         and v.cast_at = lb.latest_cast
         and option_id is not null
       group by option_id
    )
    select coalesce(jsonb_object_agg(option_id, points), '{}'::jsonb) into v_option_tally
      from per_option;
    select count(distinct voter_membership_id) into v_voter_count
      from public.group_votes where decision_id = p_decision_id;
    select option_id, points into v_winner_option, v_winner_points
      from (select (kv).key::uuid as option_id, (kv).value::text::numeric as points
              from (select jsonb_each(v_option_tally) as kv) e) r
     order by points desc nulls last limit 1;
    select points into v_runner_points
      from (select (kv).value::text::numeric as points
              from (select jsonb_each(v_option_tally) as kv) e) r
     where points is not null and (v_winner_option is null or points <> v_winner_points)
     order by points desc limit 1;
    if v_d.quorum_pct is not null then
      select count(*) into v_quorum_total from public.group_memberships
       where group_id = v_d.group_id and status = 'active';
      if v_quorum_total = 0 or (v_voter_count * 100.0 / v_quorum_total) < v_d.quorum_pct then
        v_outcome := 'no_quorum';
      end if;
    end if;
    if v_outcome is null then
      if v_winner_option is null or v_winner_points is null or v_winner_points <= 0 then v_outcome := 'rejected';
      elsif v_runner_points is not null and v_runner_points = v_winner_points then v_outcome := 'rejected';
      else v_outcome := 'passed'; end if;
    end if;
    v_result := jsonb_build_object('method','ranked_choice','option_tally',v_option_tally,
                                    'winner_option',v_winner_option,'winner_points',v_winner_points,
                                    'voter_count',v_voter_count,'outcome',v_outcome);

  elsif v_d.method = 'weighted' then
    with current as (
      select distinct on (voter_membership_id) *
        from public.group_votes where decision_id = p_decision_id
       order by voter_membership_id, seq desc
    ), per_option as (
      select option_id, sum(weight) as points
        from current where option_id is not null group by option_id
    )
    select coalesce(jsonb_object_agg(option_id, points), '{}'::jsonb) into v_option_tally from per_option;
    select count(*) into v_voter_count
      from (select distinct on (voter_membership_id) *
              from public.group_votes where decision_id = p_decision_id
             order by voter_membership_id, seq desc) cur;
    select option_id, points into v_winner_option, v_winner_points
      from (select (kv).key::uuid as option_id, (kv).value::text::numeric as points
              from (select jsonb_each(v_option_tally) as kv) e) r
     order by points desc nulls last limit 1;
    select points into v_runner_points
      from (select (kv).value::text::numeric as points
              from (select jsonb_each(v_option_tally) as kv) e) r
     where points is not null and (v_winner_option is null or points <> v_winner_points)
     order by points desc limit 1;
    if v_d.quorum_pct is not null then
      select count(*) into v_quorum_total from public.group_memberships
       where group_id = v_d.group_id and status = 'active';
      if v_quorum_total = 0 or (v_voter_count * 100.0 / v_quorum_total) < v_d.quorum_pct then
        v_outcome := 'no_quorum';
      end if;
    end if;
    if v_outcome is null then
      if v_winner_option is null or v_winner_points is null or v_winner_points <= 0 then v_outcome := 'rejected';
      elsif v_runner_points is not null and v_runner_points = v_winner_points then v_outcome := 'rejected';
      else v_outcome := 'passed'; end if;
    end if;
    v_result := jsonb_build_object('method','weighted','option_tally',v_option_tally,
                                    'winner_option',v_winner_option,'winner_points',v_winner_points,
                                    'voter_count',v_voter_count,'outcome',v_outcome);

  else
    with current as (
      select distinct on (voter_membership_id) *
        from public.group_votes where decision_id = p_decision_id
       order by voter_membership_id, seq desc
    )
    select coalesce(sum(weight) filter (where vote_value = 'yes'), 0),
           coalesce(sum(weight) filter (where vote_value = 'no'), 0),
           coalesce(sum(weight) filter (where vote_value = 'abstain'), 0),
           coalesce(sum(weight) filter (where vote_value = 'block'), 0)
      into v_yes, v_no, v_abstain, v_block from current;
    v_total := v_yes + v_no + v_abstain + v_block;
    if v_d.quorum_pct is not null then
      select count(*) into v_quorum_total from public.group_memberships
       where group_id = v_d.group_id and status = 'active';
      if v_quorum_total = 0 or (v_total * 100.0 / v_quorum_total) < v_d.quorum_pct then
        v_outcome := 'no_quorum';
      end if;
    end if;
    v_threshold := coalesce(v_d.threshold_pct,
                            case v_d.method when 'consensus' then 100
                                            when 'supermajority' then 66.66
                                            when 'consent' then 100
                                            else 50.01 end);
    if v_outcome is null then
      if v_d.method = 'consent' and v_block > 0 then v_outcome := 'rejected';
      elsif (v_yes + v_no) > 0 and (v_yes * 100.0 / (v_yes + v_no)) >= v_threshold then v_outcome := 'passed';
      else v_outcome := 'rejected'; end if;
    end if;
    v_result := jsonb_build_object('yes',v_yes,'no',v_no,'abstain',v_abstain,'block',v_block,'outcome',v_outcome);
  end if;

  -- D.18: finalize_vote ONLY decides outcome + writes passed/rejected.
  -- No more inline side effects.
  update public.group_decisions
     set status     = case when v_outcome = 'passed' then 'passed' else 'rejected' end,
         decided_at = now(),
         result     = v_result
   where id = p_decision_id;

  -- decision.finalized event (preserved shape, minus pool_charge legacy hint)
  select rse.uuid_id into v_event_uuid from public.record_system_event(
    v_d.group_id, 'decision.finalized', 'decision', p_decision_id, v_outcome,
    case when v_d.method in ('weighted','ranked_choice') then
      jsonb_build_object(
        'method',         v_d.method,
        'winner_option',  v_winner_option,
        'winner_points',  v_winner_points,
        'voter_count',    v_voter_count,
        'reference_kind', v_d.reference_kind,
        'execution_mode', v_d.execution_mode
      )
    else
      jsonb_build_object(
        'yes', v_yes, 'no', v_no, 'abstain', v_abstain, 'block', v_block,
        'reference_kind', v_d.reference_kind,
        'target_state',   v_d.metadata->>'target_state',
        'rule_action',    v_d.metadata->>'action',
        'execution_mode', v_d.execution_mode
      )
    end
  ) rse;
  perform public.evaluate_rules_for_event(v_event_uuid, 'sync');

  -- D.18: auto-execute only when template says so. Manual / secondary_approval
  -- stay in 'passed' waiting for an explicit execute_decision call.
  v_should_auto := (v_outcome = 'passed' AND COALESCE(v_d.execution_mode, 'auto') = 'auto');
  if v_should_auto then
    -- execute_decision asserts decisions.execute. finalize_vote already
    -- requires decisions.resolve at the caller layer; for autos, founders
    -- typically hold both perms. If they don't, the inner assert raises and
    -- the auto-execution is skipped — the decision still reads as 'passed'.
    begin
      perform public.execute_decision(p_decision_id);
    exception when others then
      -- swallow to keep finalize result deterministic; engine + UI will
      -- surface the gap (status='passed' but executed_at IS NULL).
      null;
    end;
  end if;

  return v_outcome;
end;
$function$;

COMMENT ON FUNCTION public.finalize_vote(uuid) IS
  'V3-D.18 — pure evaluator. Decides outcome, writes passed/rejected, no side effects unless execution_mode=auto (then calls execute_decision).';
