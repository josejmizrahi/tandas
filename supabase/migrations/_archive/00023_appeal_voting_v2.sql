-- 00023 — Appeal voting v2: quorum_min_absolute + infractor exclusion
--           + notifications_outbox writes
--
-- Three changes that close gaps in the V1 fine-appeal flow:
--
--   1. Adds `votes.quorum_min_absolute` (default 2). finalize_vote() now
--      requires `greatest(ceil(total * pct / 100), min_absolute)` votes
--      cast before quorum is met. Protects against "1 person decides
--      the whole appeal" scenarios in groups of 2-3 where the percentage
--      math degenerates.
--
--   2. start_vote() with vote_type='fine_appeal' EXCLUDES the infractor
--      (payload->>'member_id') from the eligible voter pool. The infractor
--      cannot vote on their own appeal — they're the subject of it.
--
--   3. start_vote() and finalize_vote() now insert into
--      notifications_outbox (added in 00022) so the E2E test + future
--      APNs dispatcher have a queryable record of who needs to be notified
--      and when.
--
-- Combined effect for the 2-member edge case:
--   eligible = 1 (founder, infractor excluded)
--   quorum   = max(ceil(1 * 0.5), 2) = 2
--   1 < 2  → finalize_vote returns 'quorum_failed'
--   The fine stays officialized.
--
-- Backfill: existing open votes get quorum_min_absolute = 2 (the new
-- column default). governance gets votingQuorumMinAbsolute = 2 if absent.
-- Existing closed/resolved votes are unaffected.

-- =============================================================================
-- 1. votes.quorum_min_absolute column
-- =============================================================================

alter table public.votes
  add column if not exists quorum_min_absolute int not null default 2;

comment on column public.votes.quorum_min_absolute is
  'Minimum absolute number of votes cast (in_favor + against + abstained) required for quorum. Final quorum = greatest(ceil(total_eligible * quorum_percent / 100), quorum_min_absolute). Default 2 prevents 1-person decisions in tiny groups.';

-- =============================================================================
-- 2. Backfill governance with the new default
-- =============================================================================

update public.groups
set governance = governance || jsonb_build_object('votingQuorumMinAbsolute', 2)
where governance is null
   or not (governance ? 'votingQuorumMinAbsolute');

-- =============================================================================
-- 3. Recreate start_vote with infractor exclusion + quorum_min_absolute param
--    + notifications_outbox writes
-- =============================================================================

create or replace function public.start_vote(
  p_group_id              uuid,
  p_vote_type             text,
  p_reference_id          uuid,
  p_title                 text,
  p_description           text default null,
  p_payload               jsonb default '{}'::jsonb,
  p_duration_hours        int   default null,
  p_quorum_percent        int   default null,
  p_threshold_percent     int   default null,
  p_is_anonymous          boolean default null,
  p_quorum_min_absolute   int   default null
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

  select id into v_creator_member_id
  from public.group_members
  where group_id = p_group_id
    and user_id  = v_caller_id
    and active   = true;

  if v_creator_member_id is null then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  select governance into v_governance from public.groups where id = p_group_id;

  v_duration   := coalesce(p_duration_hours,      (v_governance->>'votingDurationHours')::int,        72);
  v_quorum     := coalesce(p_quorum_percent,      (v_governance->>'votingQuorumPercent')::int,        50);
  v_threshold  := coalesce(p_threshold_percent,   (v_governance->>'votingThresholdPercent')::int,     50);
  v_anonymous  := coalesce(p_is_anonymous,        (v_governance->>'votesAreAnonymous')::boolean,      true);
  v_quorum_min := coalesce(p_quorum_min_absolute, (v_governance->>'votingQuorumMinAbsolute')::int,    2);
  v_closes_at  := now() + (v_duration || ' hours')::interval;

  -- For fine_appeal: the infractor cannot vote on their own appeal.
  -- Convention: payload.member_id holds the group_members.id of the
  -- infractor. Other vote_types ignore this and include all members.
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

  -- Notification fan-out: every eligible voter gets a "vote opened" push.
  -- Excludes the infractor (already excluded from vote_casts above).
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

comment on function public.start_vote(
  uuid, text, uuid, text, text, jsonb, int, int, int, boolean, int
) is
  'Creates a vote + pending vote_casts for active members. For vote_type=fine_appeal, excludes payload.member_id (the infractor) from eligible voters. Inserts a notifications_outbox row per eligible voter. Reads governance defaults if duration/quorum/threshold/anonymous/quorum_min_absolute not provided.';

-- =============================================================================
-- 4. Recreate finalize_vote with greatest(pct, min_absolute) quorum
--    + notifications_outbox writes
-- =============================================================================

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
  v_quorum_count := greatest(
    ceil(v_total::numeric * v_vote.quorum_percent / 100)::int,
    v_vote.quorum_min_absolute
  );

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
        'inFavor',        v_in_favor,
        'against',        v_against,
        'abstained',      v_abstained,
        'pending',        v_pending,
        'totalEligible',  v_total,
        'quorumRequired', v_quorum_count,
        'resolution',     v_resolution
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

  -- Notification fan-out on resolve: notify everyone who had a ballot
  -- (in_favor / against / abstained / pending — i.e. all originally
  -- eligible voters) PLUS the appellant if it's a fine_appeal and they
  -- aren't already in the eligible set (they shouldn't be, since
  -- start_vote excludes them — but include explicitly for safety).
  insert into public.notifications_outbox (
    group_id, recipient_member_id, notification_type, payload, deep_link
  )
  select
    v_vote.group_id,
    vc.member_id,
    'voteResolved',
    jsonb_build_object(
      'vote_id',      p_vote_id,
      'vote_type',    v_vote.vote_type,
      'reference_id', v_vote.reference_id,
      'resolution',   v_resolution,
      'title',        v_vote.title
    ),
    'ruul://vote/' || p_vote_id::text
  from public.vote_casts vc
  where vc.vote_id = p_vote_id;

  -- For fine_appeal: also notify the appellant (the infractor whose
  -- appeal this is). They were excluded from vote_casts so they're not
  -- in the SELECT above, but they need to know the outcome.
  if v_vote.vote_type = 'fine_appeal' then
    insert into public.notifications_outbox (
      group_id, recipient_member_id, notification_type, payload, deep_link
    )
    select
      v_vote.group_id,
      (v_vote.payload->>'member_id')::uuid,
      'voteResolved',
      jsonb_build_object(
        'vote_id',      p_vote_id,
        'vote_type',    v_vote.vote_type,
        'reference_id', v_vote.reference_id,
        'resolution',   v_resolution,
        'title',        v_vote.title,
        'is_appellant', true
      ),
      'ruul://vote/' || p_vote_id::text
    where v_vote.payload ? 'member_id'
      and (v_vote.payload->>'member_id') <> '';
  end if;

  return v_resolution;
end;
$$;

comment on function public.finalize_vote is
  'Closes vote, computes resolution. Quorum = greatest(ceil(total_eligible * quorum_percent / 100), quorum_min_absolute). Emits voteResolved event + writes notifications_outbox rows for all eligible voters (and the appellant for fine_appeal).';
