-- R.2Q.1 — RPCs + actualizar vote_decision, close_decision, execute_decision

-- ═════════════════════════════════════════════════════════════════════
-- create_decision_option
-- ═════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.create_decision_option(
  p_decision_id uuid,
  p_option_key text,
  p_title text,
  p_description text DEFAULT NULL,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_sort_order integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_option_id uuid;
  v_next_order integer;
BEGIN
  IF v_caller IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING errcode = '28000'; END IF;
  SELECT * INTO v_d FROM public.decisions WHERE id = p_decision_id FOR UPDATE;
  IF v_d.id IS NULL THEN RAISE EXCEPTION 'decision not found' USING errcode = 'P0002'; END IF;
  IF NOT public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.create') THEN
    RAISE EXCEPTION 'not authorized to add options to decisions' USING errcode = '42501';
  END IF;
  IF v_d.status <> 'open' THEN
    RAISE EXCEPTION 'cannot add options to a % decision', v_d.status USING errcode = '22023';
  END IF;
  IF v_d.voting_model = 'yes_no_abstain' THEN
    RAISE EXCEPTION 'yes_no_abstain decisions use built-in options' USING errcode = '22023';
  END IF;

  IF p_sort_order IS NULL THEN
    SELECT COALESCE(MAX(sort_order), -1) + 1 INTO v_next_order
      FROM public.decision_options WHERE decision_id = p_decision_id;
  ELSE
    v_next_order := p_sort_order;
  END IF;

  INSERT INTO public.decision_options
    (decision_id, option_key, title, description, payload, sort_order)
  VALUES
    (p_decision_id, p_option_key, btrim(p_title), p_description,
     COALESCE(p_payload, '{}'::jsonb), v_next_order)
  RETURNING id INTO v_option_id;

  RETURN jsonb_build_object(
    'option_id', v_option_id,
    'option', (SELECT to_jsonb(o) FROM public.decision_options o WHERE o.id = v_option_id)
  );
END $$;

-- ═════════════════════════════════════════════════════════════════════
-- list_decision_options
-- ═════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.list_decision_options(p_decision_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_options jsonb;
BEGIN
  IF v_caller IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING errcode = '28000'; END IF;
  SELECT * INTO v_d FROM public.decisions WHERE id = p_decision_id;
  IF v_d.id IS NULL THEN RAISE EXCEPTION 'decision not found' USING errcode = 'P0002'; END IF;
  IF NOT public.is_context_member(v_d.context_actor_id) THEN
    RAISE EXCEPTION 'not a member of the context' USING errcode = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(o) ORDER BY o.sort_order, o.created_at), '[]'::jsonb)
    INTO v_options
    FROM public.decision_options o
   WHERE o.decision_id = p_decision_id AND o.status = 'active';

  RETURN v_options;
END $$;

