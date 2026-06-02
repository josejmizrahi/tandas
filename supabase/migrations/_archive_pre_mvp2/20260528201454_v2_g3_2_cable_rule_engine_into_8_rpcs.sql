-- V2-G3 sub-slice 2: cable evaluate_rules_for_event(_, 'sync') post-commit
-- en las RPCs domain que aún no lo invocaban. Los 3 money RPCs ya estaban
-- cableados, así que el scope real son 4 callsites canónicos:
--   issue_sanction        → sanction.issued
--   set_membership_state  → member.state_changed (cubre leave_group)
--   open_dispute          → dispute.opened     (cubre dispute_sanction)
--   finalize_vote         → decision.finalized
--
-- Patrón uniforme: capturar uuid_id del record_system_event que ya estaba
-- en cada función + invocar evaluator con ese uuid. Los handlers G3.4 ya
-- saben routear; el depth guard + cycle detection del evaluator G3.3
-- contienen recursión (issue_sanction puede ser llamado tanto por el
-- usuario como por el dispatcher — la cadena se corta cuando una regla
-- repite version o cuando depth ≥ 5).
--
-- Heads-up: los event_types sanction.issued, dispute.opened, member.state_changed
-- (cuando dispara desde leave_group) no tienen triggers seeded en el
-- catálogo todavía. El hook se ejecuta pero no matchea reglas — eso es OK
-- (audit-only) hasta que founders publiquen reglas para esos eventos.

