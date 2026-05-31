-- 00116 — Soft validation of votes.vote_type against the canonical
-- whitelist mirrored from the iOS `VoteType` enum.
--
-- Same pattern as 00092 for system_events.event_type:
--   1. is_known_vote_type(text) immutable function carries the whitelist.
--   2. start_vote raises NOTICE on unknown types but still inserts —
--      keeps prod working during the V1→Phase 2 window where new vote
--      types may ship in iOS before the whitelist regenerates.
--   3. Promotion to a hard CHECK constraint stays a separate migration
--      after a prod audit confirms zero zombie types.
--
-- Why this matters now: prod had `votes.vote_type = 'general'` from a
-- seed that didn't match any iOS VoteType case, so the iOS Vote
-- decoder threw and HomeView's "decisiones tomadas" counter showed 0
-- even though the row existed. The seed has been corrected to
-- `general_proposal`; this migration prevents a similar drift from
-- happening silently again.

create or replace function public.is_known_vote_type(p_vote_type text)
returns boolean
language sql
immutable
parallel safe
set search_path = public
as $$
  -- Keep in sync with
  -- ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/Vote.swift's
  -- `VoteType` enum. A new case in Swift requires a follow-up migration
  -- to update this function.
  select p_vote_type = any (array[
    'fine_appeal',
    'rule_change',
    'rule_repeal',
    'member_removal',
    'fund_withdrawal',
    'role_assignment',
    'general_proposal',
    'slot_dispute'
  ]);
$$;

revoke execute on function public.is_known_vote_type(text) from public, anon;
grant  execute on function public.is_known_vote_type(text) to authenticated, service_role;

comment on function public.is_known_vote_type(text) is
  'Whitelist check for votes.vote_type values. Mirrors the iOS VoteType enum. Used by start_vote for soft validation (NOTICE on unknown).';

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

  select governance into v_governance from public.groups where id = p_group_id;

  v_duration   := coalesce(p_duration_hours,      (v_governance->>'votingDurationHours')::int,        72);
  v_quorum     := coalesce(p_quorum_percent,      (v_governance->>'votingQuorumPercent')::int,        50);
  v_threshold  := coalesce(p_threshold_percent,   (v_governance->>'votingThresholdPercent')::int,     50);
  v_anonymous  := coalesce(p_is_anonymous,        (v_governance->>'votesAreAnonymous')::boolean,      true);
  v_quorum_min := coalesce(p_quorum_min_absolute, (v_governance->>'votingQuorumMinAbsolute')::int,    2);
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

comment on function public.start_vote(
  uuid, text, uuid, text, text, jsonb, int, int, int, boolean, int
) is
  'Creates a vote + pending vote_casts for active members. Validates vote_type against is_known_vote_type whitelist (NOTICE on unknown — see 00116). For vote_type=fine_appeal, excludes payload.member_id (the infractor). Reads governance defaults if duration/quorum/threshold/anonymous/quorum_min_absolute not provided.';
