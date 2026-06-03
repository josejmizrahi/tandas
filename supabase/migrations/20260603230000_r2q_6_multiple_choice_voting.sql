-- R.2Q-6 — multiple_choice voting.
--
-- Antes: vote_decision rechazaba multiple_choice con errcode 0A000. La
-- constraint UNIQUE (decision_id, voter_actor_id) bloqueaba el modelo.
-- Este migration relaja la constraint con partial uniques, extiende
-- vote_decision con la rama multiple_choice y agrega unvote_option.
--
-- Además: hotfix de GRANT EXECUTE para 4 RPCs de R.2Q (create_decision,
-- vote_for_option, create_decision_option, list_decision_options) que
-- quedaron sin grant a authenticated (Supabase REVOKE FROM anon default).
--
-- Doctrina:
--  - yes_no_abstain: exactamente 1 vote por voter, option_id IS NULL.
--    Partial unique (decision_id, voter_actor_id) WHERE option_id IS NULL.
--  - single_choice: exactamente 1 vote por voter con option_id IS NOT NULL.
--    Enforce vía DELETE+INSERT en vote_decision (la partial unique permite
--    múltiples por voter — el RPC asegura unicidad).
--  - multiple_choice: 1..N votes por voter, cada uno con option_id ≠ NULL.
--    Partial unique (decision_id, voter_actor_id, option_id) WHERE option_id
--    IS NOT NULL evita duplicar el mismo voto.
--  - Auto-finalize de multiple_choice queda manual (close_decision).

-- 1. Drop simple unique
ALTER TABLE public.decision_votes DROP CONSTRAINT IF EXISTS decision_votes_decision_id_voter_actor_id_key;

-- 2. Partial uniques
CREATE UNIQUE INDEX IF NOT EXISTS decision_votes_uniq_voter_yes_no
  ON public.decision_votes (decision_id, voter_actor_id)
  WHERE option_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS decision_votes_uniq_voter_option
  ON public.decision_votes (decision_id, voter_actor_id, option_id)
  WHERE option_id IS NOT NULL;

-- 3. Activity catalog
INSERT INTO public.activity_event_catalog (event_type, domain, description, expected_subject_type, is_system_generated)
VALUES
  ('decision.vote_removed', 'decision', 'Un voto fue removido (multiple_choice unvote)', 'decision_vote', false)
ON CONFLICT (event_type) DO NOTHING;

