-- 00233 — Vote RPCs gated on has_permission (Permission catalog v2).

create or replace function public.start_vote(
  p_group_id              uuid,
  p_vote_type             text,
  p_reference_id          uuid,
  p_title                 text,
  p_description           text    default null,
  p_payload               jsonb   default '{}'::jsonb,
  p_duration_hours        int     default null,
  p_quorum_percent        int     default null,
  p_threshold_percent     int     default null,
  p_is_anonymous          boolean default null,
  p_quorum_min_absolute   int     default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vote_id            uuid;
  v_caller_id          uuid;
  v_creator_member_id  uuid;
  v_governance         jsonb;
  v_voting_cfg         jsonb;
  v_duration           int;
  v_quorum             int;
  v_threshold          int;
  v_anonymous          boolean;
  v_quorum_min         int;
  v_excluded_member_id uuid;
  v_closes_at          timestamptz;
begin
  v_caller_id := auth.uid();
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if p_vote_type is null or length(trim(p_vote_type)) = 0 then
    raise exception 'vote_type required';
  end if;

  if not public.is_known_vote_type(p_vote_type) then
    raise notice 'start_vote: unknown vote_type % (group=%) — vote inserted but iOS clients may fail to decode it; fix the caller or ship a whitelist update.',
      p_vote_type, p_group_id;
  end if;

  select id into v_creator_member_id
  from public.group_members
  where group_id = p_group_id
    and user_id  = v_caller_id
    and active   = true;

  if v_creator_member_id is null then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  -- mig 00233: permission gate. Reachable only by active members per
  -- the lookup above; this enforces the role-level revoke.
  if not public.has_permission(p_group_id, v_caller_id, 'createVotes') then
    raise exception 'createVotes permission required'
      using errcode = '42501';
  end if;

  select governance into v_governance from public.groups where id = p_group_id;

  v_voting_cfg := coalesce(p_payload->'capability_config'->'voting', '{}'::jsonb);

  v_duration   := coalesce(
    p_duration_hours,
    (v_voting_cfg->>'durationHours')::int,
    (v_governance->>'votingDurationHours')::int,
    72
  );
  v_quorum     := coalesce(
    p_quorum_percent,
    (v_voting_cfg->>'quorumPercent')::int,
    (v_governance->>'votingQuorumPercent')::int,
    50
  );
  v_threshold  := coalesce(
    p_threshold_percent,
    (v_voting_cfg->>'thresholdPercent')::int,
    (v_governance->>'votingThresholdPercent')::int,
    50
  );
  v_anonymous  := coalesce(
    p_is_anonymous,
    (v_voting_cfg->>'anonymous')::boolean,
    (v_governance->>'votesAreAnonymous')::boolean,
    true
  );
  v_quorum_min := coalesce(
    p_quorum_min_absolute,
    (v_voting_cfg->>'quorumMinAbsolute')::int,
    (v_governance->>'votingQuorumMinAbsolute')::int,
    2
  );
  v_closes_at  := now() + (v_duration || ' hours')::interval;

  if p_vote_type = 'fine_appeal' then
    v_excluded_member_id := nullif(p_payload->>'member_id', '')::uuid;
  end if;

  insert into public.votes (
    group_id, vote_type, reference_id, title, description,
    created_by_member_id, opened_at, closes_at,
    quorum_percent, threshold_percent, is_anonymous, quorum_min_absolute,
    status, payload
  )
  values (
    p_group_id, p_vote_type, p_reference_id, p_title, p_description,
    v_creator_member_id, now(), v_closes_at,
    v_quorum, v_threshold, v_anonymous, v_quorum_min,
    'open', p_payload
  )
  returning id into v_vote_id;

  insert into public.vote_casts (vote_id, member_id, choice)
  select v_vote_id, gm.id, 'pending'
  from public.group_members gm
  where gm.group_id = p_group_id
    and gm.active   = true
    and (v_excluded_member_id is null or gm.id <> v_excluded_member_id);

  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (
    p_group_id,
    'voteOpened',
    v_vote_id,
    v_creator_member_id,
    jsonb_build_object('vote_type', p_vote_type, 'reference_id', p_reference_id)
  );

  insert into public.notifications_outbox (
    group_id, recipient_member_id, notification_type, payload, deep_link
  )
  select
    p_group_id,
    gm.id,
    'voteOpened',
    jsonb_build_object(
      'vote_id',      v_vote_id,
      'vote_type',    p_vote_type,
      'reference_id', p_reference_id,
      'title',        p_title,
      'closes_at',    v_closes_at
    ),
    'ruul://vote/' || v_vote_id::text
  from public.group_members gm
  where gm.group_id = p_group_id
    and gm.active   = true
    and (v_excluded_member_id is null or gm.id <> v_excluded_member_id);

  return v_vote_id;
end;
$$;

comment on function public.start_vote(uuid, text, uuid, text, text, jsonb, int, int, int, boolean, int) is
  'v3 (mig 00233): adds has_permission(createVotes) gate after the existing membership lookup. Body otherwise identical to mig 00130. Enforces role-level revoke for custom roles that opt out of vote creation.';

create or replace function public.cast_vote(p_vote_id uuid, p_choice text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id        uuid;
  v_caller_member_id uuid;
  v_vote_status      text;
  v_group_id         uuid;
begin
  v_caller_id := auth.uid();
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if p_choice not in ('in_favor', 'against', 'abstained') then
    raise exception 'invalid choice' using errcode = '22023';
  end if;

  select status, group_id into v_vote_status, v_group_id
  from public.votes where id = p_vote_id for key share;

  if v_vote_status is null then
    raise exception 'vote not found' using errcode = '02000';
  end if;
  if v_vote_status <> 'open' then
    raise exception 'vote is not open' using errcode = '22023';
  end if;

  select id into v_caller_member_id
  from public.group_members
  where group_id = v_group_id
    and user_id  = v_caller_id
    and active   = true;

  if v_caller_member_id is null then
    raise exception 'not eligible to vote' using errcode = '42501';
  end if;

  -- mig 00233: permission gate. Reachable only by active members per
  -- the lookup above; enforces role-level revoke.
  if not public.has_permission(v_group_id, v_caller_id, 'castVote') then
    raise exception 'castVote permission required'
      using errcode = '42501';
  end if;

  insert into public.vote_casts (vote_id, member_id, choice, cast_at)
  values (p_vote_id, v_caller_member_id, p_choice, now());

  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (
    v_group_id, 'voteCast', p_vote_id, v_caller_member_id,
    jsonb_build_object('choice', p_choice)
  );
end;
$$;

comment on function public.cast_vote(uuid, text) is
  'v2 (mig 00233): adds has_permission(castVote) gate after the existing membership lookup. Body otherwise identical to mig 00163 (append-only inserts).';
