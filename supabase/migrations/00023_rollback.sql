-- 00023 rollback — restore start_vote / finalize_vote without quorum_min_absolute,
-- infractor exclusion, or notifications_outbox writes.
--
-- Keep votes.quorum_min_absolute column (data-preserving rollback). To drop:
--   alter table public.votes drop column if exists quorum_min_absolute;

-- Restore the pre-00023 start_vote signature + body
create or replace function public.start_vote(
  p_group_id          uuid,
  p_vote_type         text,
  p_reference_id      uuid,
  p_title             text,
  p_description       text default null,
  p_payload           jsonb default '{}'::jsonb,
  p_duration_hours    int   default null,
  p_quorum_percent    int   default null,
  p_threshold_percent int   default null,
  p_is_anonymous      boolean default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vote_id   uuid;
  v_caller_id uuid;
  v_creator_member_id uuid;
  v_governance jsonb;
  v_duration int;
  v_quorum int;
  v_threshold int;
  v_anonymous boolean;
begin
  v_caller_id := auth.uid();
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select id into v_creator_member_id
  from public.group_members
  where group_id = p_group_id
    and user_id  = v_caller_id
    and active   = true;

  if v_creator_member_id is null then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  select governance into v_governance from public.groups where id = p_group_id;

  v_duration  := coalesce(p_duration_hours,    (v_governance->>'votingDurationHours')::int,    72);
  v_quorum    := coalesce(p_quorum_percent,    (v_governance->>'votingQuorumPercent')::int,    50);
  v_threshold := coalesce(p_threshold_percent, (v_governance->>'votingThresholdPercent')::int, 50);
  v_anonymous := coalesce(p_is_anonymous,      (v_governance->>'votesAreAnonymous')::boolean,  true);

  insert into public.votes (
    group_id, vote_type, reference_id, title, description,
    created_by_member_id, opened_at, closes_at,
    quorum_percent, threshold_percent, is_anonymous,
    status, payload
  )
  values (
    p_group_id, p_vote_type, p_reference_id, p_title, p_description,
    v_creator_member_id, now(), now() + (v_duration || ' hours')::interval,
    v_quorum, v_threshold, v_anonymous,
    'open', p_payload
  )
  returning id into v_vote_id;

  insert into public.vote_casts (vote_id, member_id, choice)
  select v_vote_id, gm.id, 'pending'
  from public.group_members gm
  where gm.group_id = p_group_id
    and gm.active   = true;

  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (
    p_group_id,
    'voteOpened',
    v_vote_id,
    v_creator_member_id,
    jsonb_build_object('vote_type', p_vote_type, 'reference_id', p_reference_id)
  );

  return v_vote_id;
end;
$$;

-- Restore the pre-00023 finalize_vote (percentage-only quorum, no outbox)
create or replace function public.finalize_vote(p_vote_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vote          public.votes%rowtype;
  v_in_favor      int;
  v_against       int;
  v_abstained     int;
  v_pending       int;
  v_total         int;
  v_voted         int;
  v_quorum_count  int;
  v_resolution    text;
begin
  select * into v_vote from public.votes where id = p_vote_id for update;
  if not found then
    raise exception 'vote not found' using errcode = '02000';
  end if;
  if v_vote.status <> 'open' then
    return coalesce(v_vote.payload->>'resolution', 'unknown');
  end if;

  select
    count(*) filter (where choice = 'in_favor'),
    count(*) filter (where choice = 'against'),
    count(*) filter (where choice = 'abstained'),
    count(*) filter (where choice = 'pending'),
    count(*)
  into v_in_favor, v_against, v_abstained, v_pending, v_total
  from public.vote_casts
  where vote_id = p_vote_id;

  v_voted        := v_in_favor + v_against + v_abstained;
  v_quorum_count := ceil(v_total::numeric * v_vote.quorum_percent / 100);

  if v_voted < v_quorum_count then
    v_resolution := 'quorum_failed';
  elsif v_in_favor::numeric * 100 >= (v_in_favor + v_against)::numeric * v_vote.threshold_percent then
    v_resolution := 'passed';
  else
    v_resolution := 'failed';
  end if;

  update public.votes
  set status      = case when v_resolution = 'quorum_failed' then 'quorum_failed' else 'resolved' end,
      resolved_at = now(),
      counts      = jsonb_build_object(
        'inFavor',       v_in_favor,
        'against',       v_against,
        'abstained',     v_abstained,
        'pending',       v_pending,
        'totalEligible', v_total,
        'resolution',    v_resolution
      ),
      payload = payload || jsonb_build_object('resolution', v_resolution)
  where id = p_vote_id;

  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (
    v_vote.group_id,
    'voteResolved',
    p_vote_id,
    null,
    jsonb_build_object(
      'vote_type',    v_vote.vote_type,
      'reference_id', v_vote.reference_id,
      'resolution',   v_resolution
    )
  );

  return v_resolution;
end;
$$;
