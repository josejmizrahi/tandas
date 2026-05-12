-- 00116_rollback.sql
-- Reverts start_vote to the 00023 shape (no vote_type whitelist NOTICE).
-- Drops is_known_vote_type. Existing votes rows are left untouched.

drop function if exists public.is_known_vote_type(text);

-- Restore start_vote to the 00023 implementation by re-inserting the
-- pre-00116 body. Anyone who needs the pristine source can read
-- supabase/migrations/00023_appeal_voting_v2.sql.
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
  where group_id = p_group_id and user_id = v_caller_id and active = true;
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
  ) values (
    p_group_id, p_vote_type, p_reference_id, p_title, p_description,
    v_creator_member_id, now(), v_closes_at,
    v_quorum, v_threshold, v_anonymous, v_quorum_min,
    'open', p_payload
  ) returning id into v_vote_id;
  insert into public.vote_casts (vote_id, member_id, choice)
  select v_vote_id, gm.id, 'pending'
  from public.group_members gm
  where gm.group_id = p_group_id and gm.active = true
    and (v_excluded_member_id is null or gm.id <> v_excluded_member_id);
  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (
    p_group_id, 'voteOpened', v_vote_id, v_creator_member_id,
    jsonb_build_object('vote_type', p_vote_type, 'reference_id', p_reference_id)
  );
  insert into public.notifications_outbox (
    group_id, recipient_member_id, notification_type, payload, deep_link
  )
  select
    p_group_id, gm.id, 'voteOpened',
    jsonb_build_object(
      'vote_id', v_vote_id, 'vote_type', p_vote_type, 'reference_id', p_reference_id,
      'title', p_title, 'closes_at', v_closes_at
    ),
    'ruul://vote/' || v_vote_id::text
  from public.group_members gm
  where gm.group_id = p_group_id and gm.active = true
    and (v_excluded_member_id is null or gm.id <> v_excluded_member_id);
  return v_vote_id;
end;
$$;
