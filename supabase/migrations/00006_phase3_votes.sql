-- Phase 3: votes RPC.
-- cast_ballot: atomic upsert of a user's ballot for an open vote.
-- Replaces a prior ballot from the same user (vote_ballots is UNIQUE on
-- (vote_id, user_id), but we want the cleanest "change my mind" UX).

create or replace function public.cast_ballot(p_vote_id uuid, p_choice text)
returns public.vote_ballots
language plpgsql security definer set search_path = public as $$
declare
  v public.votes;
  ballot public.vote_ballots;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  if p_choice not in ('yes','no','abstain') then
    raise exception 'invalid choice: %', p_choice;
  end if;

  select * into v from public.votes where id = p_vote_id;
  if not found then raise exception 'vote not found'; end if;
  if v.status <> 'open' then raise exception 'vote is closed'; end if;
  if not public.is_group_member(v.group_id, auth.uid()) then raise exception 'not a member'; end if;
  if v.committee_only and not public.is_group_committee(v.group_id, auth.uid()) then
    raise exception 'committee only';
  end if;

  insert into public.vote_ballots (vote_id, user_id, choice, cast_at)
  values (p_vote_id, auth.uid(), p_choice, now())
  on conflict (vote_id, user_id)
  do update set choice = excluded.choice, cast_at = now()
  returning * into ballot;
  return ballot;
end;
$$;
revoke execute on function public.cast_ballot(uuid, text) from public, anon;
grant  execute on function public.cast_ballot(uuid, text) to authenticated;
