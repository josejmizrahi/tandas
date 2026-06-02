-- V2-G9 — Vote weights + ranked-choice (Borda) UX
--
-- Adds:
--   * cast_vote.p_weight (numeric, only honored when method='weighted',
--     capped by group_decisions.metadata.weight_strategy.config.max_weight
--     when present).
--   * cast_ranked_vote(p_decision_id, p_rankings jsonb, p_reason text) —
--     inserts one ballot per ranked option with `weight = (N - rank)`
--     Borda points. All rows in a single call share `cast_at = now()`
--     which finalize_vote uses as a batch identifier.
--   * finalize_vote now branches on method:
--     - 'weighted'      → per-option weighted tally, winner = highest sum
--     - 'ranked_choice' → per-option Borda tally on the latest ballot
--                         batch per voter, winner = highest points
--     - everything else → unchanged yes/no/abstain/block path

-- 1. cast_vote with optional p_weight ----------------------------------------
CREATE OR REPLACE FUNCTION public.cast_vote(
  p_decision_id uuid,
  p_option_id   uuid    DEFAULT NULL,
  p_vote_value  text    DEFAULT NULL,
  p_reason      text    DEFAULT NULL,
  p_weight      numeric DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_d            public.group_decisions%rowtype;
  v_voter        uuid;
  v_weight       numeric;
  v_max_weight   numeric;
  v_strategy     jsonb;
  v_id           uuid;
  v_event        uuid;
begin
  select * into v_d from public.group_decisions where id = p_decision_id;
  if v_d.id is null then raise exception 'decision not found'; end if;
  if v_d.status <> 'open' then raise exception 'decision is not open'; end if;
  if v_d.closes_at is not null and v_d.closes_at < now() then
    raise exception 'voting window closed';
  end if;

  v_voter := (select gm.id from public.group_memberships gm
              where gm.group_id = v_d.group_id and gm.user_id = auth.uid() and gm.status = 'active');
  if v_voter is null then
    raise exception 'caller is not an active member of group %', v_d.group_id;
  end if;

  -- V2-G9: p_weight honored only when method='weighted'. Everything
  -- else keeps the canonical weight=1 path so tally math stays simple.
  if v_d.method = 'weighted' then
    if p_weight is null or p_weight <= 0 then
      raise exception 'weighted votes require p_weight > 0' using errcode = '22023';
    end if;
    v_strategy := v_d.metadata->'weight_strategy';
    if v_strategy is not null and v_strategy ? 'config' then
      v_max_weight := NULLIF(v_strategy->'config'->>'max_weight', '')::numeric;
      if v_max_weight is not null and p_weight > v_max_weight then
        raise exception 'p_weight % exceeds max_weight %', p_weight, v_max_weight
          using errcode = '22023';
      end if;
    end if;
    v_weight := p_weight;
  else
    v_weight := 1;
  end if;

  insert into public.group_votes (
    group_id, decision_id, voter_membership_id, option_id, vote_value, weight, reason
  ) values (
    v_d.group_id, p_decision_id, v_voter, p_option_id, p_vote_value, v_weight, p_reason
  ) returning id into v_id;

  -- Silent canonical write (no vote value in the event payload).
  select rse.uuid_id into v_event from public.record_system_event(
    v_d.group_id, 'decision.vote_cast', 'decision', p_decision_id, null,
    jsonb_build_object('voter_membership_id', v_voter, 'authority_path', 'self_party')
  ) rse;
  perform public.evaluate_rules_for_event(v_event, 'sync');

  return v_id;
end;
$function$;

-- 2. cast_ranked_vote -------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cast_ranked_vote(
  p_decision_id uuid,
  p_rankings    jsonb,
  p_reason      text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_d         public.group_decisions%rowtype;
  v_voter     uuid;
  v_event     uuid;
  v_batch     timestamptz := now();
  v_first_id  uuid;
  v_n         integer;
  v_distinct  integer;
  r           record;
begin
  if p_rankings is null or jsonb_typeof(p_rankings) <> 'array' then
    raise exception 'p_rankings must be a jsonb array of {option_id, rank}'
      using errcode = '22023';
  end if;

  select * into v_d from public.group_decisions where id = p_decision_id;
  if v_d.id is null then raise exception 'decision not found'; end if;
  if v_d.method <> 'ranked_choice' then
    raise exception 'cast_ranked_vote only applies to ranked_choice decisions'
      using errcode = '22023';
  end if;
  if v_d.status <> 'open' then raise exception 'decision is not open'; end if;
  if v_d.closes_at is not null and v_d.closes_at < now() then
    raise exception 'voting window closed';
  end if;

  v_voter := (select gm.id from public.group_memberships gm
              where gm.group_id = v_d.group_id and gm.user_id = auth.uid() and gm.status = 'active');
  if v_voter is null then
    raise exception 'caller is not an active member of group %', v_d.group_id;
  end if;

  -- Validate rankings: at least one item, no duplicate option_id, all
  -- option_ids belong to this decision, ranks are positive integers.
  v_n := jsonb_array_length(p_rankings);
  if v_n < 1 then
    raise exception 'p_rankings must include at least one option' using errcode = '22023';
  end if;
  select count(distinct (item->>'option_id')) into v_distinct
    from jsonb_array_elements(p_rankings) as item;
  if v_distinct <> v_n then
    raise exception 'duplicate option_id in p_rankings' using errcode = '22023';
  end if;

  -- Insert one ballot per ranked option. Borda points = (N - rank).
  -- rank is 1-based: best = 1 → (N - 1) points; worst = N → 0 points.
  -- Sharing v_batch (cast_at) lets finalize_vote pick the latest ballot
  -- batch per voter without a new column.
  for r in
    select
      (item->>'option_id')::uuid                       as option_id,
      (item->>'rank')::int                             as rank
    from jsonb_array_elements(p_rankings) as item
    order by (item->>'rank')::int
  loop
    if r.rank is null or r.rank < 1 or r.rank > v_n then
      raise exception 'rank % out of range [1, %]', r.rank, v_n using errcode = '22023';
    end if;
    if not exists (
      select 1 from public.group_decision_options
       where id = r.option_id and decision_id = p_decision_id
    ) then
      raise exception 'option_id % does not belong to decision %', r.option_id, p_decision_id
        using errcode = '22023';
    end if;
    insert into public.group_votes (
      group_id, decision_id, voter_membership_id, option_id,
      vote_value, weight, reason, cast_at
    ) values (
      v_d.group_id, p_decision_id, v_voter, r.option_id,
      'rank', (v_n - r.rank)::numeric, p_reason, v_batch
    ) returning id into v_first_id;
  end loop;

  select rse.uuid_id into v_event from public.record_system_event(
    v_d.group_id, 'decision.vote_cast', 'decision', p_decision_id, null,
    jsonb_build_object('voter_membership_id', v_voter,
                       'authority_path', 'self_party',
                       'ranked', true,
                       'n_options', v_n)
  ) rse;
  perform public.evaluate_rules_for_event(v_event, 'sync');

  -- The "ballot id" we return is the first (highest-ranked) insert;
  -- the iOS client only needs *some* id to confirm acceptance.
  return v_first_id;
end;
$function$;

-- 3. finalize_vote branches per method --------------------------------------
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
begin
  select * into v_d from public.group_decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found'; end if;
  if v_d.status <> 'open' then return v_d.status; end if;

  ----------------------------------------------------------------------------
  -- Branch A: ranked_choice (Borda) ----------------------------------------
  ----------------------------------------------------------------------------
  if v_d.method = 'ranked_choice' then
    -- Aggregate the latest ballot batch per voter. A batch = all rows
    -- sharing (decision_id, voter_membership_id, cast_at). The latest
    -- batch is the one with max(cast_at).
    with latest_batch as (
      select voter_membership_id, max(cast_at) as latest_cast
        from public.group_votes
       where decision_id = p_decision_id
       group by voter_membership_id
    ), current_ballots as (
      select v.option_id, v.weight, v.voter_membership_id
        from public.group_votes v
        join latest_batch l using (voter_membership_id)
       where v.decision_id = p_decision_id
         and v.cast_at = l.latest_cast
    ), per_option as (
      select option_id, sum(weight) as points
        from current_ballots
       where option_id is not null
       group by option_id
    )
    select
      jsonb_object_agg(option_id, points),
      count(distinct voter_membership_id)
    into v_option_tally, v_voter_count
    from (
      select * from current_ballots
    ) sub;

    -- Build tally from per_option to keep numeric type.
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

    select option_id, points
      into v_winner_option, v_winner_points
      from (
        select (kv).key::uuid as option_id, (kv).value::text::numeric as points
          from (select jsonb_each(v_option_tally) as kv) e
      ) ranked
     order by points desc nulls last
     limit 1;

    -- Detect tie at the top by checking the second-place points.
    select points into v_runner_points
      from (
        select (kv).value::text::numeric as points
          from (select jsonb_each(v_option_tally) as kv) e
      ) ranked
     where points is not null and (v_winner_option is null or points <> v_winner_points)
     order by points desc
     limit 1;

    -- Quorum (optional) — counted by distinct voters that submitted any
    -- ranking, not by ballot count.
    if v_d.quorum_pct is not null then
      select count(*) into v_quorum_total
        from public.group_memberships
       where group_id = v_d.group_id and status = 'active';
      if v_quorum_total = 0 or (v_voter_count * 100.0 / v_quorum_total) < v_d.quorum_pct then
        v_outcome := 'no_quorum';
      end if;
    end if;

    if v_outcome is null then
      if v_winner_option is null or v_winner_points is null or v_winner_points <= 0 then
        v_outcome := 'rejected';
      elsif v_runner_points is not null and v_runner_points = v_winner_points then
        -- Tie at the top → no decision.
        v_outcome := 'rejected';
      else
        v_outcome := 'passed';
      end if;
    end if;

    v_result := jsonb_build_object(
      'method',         'ranked_choice',
      'option_tally',   v_option_tally,
      'winner_option',  v_winner_option,
      'winner_points',  v_winner_points,
      'voter_count',    v_voter_count,
      'outcome',        v_outcome
    );

  ----------------------------------------------------------------------------
  -- Branch B: weighted (per-option weighted sums) --------------------------
  ----------------------------------------------------------------------------
  elsif v_d.method = 'weighted' then
    with current as (
      select distinct on (voter_membership_id) *
        from public.group_votes
       where decision_id = p_decision_id
       order by voter_membership_id, seq desc
    ), per_option as (
      select option_id, sum(weight) as points
        from current
       where option_id is not null
       group by option_id
    )
    select coalesce(jsonb_object_agg(option_id, points), '{}'::jsonb),
           count(*)
      into v_option_tally, v_voter_count
      from per_option,
           (select count(*) c from current) cv;

    -- Recompute voter_count from current to keep semantics clear.
    select count(*) into v_voter_count
      from (
        select distinct on (voter_membership_id) *
          from public.group_votes
         where decision_id = p_decision_id
         order by voter_membership_id, seq desc
      ) cur;

    select option_id, points
      into v_winner_option, v_winner_points
      from (
        select (kv).key::uuid as option_id, (kv).value::text::numeric as points
          from (select jsonb_each(v_option_tally) as kv) e
      ) ranked
     order by points desc nulls last
     limit 1;

    select points into v_runner_points
      from (
        select (kv).value::text::numeric as points
          from (select jsonb_each(v_option_tally) as kv) e
      ) ranked
     where points is not null and (v_winner_option is null or points <> v_winner_points)
     order by points desc
     limit 1;

    if v_d.quorum_pct is not null then
      select count(*) into v_quorum_total
        from public.group_memberships
       where group_id = v_d.group_id and status = 'active';
      if v_quorum_total = 0 or (v_voter_count * 100.0 / v_quorum_total) < v_d.quorum_pct then
        v_outcome := 'no_quorum';
      end if;
    end if;

    if v_outcome is null then
      if v_winner_option is null or v_winner_points is null or v_winner_points <= 0 then
        v_outcome := 'rejected';
      elsif v_runner_points is not null and v_runner_points = v_winner_points then
        v_outcome := 'rejected';
      else
        v_outcome := 'passed';
      end if;
    end if;

    v_result := jsonb_build_object(
      'method',         'weighted',
      'option_tally',   v_option_tally,
      'winner_option',  v_winner_option,
      'winner_points',  v_winner_points,
      'voter_count',    v_voter_count,
      'outcome',        v_outcome
    );

  ----------------------------------------------------------------------------
  -- Branch C: legacy yes/no/abstain/block path (everything else) -----------
  ----------------------------------------------------------------------------
  else
    with current as (
      select distinct on (voter_membership_id) *
        from public.group_votes
       where decision_id = p_decision_id
       order by voter_membership_id, seq desc
    )
    select
      coalesce(sum(weight) filter (where vote_value = 'yes'), 0),
      coalesce(sum(weight) filter (where vote_value = 'no'), 0),
      coalesce(sum(weight) filter (where vote_value = 'abstain'), 0),
      coalesce(sum(weight) filter (where vote_value = 'block'), 0)
    into v_yes, v_no, v_abstain, v_block from current;

    v_total := v_yes + v_no + v_abstain + v_block;

    if v_d.quorum_pct is not null then
      select count(*) into v_quorum_total
        from public.group_memberships
       where group_id = v_d.group_id and status = 'active';
      if v_quorum_total = 0 or (v_total * 100.0 / v_quorum_total) < v_d.quorum_pct then
        v_outcome := 'no_quorum';
      end if;
    end if;

    v_threshold := coalesce(v_d.threshold_pct,
                            case v_d.method
                              when 'consensus'    then 100
                              when 'supermajority' then 66.66
                              when 'consent'      then 100
                              else 50.01
                            end);

    if v_outcome is null then
      if v_d.method = 'consent' and v_block > 0 then
        v_outcome := 'rejected';
      elsif (v_yes + v_no) > 0 and (v_yes * 100.0 / (v_yes + v_no)) >= v_threshold then
        v_outcome := 'passed';
      else
        v_outcome := 'rejected';
      end if;
    end if;

    v_result := jsonb_build_object(
      'yes', v_yes, 'no', v_no, 'abstain', v_abstain, 'block', v_block,
      'outcome', v_outcome
    );
  end if;

  update public.group_decisions
     set status = case when v_outcome = 'passed' then 'passed' else 'rejected' end,
         decided_at = now(),
         result = v_result
   where id = p_decision_id;

  ----------------------------------------------------------------------------
  -- Outcome handlers (G2) — only run on 'passed' --------------------------
  ----------------------------------------------------------------------------
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
      if v_pool_amount is not null
         and v_pool_amount > 0
         and v_pool_kind IN ('quota','buy_in','fee') then
        insert into public.group_obligations (
          group_id, owed_by_membership_id, owed_to_kind,
          obligation_kind, amount_original, amount_outstanding, unit,
          description, metadata
        ) values (
          v_d.group_id, v_d.reference_id, 'pool',
          'pool_charge', v_pool_amount, v_pool_amount, v_pool_unit,
          COALESCE(v_pool_reason, v_d.title),
          jsonb_build_object(
            'charge_kind', v_pool_kind,
            'source',      'decision',
            'decision_id', p_decision_id
          )
        )
        returning id into v_pool_obligation;
        perform public.record_system_event(
          v_d.group_id, 'money.pool_charge_created', 'obligation', v_pool_obligation,
          COALESCE(v_pool_reason, v_d.title),
          jsonb_build_object(
            'amount',      v_pool_amount,
            'unit',        v_pool_unit,
            'kind',        v_pool_kind,
            'target',      v_d.reference_id,
            'source',      'decision',
            'decision_id', p_decision_id
          )
        );
      end if;
    end if;
  end if;

  perform public.record_system_event(
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
  );

  return v_outcome;
end;
$function$;
