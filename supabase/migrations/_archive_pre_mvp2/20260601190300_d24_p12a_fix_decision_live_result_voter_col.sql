-- d24_p12a_fix_decision_live_result_voter_col
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- Hot-fix: group_votes column is voter_membership_id, not membership_id.
create or replace function public.decision_live_result(p_decision_id uuid)
returns jsonb
language plpgsql stable security definer set search_path=public, pg_catalog
as $$
declare
    v_uid uuid := (select auth.uid());
    v_d public.group_decisions%ROWTYPE;
    v_my_membership_id uuid;
    v_my_vote jsonb;
    v_counts jsonb;
    v_eligible int;
    v_total_votes int;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_d from public.group_decisions where id=p_decision_id;
    if v_d.id is null then raise exception 'decision_not_found' using errcode='42704'; end if;
    if not public.is_group_member(v_d.group_id) then raise exception 'not_a_member' using errcode='42501'; end if;

    select id into v_my_membership_id from public.group_memberships
    where group_id=v_d.group_id and user_id=v_uid and status='active' limit 1;

    with latest as (
        select distinct on (voter_membership_id) voter_membership_id, vote_value, cast_at, reason
        from public.group_votes
        where decision_id = p_decision_id
        order by voter_membership_id, cast_at desc, id desc
    )
    select jsonb_build_object(
        'yes', count(*) filter (where vote_value='yes'),
        'no',  count(*) filter (where vote_value='no'),
        'abstain', count(*) filter (where vote_value='abstain'),
        'maybe', count(*) filter (where vote_value='maybe'),
        'total', count(*)
    ) into v_counts
    from latest;

    v_total_votes := coalesce((v_counts->>'total')::int, 0);

    select count(*) into v_eligible from public.group_memberships
    where group_id=v_d.group_id and status='active';

    select jsonb_build_object(
        'vote_value', vote_value,
        'cast_at', cast_at,
        'reason', reason
    ) into v_my_vote
    from public.group_votes
    where decision_id=p_decision_id and voter_membership_id=v_my_membership_id
    order by cast_at desc, id desc limit 1;

    return jsonb_build_object(
        'decision', to_jsonb(v_d),
        'current_vote_counts', coalesce(v_counts, jsonb_build_object('yes',0,'no',0,'abstain',0,'maybe',0,'total',0)),
        'my_vote', coalesce(v_my_vote, 'null'::jsonb),
        'eligible_voters_count', v_eligible,
        'quorum_status', jsonb_build_object(
            'required_pct', v_d.quorum_pct,
            'current_pct', case when v_eligible=0 then 0
                               else round((v_total_votes::numeric * 100.0 / v_eligible)::numeric, 2) end,
            'reached', case when v_eligible=0 then false
                            else (v_total_votes::numeric * 100.0 / v_eligible) >= coalesce(v_d.quorum_pct, 0) end
        ),
        'threshold_status', jsonb_build_object(
            'required_pct', v_d.threshold_pct,
            'current_yes_pct', case when v_total_votes=0 then 0
                                else round(((v_counts->>'yes')::numeric * 100.0 / v_total_votes)::numeric, 2) end,
            'reached', case when v_total_votes=0 then false
                            else ((v_counts->>'yes')::numeric * 100.0 / v_total_votes) >= coalesce(v_d.threshold_pct, 50) end
        ),
        'execution_status', v_d.execution_status,
        'execution_attempts', v_d.execution_attempts,
        'execution_error', v_d.execution_error
    );
end$$;
grant execute on function public.decision_live_result(uuid) to authenticated;
