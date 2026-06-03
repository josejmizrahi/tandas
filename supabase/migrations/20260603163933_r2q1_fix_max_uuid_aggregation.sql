-- R.2Q.1 — Fix: PostgreSQL no tiene max(uuid). Resolvemos option_id por separado
-- (lookup por option_key después del aggregate, en lugar de incluirlo en GROUP BY).

CREATE OR REPLACE FUNCTION public.vote_decision(
  p_decision_id uuid,
  p_vote text,
  p_option text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_vote_id uuid;
  v_option_id uuid;
  v_winning_option_id uuid;
  v_members numeric;
  v_approve numeric;
  v_reject numeric;
  v_total_votes numeric;
  v_new_status text;
  v_option_tally jsonb;
  v_winning_option text;
  v_winning_votes numeric;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if p_vote not in ('approve', 'reject', 'abstain') then
    raise exception 'invalid vote: %', p_vote using errcode = '22023';
  end if;

  select * into v_d from public.decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.vote') then
    raise exception 'not authorized to vote in context %', v_d.context_actor_id using errcode = '42501';
  end if;
  if v_d.status <> 'open' then
    raise exception 'decision is %', v_d.status using errcode = '22023';
  end if;
  if v_d.closes_at is not null and v_d.closes_at <= now() then
    raise exception 'voting window closed' using errcode = '22023';
  end if;

  if v_d.voting_model not in ('yes_no_abstain', 'single_choice') then
    raise exception 'voting_model_not_implemented: %', v_d.voting_model using errcode = '0A000';
  end if;

  if v_d.voting_model = 'single_choice' then
    if p_option is null then
      raise exception 'option required for single_choice voting_model' using errcode = '22023';
    end if;
    select id into v_option_id
      from public.decision_options
     where decision_id = p_decision_id and option_key = p_option and status = 'active';
    if v_option_id is null then
      raise exception 'invalid option: %', p_option using errcode = '22023';
    end if;
  elsif v_d.voting_model = 'yes_no_abstain' then
    select id into v_option_id
      from public.decision_options
     where decision_id = p_decision_id and option_key = p_vote and status = 'active';
  end if;

  insert into public.decision_votes (decision_id, voter_actor_id, vote, option_id, metadata)
  values (p_decision_id, v_caller, p_vote, v_option_id,
          jsonb_strip_nulls(jsonb_build_object('option', p_option)))
  on conflict (decision_id, voter_actor_id)
  do update set vote = excluded.vote, voted_at = now(),
                option_id = excluded.option_id,
                metadata = excluded.metadata
  returning id into v_vote_id;

  perform public._emit_activity(v_d.context_actor_id, v_caller, 'decision.vote_cast', 'decision_vote', v_vote_id,
    jsonb_strip_nulls(jsonb_build_object(
      'decision_id', p_decision_id, 'vote', p_vote, 'option', p_option, 'option_id', v_option_id)),
    p_decision_id := p_decision_id);

  select count(*) into v_members from public.actor_memberships
   where context_actor_id = v_d.context_actor_id and membership_status = 'active';
  v_members := greatest(v_members, 1);

  select coalesce(sum(weight) filter (where vote = 'approve'), 0),
         coalesce(sum(weight) filter (where vote = 'reject'), 0),
         coalesce(sum(weight), 0)
    into v_approve, v_reject, v_total_votes
    from public.decision_votes where decision_id = p_decision_id;

  if v_d.voting_model = 'single_choice' then
    select coalesce(jsonb_object_agg(opt, votes), '{}'::jsonb) into v_option_tally
    from (
      select coalesce(o.option_key, dv.metadata->>'option') as opt, sum(dv.weight) as votes
        from public.decision_votes dv
        left join public.decision_options o on o.id = dv.option_id
       where dv.decision_id = p_decision_id
         and coalesce(o.option_key, dv.metadata->>'option') is not null
       group by coalesce(o.option_key, dv.metadata->>'option')
    ) t;

    select opt, votes into v_winning_option, v_winning_votes
    from (
      select coalesce(o.option_key, dv.metadata->>'option') as opt,
             sum(dv.weight) as votes
        from public.decision_votes dv
        left join public.decision_options o on o.id = dv.option_id
       where dv.decision_id = p_decision_id
         and coalesce(o.option_key, dv.metadata->>'option') is not null
       group by coalesce(o.option_key, dv.metadata->>'option')
       order by sum(dv.weight) desc limit 1
    ) w;

    if v_winning_option is not null then
      select id into v_winning_option_id from public.decision_options
       where decision_id = p_decision_id and option_key = v_winning_option;
    end if;

    if v_winning_votes > v_members / 2.0
       or (v_total_votes >= v_members and v_winning_votes > 0) then
      v_new_status := 'approved';
    end if;

  else
    if v_approve > v_members / 2.0 then
      v_new_status := 'approved';
      select id, option_key into v_winning_option_id, v_winning_option
        from public.decision_options where decision_id = p_decision_id and option_key = 'approve';
    elsif v_reject >= v_members / 2.0 and v_reject > 0 and (v_members - v_reject) < v_members / 2.0 then
      v_new_status := 'rejected';
      select id, option_key into v_winning_option_id, v_winning_option
        from public.decision_options where decision_id = p_decision_id and option_key = 'reject';
    end if;
  end if;

  if v_new_status is not null then
    update public.decisions
       set status = v_new_status, decided_at = now(),
           result = jsonb_strip_nulls(jsonb_build_object(
             'approve', v_approve, 'reject', v_reject, 'members', v_members,
             'option_tally', v_option_tally,
             'winning_option', v_winning_option,
             'winning_option_id', v_winning_option_id))
     where id = p_decision_id;

    perform public._emit_activity(v_d.context_actor_id, v_caller, 'decision.closed', 'decision', p_decision_id,
      jsonb_strip_nulls(jsonb_build_object(
        'status', v_new_status, 'winning_option', v_winning_option,
        'winning_option_id', v_winning_option_id,
        'closed_by', 'auto_finalize')),
      p_decision_id := p_decision_id);
  end if;

  return jsonb_build_object(
    'decision_id', p_decision_id, 'my_vote', p_vote, 'my_option', p_option,
    'my_option_id', v_option_id,
    'status', coalesce(v_new_status, 'open'),
    'tally', jsonb_strip_nulls(jsonb_build_object(
      'approve', v_approve, 'reject', v_reject, 'members', v_members,
      'option_tally', v_option_tally,
      'winning_option', v_winning_option,
      'winning_option_id', v_winning_option_id)));
end; $$;

CREATE OR REPLACE FUNCTION public.close_decision(p_decision_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_members numeric;
  v_approve numeric;
  v_reject numeric;
  v_option_tally jsonb;
  v_winning_option text;
  v_winning_option_id uuid;
  v_new_status text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_d from public.decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.execute') then
    raise exception 'not authorized to close decisions' using errcode = '42501';
  end if;

  if v_d.status <> 'open' then
    return jsonb_build_object('decision_id', p_decision_id, 'status', v_d.status,
      'winning_option', v_d.result->>'winning_option',
      'winning_option_id', v_d.result->>'winning_option_id',
      'already_closed', true);
  end if;

  select count(*) into v_members from public.actor_memberships
   where context_actor_id = v_d.context_actor_id and membership_status = 'active';
  v_members := greatest(v_members, 1);

  select coalesce(sum(weight) filter (where vote = 'approve'), 0),
         coalesce(sum(weight) filter (where vote = 'reject'), 0)
    into v_approve, v_reject
    from public.decision_votes where decision_id = p_decision_id;

  if v_d.voting_model = 'single_choice' then
    select coalesce(jsonb_object_agg(opt, votes), '{}'::jsonb) into v_option_tally
    from (
      select coalesce(o.option_key, dv.metadata->>'option') as opt, sum(dv.weight) as votes
        from public.decision_votes dv
        left join public.decision_options o on o.id = dv.option_id
       where dv.decision_id = p_decision_id
         and coalesce(o.option_key, dv.metadata->>'option') is not null
       group by coalesce(o.option_key, dv.metadata->>'option')
    ) t;

    select opt into v_winning_option
    from (
      select coalesce(o.option_key, dv.metadata->>'option') as opt,
             sum(dv.weight) as votes
        from public.decision_votes dv
        left join public.decision_options o on o.id = dv.option_id
       where dv.decision_id = p_decision_id
         and coalesce(o.option_key, dv.metadata->>'option') is not null
       group by coalesce(o.option_key, dv.metadata->>'option')
       order by sum(dv.weight) desc limit 1
    ) w;

    if v_winning_option is not null then
      select id into v_winning_option_id from public.decision_options
       where decision_id = p_decision_id and option_key = v_winning_option;
    end if;
    v_new_status := case when v_winning_option is not null then 'approved' else 'rejected' end;
  else
    v_new_status := case when v_approve > v_reject and v_approve > 0 then 'approved' else 'rejected' end;
    select id, option_key into v_winning_option_id, v_winning_option
      from public.decision_options where decision_id = p_decision_id
        and option_key = case when v_new_status = 'approved' then 'approve' else 'reject' end;
  end if;

  update public.decisions
     set status = v_new_status, decided_at = now(), closes_at = coalesce(closes_at, now()),
         result = jsonb_strip_nulls(jsonb_build_object(
           'approve', v_approve, 'reject', v_reject, 'members', v_members,
           'option_tally', v_option_tally,
           'winning_option', v_winning_option,
           'winning_option_id', v_winning_option_id))
   where id = p_decision_id;

  perform public._emit_activity(v_d.context_actor_id, v_caller, 'decision.closed', 'decision', p_decision_id,
    jsonb_strip_nulls(jsonb_build_object(
      'status', v_new_status, 'winning_option', v_winning_option,
      'winning_option_id', v_winning_option_id,
      'closed_by', 'explicit_close')),
    p_decision_id := p_decision_id);

  return jsonb_build_object('decision_id', p_decision_id, 'status', v_new_status,
    'winning_option', v_winning_option,
    'winning_option_id', v_winning_option_id,
    'tally', jsonb_strip_nulls(jsonb_build_object(
      'approve', v_approve, 'reject', v_reject, 'members', v_members, 'option_tally', v_option_tally)));
end; $$;