CREATE OR REPLACE FUNCTION public.issue_sanction(
  p_group_id uuid,
  p_target_membership_id uuid,
  p_sanction_kind text,
  p_reason text,
  p_amount numeric DEFAULT NULL::numeric,
  p_unit text DEFAULT NULL::text,
  p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_rule_version_id uuid DEFAULT NULL::uuid,
  p_source_event_id uuid DEFAULT NULL::uuid,
  p_client_id text DEFAULT NULL::text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_id uuid; v_obligation uuid; v_actor uuid; v_event_uuid uuid;
begin
  perform public.assert_permission(p_group_id, 'sanctions.create');
  if p_client_id is not null then
    select id into v_id from public.group_sanctions
     where group_id = p_group_id and client_id = p_client_id;
    if v_id is not null then return v_id; end if;
  end if;

  v_actor := (select id from public.group_memberships where group_id = p_group_id and user_id = auth.uid());

  insert into public.group_sanctions (
    group_id, target_membership_id, issued_by_membership_id, rule_version_id,
    source_event_id, sanction_kind, status, amount, unit, reason, ends_at, client_id
  ) values (
    p_group_id, p_target_membership_id, v_actor, p_rule_version_id,
    p_source_event_id, p_sanction_kind, 'active', p_amount, p_unit, p_reason, p_ends_at, p_client_id
  ) returning id into v_id;

  if p_sanction_kind = 'monetary' then
    if p_amount is null or p_amount <= 0 or p_unit is null then
      raise exception 'monetary sanction requires positive amount + unit';
    end if;
    insert into public.group_obligations (
      group_id, owed_by_membership_id, owed_to_kind,
      obligation_kind, amount_original, amount_outstanding, unit, description, metadata
    ) values (
      p_group_id, p_target_membership_id, 'pool',
      'fine', p_amount, p_amount, p_unit, p_reason,
      jsonb_build_object('sanction_id', v_id)
    ) returning id into v_obligation;
    update public.group_sanctions set obligation_id = v_obligation where id = v_id;
  elsif p_sanction_kind = 'suspension' then
    perform public.set_membership_state(p_target_membership_id, 'suspended', p_reason, p_ends_at);
  end if;

  insert into public.group_reputation_events (
    group_id, subject_membership_id, actor_membership_id,
    reputation_type, reason, evidence_entity_kind, evidence_entity_id
  ) values (
    p_group_id, p_target_membership_id, v_actor,
    case when p_rule_version_id is not null then 'rule_violation' else 'commitment_broken' end,
    p_reason, 'sanction', v_id
  );

  select rse.uuid_id into v_event_uuid from public.record_system_event(
    p_group_id, 'sanction.issued', 'sanction', v_id, p_reason,
    jsonb_build_object('kind', p_sanction_kind, 'target', p_target_membership_id)
  ) rse;
  perform public.evaluate_rules_for_event(v_event_uuid, 'sync');

  return v_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_membership_state(
  p_membership_id uuid,
  p_new_state text,
  p_reason text DEFAULT NULL::text,
  p_until timestamp with time zone DEFAULT NULL::timestamp with time zone
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_m public.group_memberships%rowtype;
  v_is_self boolean;
  v_event_uuid uuid;
begin
  select * into v_m from public.group_memberships where id = p_membership_id for update;
  if v_m.id is null then raise exception 'membership not found'; end if;
  v_is_self := (v_m.user_id = auth.uid());

  if p_new_state not in ('active','suspended','left','banned','requested','invited') then
    raise exception 'invalid membership state %', p_new_state;
  end if;

  if p_new_state = 'left' then
    if not (v_is_self or public.has_group_permission(v_m.group_id, 'members.remove')) then
      raise exception 'caller cannot move membership to left';
    end if;
  elsif p_new_state = 'suspended' then
    perform public.assert_permission(v_m.group_id, 'members.suspend');
  elsif p_new_state = 'banned' then
    perform public.assert_permission(v_m.group_id, 'members.remove');
  else
    perform public.assert_permission(v_m.group_id, 'members.update');
  end if;

  update public.group_memberships
     set status = p_new_state,
         suspended_until = case when p_new_state='suspended' then p_until else null end,
         suspended_reason = case when p_new_state='suspended' then p_reason else suspended_reason end,
         left_at = case when p_new_state in ('left','banned') then now() else left_at end,
         left_reason = case when p_new_state in ('left','banned') then p_reason else left_reason end
   where id = p_membership_id;

  insert into public.group_membership_events (group_id, membership_id, actor_user_id, event_type, reason)
  values (v_m.group_id, p_membership_id, auth.uid(),
          case p_new_state
            when 'suspended' then 'suspended'
            when 'active'    then 'reactivated'
            when 'left'      then 'left'
            when 'banned'    then 'banned'
            else 'other'
          end,
          p_reason);

  if p_new_state in ('left','banned','suspended') then
    update public.group_mandates
       set status = 'revoked', revoked_at = now(), revoked_reason = 'member_state_change'
     where representative_membership_id = p_membership_id and status = 'active';
  end if;

  select rse.uuid_id into v_event_uuid from public.record_system_event(
    v_m.group_id, 'member.state_changed', 'membership', p_membership_id,
    'Cambio de estado de membresía',
    jsonb_build_object('to', p_new_state, 'reason', p_reason)
  ) rse;
  perform public.evaluate_rules_for_event(v_event_uuid, 'sync');
end;
$function$;

CREATE OR REPLACE FUNCTION public.open_dispute(
  p_group_id uuid,
  p_subject_kind text,
  p_subject_id uuid,
  p_title text,
  p_description text DEFAULT NULL::text,
  p_respondent_membership_id uuid DEFAULT NULL::uuid
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_id uuid; v_opener uuid; v_event_uuid uuid;
begin
  perform public.assert_permission(p_group_id, 'disputes.open');
  v_opener := public.assert_member_of_group(p_group_id);

  insert into public.group_disputes (
    group_id, opened_by_membership_id, respondent_membership_id,
    subject_kind, subject_id, title, description, status
  ) values (
    p_group_id, v_opener, p_respondent_membership_id,
    p_subject_kind, p_subject_id, p_title, p_description, 'open'
  ) returning id into v_id;

  insert into public.group_dispute_events (dispute_id, actor_membership_id, event_type, body)
  values (v_id, v_opener, 'comment', p_description);

  select rse.uuid_id into v_event_uuid from public.record_system_event(
    p_group_id, 'dispute.opened', 'dispute', v_id, p_title,
    jsonb_build_object('subject_kind', p_subject_kind, 'subject_id', p_subject_id)
  ) rse;
  perform public.evaluate_rules_for_event(v_event_uuid, 'sync');

  return v_id;
end;
$function$;

-- finalize_vote: el único caso donde el body es grande; preservo todo
-- excepto el patch al PERFORM record_system_event final (que es el que
-- emite el evento canónico 'decision.finalized'). Los record_system_event
-- intermedios (rule.archived/rule.activated/money.pool_charge_created en
-- los outcome handlers) no se cablean porque son bookkeeping side effects
-- de la decisión, no eventos por los que un founder querría reglas.
CREATE OR REPLACE FUNCTION public.finalize_vote(p_decision_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
      if v_target_state IN ('active','suspended','expelled','inactive') then
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
