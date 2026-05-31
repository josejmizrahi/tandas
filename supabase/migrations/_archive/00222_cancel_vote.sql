-- Mig 00222: cancel_vote — creator can cancel an open vote with no real casts.
create or replace function public.cancel_vote(p_vote_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_vote votes%rowtype;
    v_caller_member uuid;
    v_real_casts int;
begin
    select * into v_vote from votes where id = p_vote_id;
    if not found then
        raise exception 'vote_not_found' using errcode = 'P0001';
    end if;
    if v_vote.status <> 'open' then
        raise exception 'vote_not_open' using errcode = 'P0001';
    end if;
    select id into v_caller_member
    from group_members
    where group_id = v_vote.group_id and user_id = auth.uid() and active = true;
    if v_caller_member is null then
        raise exception 'not_member' using errcode = 'P0001';
    end if;
    if v_vote.created_by_member_id is distinct from v_caller_member then
        raise exception 'not_creator' using errcode = 'P0001';
    end if;
    select count(*) into v_real_casts
    from (
        select distinct on (member_id) choice
        from vote_casts
        where vote_id = p_vote_id
        order by member_id, created_at desc
    ) latest
    where choice in ('in_favor', 'against', 'abstained');
    if v_real_casts > 0 then
        raise exception 'votes_already_cast' using errcode = 'P0001';
    end if;
    update votes
    set status = 'cancelled', resolved_at = now()
    where id = p_vote_id;
    perform public.record_system_event(
        v_vote.group_id,
        'voteResolved',
        jsonb_build_object(
            'vote_id', p_vote_id,
            'vote_type', v_vote.vote_type,
            'resolution', 'cancelled',
            'cancelled_by_member_id', v_caller_member
        )
    );
end;
$$;
grant execute on function public.cancel_vote(uuid) to authenticated;