-- 4. vote_decision extendida con multiple_choice.
CREATE OR REPLACE FUNCTION public.vote_decision(p_decision_id uuid, p_vote text, p_option text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
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

  if v_d.voting_model not in ('yes_no_abstain', 'single_choice', 'multiple_choice') then
    raise exception 'voting_model_not_implemented: %', v_d.voting_model using errcode = '0A000';
  end if;

  if v_d.voting_model = 'single_choice' or v_d.voting_model = 'multiple_choice' then
    if p_vote <> 'abstain' and p_option is null then
      raise exception 'option required for % voting_model', v_d.voting_model using errcode = '22023';
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

  if v_d.voting_model = 'yes_no_abstain' then
    insert into public.decision_votes (decision_id, voter_actor_id, vote, option_id, metadata)
    values (p_decision_id, v_caller, p_vote, v_option_id,
            jsonb_strip_nulls(jsonb_build_object('option', p_option)))
    on conflict (decision_id, voter_actor_id) where option_id is null
    do update set vote = excluded.vote, voted_at = now(),
                  option_id = excluded.option_id,
                  metadata = excluded.metadata
    returning id into v_vote_id;
  elsif v_d.voting_model = 'single_choice' then
    delete from public.decision_votes
     where decision_id = p_decision_id and voter_actor_id = v_caller;
    insert into public.decision_votes (decision_id, voter_actor_id, vote, option_id, metadata)
    values (p_decision_id, v_caller, p_vote, v_option_id,
            jsonb_strip_nulls(jsonb_build_object('option', p_option)))
    returning id into v_vote_id;
  else -- multiple_choice
    insert into public.decision_votes (decision_id, voter_actor_id, vote, option_id, metadata)
    values (p_decision_id, v_caller, p_vote, v_option_id,
            jsonb_strip_nulls(jsonb_build_object('option', p_option)))
    on conflict (decision_id, voter_actor_id, option_id) where option_id is not null
    do nothing
    returning id into v_vote_id;
    if v_vote_id is null then
      select id into v_vote_id from public.decision_votes
       where decision_id = p_decision_id and voter_actor_id = v_caller and option_id = v_option_id;
    end if;
  end if;

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

  elsif v_d.voting_model = 'multiple_choice' then
    -- Tally completo; sin auto-finalize (cierre manual con close_decision).
    select coalesce(jsonb_object_agg(opt, votes), '{}'::jsonb) into v_option_tally
    from (
      select coalesce(o.option_key, dv.metadata->>'option') as opt, sum(dv.weight) as votes
        from public.decision_votes dv
        left join public.decision_options o on o.id = dv.option_id
       where dv.decision_id = p_decision_id
         and coalesce(o.option_key, dv.metadata->>'option') is not null
       group by coalesce(o.option_key, dv.metadata->>'option')
    ) t;

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
end; $function$;

-- 5. unvote_option (multiple_choice toggle-off).
CREATE OR REPLACE FUNCTION public.unvote_option(p_decision_id uuid, p_option_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_removed_id uuid;
BEGIN
  IF v_caller IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING errcode = '28000'; END IF;

  SELECT * INTO v_d FROM public.decisions WHERE id = p_decision_id;
  IF v_d.id IS NULL THEN RAISE EXCEPTION 'decision not found' USING errcode = 'P0002'; END IF;
  IF NOT public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.vote') THEN
    RAISE EXCEPTION 'not authorized to vote in context %', v_d.context_actor_id USING errcode = '42501';
  END IF;
  IF v_d.status <> 'open' THEN
    RAISE EXCEPTION 'decision is %', v_d.status USING errcode = '22023';
  END IF;
  IF v_d.voting_model <> 'multiple_choice' THEN
    RAISE EXCEPTION 'unvote_option only applies to multiple_choice voting (current: %)', v_d.voting_model USING errcode = '22023';
  END IF;

  DELETE FROM public.decision_votes
   WHERE decision_id = p_decision_id AND voter_actor_id = v_caller AND option_id = p_option_id
   RETURNING id INTO v_removed_id;

  IF v_removed_id IS NOT NULL THEN
    PERFORM public._emit_activity(
      v_d.context_actor_id, v_caller, 'decision.vote_removed', 'decision_vote', v_removed_id,
      jsonb_build_object('decision_id', p_decision_id, 'option_id', p_option_id),
      p_decision_id := p_decision_id
    );
  END IF;

  RETURN jsonb_build_object(
    'decision_id', p_decision_id,
    'option_id', p_option_id,
    'removed', v_removed_id IS NOT NULL
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.unvote_option(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.unvote_option(uuid, uuid) TO authenticated, service_role;

COMMENT ON FUNCTION public.unvote_option(uuid, uuid) IS
'R.2Q-6 — quita un voto del voter en una decisión multiple_choice. No-op si no existía.';

-- 6. HOTFIX GRANTs: 4 RPCs de R.2Q quedaron sin GRANT EXECUTE a authenticated.
DO $$
DECLARE
  v_name text;
  v_args text;
BEGIN
  FOR v_name, v_args IN
    SELECT proname, pg_get_function_identity_arguments(oid)
      FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname IN ('create_decision', 'vote_for_option', 'create_decision_option', 'list_decision_options')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s) FROM PUBLIC, anon', v_name, v_args);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO authenticated, service_role', v_name, v_args);
  END LOOP;
END $$;
