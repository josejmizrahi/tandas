-- PARTE 12 hot-fix #4: finalize_vote membership handler validaba target_state
-- IN ('active','suspended','expelled','inactive') pero set_membership_state
-- whitelist real es active|suspended|left|banned|requested|invited.
--
-- Resultado: cualquier vote sobre membership state con target_state='expelled'
-- o 'inactive' (que iOS sigue mandando como legacy) pasaba la validación local
-- pero raise dentro de set_membership_state → finalize_vote rollback completo,
-- decisión queda stuck. Votar expulsión = roto silently.
--
-- Hot-fix mechanical: agregar CASE mapping antes de la validación IN:
--   - 'expelled' → 'banned' (canonical kick-out).
--   - 'inactive' → 'left' (más cercano semántico).
-- Y alinear el IN list al whitelist real de set_membership_state.

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
  v_target_state     text;
  v_rule_action      text;
  v_rule             public.group_rules%rowtype;
  v_pool_amount      numeric;
  v_pool_unit        text;
  v_pool_kind        text;
  v_pool_reason      text;
  v_pool_obligation  uuid;
  v_option_tally     jsonb := '{}'::jsonb;
  v_winner_option    uuid;
  v_winner_points    numeric;
  v_runner_points    numeric;
  v_voter_count      bigint;
  v_result           jsonb;
  v_event_uuid       uuid;
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

  update public.group_decisions
     set status = case when v_outcome = 'passed' then 'passed' else 'rejected' end,
         decided_at = now(), result = v_result
   where id = p_decision_id;

  if v_outcome = 'passed' then
    if v_d.reference_kind = 'sanction' and v_d.reference_id is not null then
      perform public.update_sanction_status(v_d.reference_id, 'reversed', 'vote_pass');
    elsif v_d.reference_kind = 'dispute' and v_d.reference_id is not null then
      update public.group_disputes set status = 'resolved', resolved_at = now() where id = v_d.reference_id;
    elsif v_d.reference_kind = 'mandate_grant' and v_d.reference_id is not null then
      update public.group_mandates set source_decision_id = p_decision_id where id = v_d.reference_id;
    elsif v_d.reference_kind = 'mandate_revoke' and v_d.reference_id is not null then
      perform public.revoke_mandate(v_d.reference_id, 'vote_pass');
    elsif v_d.reference_kind = 'dissolution' and v_d.reference_id is not null then
      perform public.approve_dissolution(v_d.reference_id);
    elsif v_d.reference_kind = 'membership' and v_d.reference_id is not null then
      v_target_state := NULLIF(v_d.metadata->>'target_state', '');
      -- PARTE 12 hot-fix: mapping a whitelist real de set_membership_state.
      v_target_state := CASE v_target_state
        WHEN 'expelled' THEN 'banned'
        WHEN 'inactive' THEN 'left'
        ELSE v_target_state
      END;
      if v_target_state IN ('active','suspended','left','banned') then
        perform public.set_membership_state(v_d.reference_id, v_target_state, 'vote_pass');
      end if;
    elsif v_d.reference_kind = 'rule' and v_d.reference_id is not null then
      v_rule_action := NULLIF(v_d.metadata->>'action', '');
      select * into v_rule from public.group_rules where id = v_d.reference_id for update;
      if v_rule.id is not null then
        if v_rule_action = 'archive' and v_rule.status <> 'archived' then
          update public.group_rules set status = 'archived', updated_at = now() where id = v_rule.id;
          if v_rule.current_version_id is not null then
            update public.group_rule_versions set effective_until = now()
             where id = v_rule.current_version_id and effective_until is null;
          end if;
          perform public.record_system_event(
            v_rule.group_id, 'rule.archived', 'rule', v_rule.id,
            'Regla archivada por decisión',
            jsonb_build_object('source', 'decision', 'decision_id', p_decision_id)
          );
        elsif v_rule_action = 'activate' and v_rule.status IN ('archived','draft') then
          update public.group_rules set status = 'active', updated_at = now() where id = v_rule.id;
          perform public.record_system_event(
            v_rule.group_id, 'rule.activated', 'rule', v_rule.id,
            'Regla reactivada por decisión',
            jsonb_build_object('source', 'decision', 'decision_id', p_decision_id)
          );
        end if;
      end if;
    elsif v_d.reference_kind = 'pool_charge' and v_d.reference_id is not null then
      v_pool_amount := NULLIF(v_d.metadata->>'amount', '')::numeric;
      v_pool_unit   := COALESCE(NULLIF(v_d.metadata->>'unit', ''), 'MXN');
      v_pool_kind   := NULLIF(v_d.metadata->>'charge_kind', '');
      v_pool_reason := NULLIF(v_d.metadata->>'reason', '');
      if v_pool_amount is not null and v_pool_amount > 0
         and v_pool_kind IN ('quota','buy_in','fee') then
        insert into public.group_obligations (
          group_id, owed_by_membership_id, owed_to_kind,
          obligation_kind, amount_original, amount_outstanding, unit, description, metadata
        ) values (
          v_d.group_id, v_d.reference_id, 'pool',
          'pool_charge', v_pool_amount, v_pool_amount, v_pool_unit,
          COALESCE(v_pool_reason, v_d.title),
          jsonb_build_object('charge_kind', v_pool_kind, 'source', 'decision', 'decision_id', p_decision_id)
        ) returning id into v_pool_obligation;
        perform public.record_system_event(
          v_d.group_id, 'money.pool_charge_created', 'obligation', v_pool_obligation,
          COALESCE(v_pool_reason, v_d.title),
          jsonb_build_object('amount', v_pool_amount, 'unit', v_pool_unit, 'kind', v_pool_kind,
                             'target', v_d.reference_id, 'source', 'decision', 'decision_id', p_decision_id)
        );
      end if;
    end if;
  end if;

  select rse.uuid_id into v_event_uuid from public.record_system_event(
    v_d.group_id, 'decision.finalized', 'decision', p_decision_id, v_outcome,
    case when v_d.method in ('weighted','ranked_choice') then
      jsonb_build_object(
        'method',         v_d.method,
        'winner_option',  v_winner_option,
        'winner_points',  v_winner_points,
        'voter_count',    v_voter_count,
        'reference_kind', v_d.reference_kind
      )
    else
      jsonb_build_object(
        'yes', v_yes, 'no', v_no, 'abstain', v_abstain, 'block', v_block,
        'reference_kind', v_d.reference_kind,
        'target_state', v_d.metadata->>'target_state',
        'rule_action',  v_d.metadata->>'action',
        'pool_charge_amount', v_d.metadata->>'amount',
        'pool_charge_kind',   v_d.metadata->>'charge_kind'
      )
    end
  ) rse;
  perform public.evaluate_rules_for_event(v_event_uuid, 'sync');

  return v_outcome;
end;
$function$;

REVOKE ALL ON FUNCTION public.finalize_vote(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finalize_vote(uuid) TO authenticated, service_role;