-- ═════════════════════════════════════════════════════════════════════
-- vote_for_option (canónica nueva)
-- ═════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.vote_for_option(
  p_decision_id uuid,
  p_option_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_opt public.decision_options%rowtype;
  v_vote_value text;
BEGIN
  SELECT * INTO v_opt FROM public.decision_options WHERE id = p_option_id;
  IF v_opt.id IS NULL THEN RAISE EXCEPTION 'option not found' USING errcode = 'P0002'; END IF;
  IF v_opt.decision_id <> p_decision_id THEN
    RAISE EXCEPTION 'option does not belong to decision' USING errcode = '22023';
  END IF;

  -- Convención de p_vote text para mantener back-compat con decision_votes.vote CHECK
  IF v_opt.option_key IN ('approve','reject','abstain') THEN
    v_vote_value := v_opt.option_key;
  ELSE
    v_vote_value := 'approve';
  END IF;

  RETURN public.vote_decision(p_decision_id, v_vote_value, v_opt.option_key);
END $$;

-- ═════════════════════════════════════════════════════════════════════
-- vote_decision (actualizada): resolve option_id desde p_option, valida voting_model
-- ═════════════════════════════════════════════════════════════════════
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
    -- abstain puede no traer option (no vota por nadie en particular)
    if p_vote <> 'abstain' and p_option is null then
      raise exception 'option required for single_choice voting_model' using errcode = '22023';
    end if;
    if p_option is not null then
      select id into v_option_id
        from public.decision_options
       where decision_id = p_decision_id and option_key = p_option and status = 'active';
      if v_option_id is null then
        raise exception 'invalid option: %', p_option using errcode = '22023';
      end if;
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

-- ═════════════════════════════════════════════════════════════════════
-- close_decision (actualizada): incluye winning_option_id
-- ═════════════════════════════════════════════════════════════════════
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

-- ═════════════════════════════════════════════════════════════════════
-- execute_decision (actualizada): dispatch por winning_option.payload.action
-- mantiene fallback a comportamiento hardcoded legacy
-- ═════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.execute_decision(p_decision_id uuid, p_result jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_winner_option text;
  v_winner_option_id uuid;
  v_opt public.decision_options%rowtype;
  v_action text;
  v_winner_res uuid;
  v_loser_res uuid;
  v_conflict_id uuid;
  v_conflict public.reservation_conflicts%rowtype;
  v_effects jsonb := '[]'::jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_d from public.decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.execute') then
    raise exception 'not authorized to execute decisions' using errcode = '42501';
  end if;

  if v_d.status = 'executed' then
    return jsonb_build_object('decision_id', p_decision_id, 'status', 'executed', 'already_executed', true);
  end if;
  if v_d.status <> 'approved' then
    raise exception 'only approved decisions can be executed (status: %)', v_d.status using errcode = '22023';
  end if;

  v_winner_option := v_d.result->>'winning_option';
  v_winner_option_id := (v_d.result->>'winning_option_id')::uuid;

  -- Resolver winning option si no fue persistida
  if v_winner_option_id is null and v_winner_option is not null then
    select id into v_winner_option_id from public.decision_options
     where decision_id = p_decision_id and option_key = v_winner_option;
  end if;

  -- Dispatch payload-driven (R.2Q)
  if v_winner_option_id is not null then
    select * into v_opt from public.decision_options where id = v_winner_option_id;
    v_action := v_opt.payload->>'action';

    if v_action = 'reservation_award' then
      v_winner_res := (v_opt.payload->>'winner_reservation_id')::uuid;
      v_conflict_id := (v_opt.payload->>'conflict_id')::uuid;

      if v_conflict_id is not null then
        select * into v_conflict from public.reservation_conflicts where id = v_conflict_id for update;
      end if;

      if v_conflict.id is not null and v_conflict.resolution_status = 'open' then
        v_loser_res := case when v_winner_res = v_conflict.reservation_a_id
                            then v_conflict.reservation_b_id else v_conflict.reservation_a_id end;

        update public.resource_reservations
           set status = 'rejected', source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('rejected_by_decision', p_decision_id)
         where id = v_loser_res and status in ('requested', 'approved');

        update public.resource_reservations
           set status = 'approved', source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('approved_by_decision', p_decision_id)
         where id = v_winner_res and status = 'requested';

        update public.reservation_conflicts
           set resolution_status = 'resolved', resolved_at = now(), source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('resolved_by_decision', p_decision_id,
                                                         'winner_reservation_id', v_winner_res)
         where id = v_conflict.id;

        perform public._emit_activity(v_d.context_actor_id, v_caller, 'reservation.approved',
          'reservation', v_winner_res,
          jsonb_build_object('by_decision', p_decision_id, 'winning_option', v_winner_option),
          p_resource_id := v_conflict.resource_id, p_decision_id := p_decision_id);
        perform public._emit_activity(v_d.context_actor_id, v_caller, 'reservation.rejected',
          'reservation', v_loser_res,
          jsonb_build_object('by_decision', p_decision_id),
          p_resource_id := v_conflict.resource_id, p_decision_id := p_decision_id);

        v_effects := jsonb_build_array(
          jsonb_build_object('type', 'conflict_resolved', 'conflict_id', v_conflict.id),
          jsonb_build_object('type', 'reservation_approved', 'reservation_id', v_winner_res),
          jsonb_build_object('type', 'reservation_rejected', 'reservation_id', v_loser_res));
      end if;

    elsif v_action = 'split_reservation' then
      v_conflict_id := (v_opt.payload->>'conflict_id')::uuid;
      if v_conflict_id is not null then
        select * into v_conflict from public.reservation_conflicts where id = v_conflict_id for update;
      end if;
      if v_conflict.id is not null and v_conflict.resolution_status = 'open' then
        update public.resource_reservations
           set status = 'approved', source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('split_by_decision', p_decision_id)
         where id in (v_conflict.reservation_a_id, v_conflict.reservation_b_id)
           and status = 'requested';

        update public.reservation_conflicts
           set resolution_status = 'resolved', resolved_at = now(), source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('resolved_by_decision', p_decision_id,
                                                         'resolution', 'split')
         where id = v_conflict.id;

        v_effects := jsonb_build_array(
          jsonb_build_object('type', 'conflict_resolved', 'conflict_id', v_conflict.id, 'resolution', 'split'));
      end if;

    elsif v_action = 'cancel_reservations' then
      v_conflict_id := (v_opt.payload->>'conflict_id')::uuid;
      if v_conflict_id is not null then
        select * into v_conflict from public.reservation_conflicts where id = v_conflict_id for update;
      end if;
      if v_conflict.id is not null and v_conflict.resolution_status = 'open' then
        update public.resource_reservations
           set status = 'cancelled', source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('cancelled_by_decision', p_decision_id)
         where id in (v_conflict.reservation_a_id, v_conflict.reservation_b_id)
           and status in ('requested', 'approved');

        update public.reservation_conflicts
           set resolution_status = 'resolved', resolved_at = now(), source_decision_id = p_decision_id,
               metadata = metadata || jsonb_build_object('resolved_by_decision', p_decision_id,
                                                         'resolution', 'cancelled')
         where id = v_conflict.id;

        v_effects := jsonb_build_array(
          jsonb_build_object('type', 'conflict_resolved', 'conflict_id', v_conflict.id, 'resolution', 'cancelled'));
      end if;
    end if;
  end if;

  -- Fallback legacy: reservation_dispute con payload-level option_reservations
  -- (mantiene back-compat con _smoke_r2g pre-R.2Q)
  if v_effects = '[]'::jsonb
     and v_d.decision_type = 'reservation_dispute'
     and v_d.payload ? 'reservation_conflict_id'
     and v_winner_option is not null
     and v_d.payload ? 'option_reservations'
     and v_d.payload->'option_reservations' ? v_winner_option then

    select * into v_conflict from public.reservation_conflicts
     where id = (v_d.payload->>'reservation_conflict_id')::uuid for update;

    if v_conflict.id is not null and v_conflict.resolution_status = 'open' then
      v_winner_res := (v_d.payload->'option_reservations'->>v_winner_option)::uuid;
      v_loser_res := case when v_winner_res = v_conflict.reservation_a_id
                          then v_conflict.reservation_b_id else v_conflict.reservation_a_id end;

      update public.resource_reservations
         set status = 'rejected', source_decision_id = p_decision_id,
             metadata = metadata || jsonb_build_object('rejected_by_decision', p_decision_id)
       where id = v_loser_res and status in ('requested', 'approved');

      update public.resource_reservations
         set status = 'approved', source_decision_id = p_decision_id,
             metadata = metadata || jsonb_build_object('approved_by_decision', p_decision_id)
       where id = v_winner_res and status = 'requested';

      update public.reservation_conflicts
         set resolution_status = 'resolved', resolved_at = now(), source_decision_id = p_decision_id,
             metadata = metadata || jsonb_build_object('resolved_by_decision', p_decision_id,
                                                       'winner_reservation_id', v_winner_res)
       where id = v_conflict.id;

      perform public._emit_activity(v_d.context_actor_id, v_caller, 'reservation.approved',
        'reservation', v_winner_res,
        jsonb_build_object('by_decision', p_decision_id, 'winning_option', v_winner_option),
        p_resource_id := v_conflict.resource_id, p_decision_id := p_decision_id);
      perform public._emit_activity(v_d.context_actor_id, v_caller, 'reservation.rejected',
        'reservation', v_loser_res,
        jsonb_build_object('by_decision', p_decision_id),
        p_resource_id := v_conflict.resource_id, p_decision_id := p_decision_id);

      v_effects := jsonb_build_array(
        jsonb_build_object('type', 'conflict_resolved', 'conflict_id', v_conflict.id),
        jsonb_build_object('type', 'reservation_approved', 'reservation_id', v_winner_res),
        jsonb_build_object('type', 'reservation_rejected', 'reservation_id', v_loser_res));
    end if;
  end if;

  update public.decisions
     set status = 'executed', executed_at = now(),
         result = result || coalesce(p_result, '{}'::jsonb)
                  || jsonb_build_object('executed_by_actor_id', v_caller, 'effects', v_effects)
   where id = p_decision_id;

  perform public._emit_activity(v_d.context_actor_id, v_caller, 'decision.executed', 'decision', p_decision_id,
    jsonb_build_object('effects', v_effects), p_decision_id := p_decision_id);

  return jsonb_build_object('decision_id', p_decision_id, 'status', 'executed', 'effects', v_effects);
end; $$;

-- ═════════════════════════════════════════════════════════════════════
-- decision_results
-- ═════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.decision_results(p_decision_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_options jsonb;
  v_counts jsonb;
BEGIN
  IF v_caller IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING errcode = '28000'; END IF;
  SELECT * INTO v_d FROM public.decisions WHERE id = p_decision_id;
  IF v_d.id IS NULL THEN RAISE EXCEPTION 'decision not found' USING errcode = 'P0002'; END IF;
  IF NOT public.is_context_member(v_d.context_actor_id) THEN
    RAISE EXCEPTION 'not a member of the context' USING errcode = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(o) ORDER BY o.sort_order, o.created_at), '[]'::jsonb)
    INTO v_options
    FROM public.decision_options o
   WHERE o.decision_id = p_decision_id AND o.status = 'active';

  SELECT COALESCE(jsonb_object_agg(opt_key, votes), '{}'::jsonb) INTO v_counts
  FROM (
    SELECT COALESCE(o.option_key, dv.metadata->>'option', dv.vote) AS opt_key,
           SUM(dv.weight) AS votes
      FROM public.decision_votes dv
      LEFT JOIN public.decision_options o ON o.id = dv.option_id
     WHERE dv.decision_id = p_decision_id
     GROUP BY COALESCE(o.option_key, dv.metadata->>'option', dv.vote)
  ) t;

  RETURN jsonb_build_object(
    'decision', to_jsonb(v_d),
    'options', v_options,
    'vote_counts', v_counts,
    'winner', jsonb_strip_nulls(jsonb_build_object(
      'option_key', v_d.result->>'winning_option',
      'option_id', v_d.result->>'winning_option_id'
    )),
    'execution_status', jsonb_build_object(
      'status', v_d.status,
      'executed_at', v_d.executed_at,
      'effects', COALESCE(v_d.result->'effects', '[]'::jsonb)
    )
  );
END $$;

-- Bloquear anon (defensa en profundidad)
REVOKE EXECUTE ON FUNCTION public.create_decision_option(uuid, text, text, text, jsonb, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.list_decision_options(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.vote_for_option(uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.decision_results(uuid) FROM anon;
