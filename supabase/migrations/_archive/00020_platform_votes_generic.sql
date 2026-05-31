-- 00020 — Platform V2: generic Vote / VoteCast tables
--
-- Phase1 Bloque 1 (Plans/Phase1.md decision C). Replaces the appeal-specific
-- voting tables (appeals, appeal_votes) with a generic vote/vote_casts pair
-- that supports any vote_type:
--   V1:        fine_appeal
--   V2 ready:  rule_change, member_removal, fund_withdrawal, role_assignment,
--              general_proposal, slot_dispute
--
-- Backfill: existing appeals → votes (vote_type='fine_appeal'),
--           existing appeal_votes → vote_casts.
-- Vote IDs preserve appeal IDs, so vote_casts.vote_id = old appeal_id.
--
-- LEGACY appeals + appeal_votes NOT DROPPED. They remain until paridad is
-- verified and app code dual-writes are validated.

-- =============================================================================
-- 0. Drop legacy votes + RPCs from 00006_phase3_votes
-- =============================================================================
--
-- Existing public.votes (from 00006) had a different schema: subject_type,
-- subject_id, opens_at, threshold/quorum numeric, committee_only, result
-- (jsonb). Zero rows in production, no FK references, no app consumers.
-- The legacy RPCs (create_vote, close_vote, cast_ballot) operate on that
-- shape and become orphans after we redefine the table.
--
-- Drop CASCADE clears the table + its policies + dependents in one shot.

drop function if exists public.cast_ballot(uuid, uuid, text) cascade;
drop function if exists public.close_vote(uuid) cascade;
drop function if exists public.create_vote(uuid, text, uuid, text, text, jsonb) cascade;
drop function if exists public.create_vote(uuid, text, uuid, text, text) cascade;
drop function if exists public.create_vote cascade;
drop table    if exists public.ballots cascade;
drop table    if exists public.votes cascade;

-- =============================================================================
-- 1. votes — generic vote envelope
-- =============================================================================

create table if not exists public.votes (
  id                    uuid primary key default gen_random_uuid(),
  group_id              uuid not null references public.groups(id) on delete cascade,
  vote_type             text not null,
  reference_id          uuid not null,                 -- appeal_id, proposal_id, etc.
  title                 text not null,
  description           text,
  created_by_member_id  uuid references public.group_members(id) on delete set null,
  opened_at             timestamptz not null default now(),
  closes_at             timestamptz not null,
  resolved_at           timestamptz,
  quorum_percent        int  not null default 50,
  threshold_percent     int  not null default 50,
  is_anonymous          boolean not null default true,
  status                text not null default 'open',  -- open | closed | resolved | quorum_failed | cancelled
  counts                jsonb,
  payload               jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

comment on table public.votes is
  'Generic vote envelope. Supports fine_appeal (V1) and rule_change / member_removal / fund_withdrawal / etc. (V2+).';
comment on column public.votes.vote_type is
  'fine_appeal | rule_change | member_removal | fund_withdrawal | role_assignment | general_proposal | slot_dispute';
comment on column public.votes.reference_id is
  'Entity the vote decides about. For fine_appeal: appeal_id. For rule_change: rule_id. Etc.';
comment on column public.votes.payload is
  'Vote-type-specific context. e.g. {fine_id, member_id} for fine_appeal.';
comment on column public.votes.status is
  'open | closed | resolved | quorum_failed | cancelled';

create index if not exists votes_group_status_idx
  on public.votes(group_id, status);
create index if not exists votes_reference_idx
  on public.votes(reference_id);
create index if not exists votes_type_idx
  on public.votes(vote_type);
create index if not exists votes_open_closing_idx
  on public.votes(closes_at)
  where status = 'open';

create trigger votes_set_updated_at
  before update on public.votes
  for each row execute function public.set_updated_at();

-- =============================================================================
-- 2. vote_casts — individual ballots
-- =============================================================================

create table if not exists public.vote_casts (
  id          uuid primary key default gen_random_uuid(),
  vote_id     uuid not null references public.votes(id) on delete cascade,
  member_id   uuid not null references public.group_members(id) on delete cascade,
  choice      text not null default 'pending',         -- pending | in_favor | against | abstained
  cast_at     timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique(vote_id, member_id)
);

comment on column public.vote_casts.choice is
  'pending | in_favor | against | abstained';

create trigger vote_casts_set_updated_at
  before update on public.vote_casts
  for each row execute function public.set_updated_at();

create index if not exists vote_casts_vote_idx on public.vote_casts(vote_id);
create index if not exists vote_casts_member_idx on public.vote_casts(member_id);

-- =============================================================================
-- 3. vote_counts_view — anonymized aggregate
-- =============================================================================
--
-- Bypasses RLS on vote_casts (default security_invoker=off in Postgres).
-- Clients see counts without seeing individual choices. Required for
-- anonymity guarantee when is_anonymous=true.

create or replace view public.vote_counts_view as
select
  vote_id,
  count(*) filter (where choice = 'in_favor')  as in_favor,
  count(*) filter (where choice = 'against')   as against,
  count(*) filter (where choice = 'abstained') as abstained,
  count(*) filter (where choice = 'pending')   as pending,
  count(*)                                      as total_eligible
from public.vote_casts
group by vote_id;

comment on view public.vote_counts_view is
  'Aggregated vote counts per vote_id. Reads bypass vote_casts RLS so anonymity is preserved.';

-- =============================================================================
-- 4. Backfill: appeals → votes
-- =============================================================================
--
-- Preserves appeal.id as vote.id so vote_casts.vote_id maps cleanly to old
-- appeal_votes.appeal_id without lookups.

insert into public.votes (
  id, group_id, vote_type, reference_id, title, description,
  created_by_member_id, opened_at, closes_at, resolved_at,
  quorum_percent, threshold_percent, is_anonymous, status,
  counts, payload, created_at, updated_at
)
select
  a.id,                                          -- preserve id
  m.group_id,                                    -- group via member
  'fine_appeal',
  a.id,                                          -- reference_id = appeal id (the entity being voted on is the appeal itself)
  'Apelación de multa',                          -- generic title; UI renders specifics
  a.reason,
  a.appellant_member_id,
  a.voting_started_at,
  a.voting_ends_at,
  a.resolved_at,
  coalesce((g.governance->>'votingQuorumPercent')::int, 50),
  coalesce((g.governance->>'votingThresholdPercent')::int, 50),
  coalesce((g.governance->>'votesAreAnonymous')::boolean, true),
  case a.status
    when 'voting'              then 'open'
    when 'resolved_in_favor'   then 'resolved'
    when 'resolved_against'    then 'resolved'
    when 'expired'             then 'closed'
    else a.status
  end,
  a.vote_counts,
  jsonb_build_object(
    'fine_id', a.fine_id,
    'resolution', case a.status
      when 'resolved_in_favor' then 'passed'
      when 'resolved_against'  then 'failed'
      when 'expired'           then 'quorum_failed'
      else null
    end
  ),
  a.created_at,
  a.updated_at
from public.appeals a
join public.group_members m on m.id = a.appellant_member_id
join public.groups g on g.id = m.group_id
on conflict (id) do nothing;

-- =============================================================================
-- 5. Backfill: appeal_votes → vote_casts
-- =============================================================================

insert into public.vote_casts (
  id, vote_id, member_id, choice, cast_at, created_at, updated_at
)
select
  av.id,
  av.appeal_id,            -- maps to votes.id (preserved above)
  av.member_id,
  av.choice,
  av.voted_at,
  av.created_at,
  av.updated_at
from public.appeal_votes av
on conflict (id) do nothing;

-- =============================================================================
-- 6. RLS
-- =============================================================================

alter table public.votes enable row level security;
alter table public.vote_casts enable row level security;

-- votes: any member of the group can SELECT. Direct INSERT/UPDATE blocked —
-- only via SECURITY DEFINER RPCs (start_vote, finalize_vote, etc.) which
-- enforce governance rules.

drop policy if exists votes_select_members on public.votes;
create policy votes_select_members on public.votes
  for select
  using (
    exists (
      select 1 from public.group_members gm
      where gm.group_id = votes.group_id
        and gm.user_id  = auth.uid()
        and gm.active   = true
    )
  );

-- vote_casts: only the caster sees their own ballot (anonymity).
-- UPDATE only by owner while parent vote is still open.

drop policy if exists vote_casts_select_own on public.vote_casts;
create policy vote_casts_select_own on public.vote_casts
  for select
  using (
    exists (
      select 1 from public.group_members gm
      where gm.id      = vote_casts.member_id
        and gm.user_id = auth.uid()
    )
  );

drop policy if exists vote_casts_update_own_open on public.vote_casts;
create policy vote_casts_update_own_open on public.vote_casts
  for update
  using (
    exists (
      select 1 from public.group_members gm
      where gm.id      = vote_casts.member_id
        and gm.user_id = auth.uid()
    )
    and exists (
      select 1 from public.votes v
      where v.id     = vote_casts.vote_id
        and v.status = 'open'
    )
  );

-- =============================================================================
-- 7. Generic vote RPCs
-- =============================================================================

-- start_vote: creates a vote + pending vote_casts for all eligible members.
-- Used by app + by rule consequence executors that need to open a vote.

create or replace function public.start_vote(
  p_group_id          uuid,
  p_vote_type         text,
  p_reference_id      uuid,
  p_title             text,
  p_description       text default null,
  p_payload           jsonb default '{}'::jsonb,
  p_duration_hours    int   default null,    -- null = read from governance
  p_quorum_percent    int   default null,    -- null = read from governance
  p_threshold_percent int   default null,    -- null = read from governance
  p_is_anonymous      boolean default null   -- null = read from governance
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

  -- Find the caller's group_members row (vote creator must be a member)
  select id into v_creator_member_id
  from public.group_members
  where group_id = p_group_id
    and user_id  = v_caller_id
    and active   = true;

  if v_creator_member_id is null then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  -- Pull governance defaults
  select governance into v_governance from public.groups where id = p_group_id;

  v_duration  := coalesce(p_duration_hours,    (v_governance->>'votingDurationHours')::int,    72);
  v_quorum    := coalesce(p_quorum_percent,    (v_governance->>'votingQuorumPercent')::int,    50);
  v_threshold := coalesce(p_threshold_percent, (v_governance->>'votingThresholdPercent')::int, 50);
  v_anonymous := coalesce(p_is_anonymous,      (v_governance->>'votesAreAnonymous')::boolean,  true);

  -- Insert vote
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

  -- Create pending casts for all active members
  insert into public.vote_casts (vote_id, member_id, choice)
  select v_vote_id, gm.id, 'pending'
  from public.group_members gm
  where gm.group_id = p_group_id
    and gm.active   = true;

  -- Emit system event
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

comment on function public.start_vote is
  'Creates a vote + pending vote_casts for all active members. Reads governance defaults if duration/quorum/threshold/anonymous not provided.';

-- cast_vote: register/update caller's choice on an open vote.

create or replace function public.cast_vote(
  p_vote_id uuid,
  p_choice  text
)
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

  -- Lookup vote + group
  select status, group_id into v_vote_status, v_group_id
  from public.votes where id = p_vote_id;

  if v_vote_status is null then
    raise exception 'vote not found' using errcode = '02000';
  end if;
  if v_vote_status <> 'open' then
    raise exception 'vote is not open' using errcode = '22023';
  end if;

  -- Caller must be a member of the group
  select id into v_caller_member_id
  from public.group_members
  where group_id = v_group_id
    and user_id  = v_caller_id
    and active   = true;

  if v_caller_member_id is null then
    raise exception 'not eligible to vote' using errcode = '42501';
  end if;

  -- Update caster's row
  update public.vote_casts
  set choice  = p_choice,
      cast_at = now()
  where vote_id   = p_vote_id
    and member_id = v_caller_member_id;

  if not found then
    raise exception 'no ballot for this member on this vote' using errcode = '02000';
  end if;

  -- Emit system event
  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (
    v_group_id,
    'voteCast',
    p_vote_id,
    v_caller_member_id,
    jsonb_build_object('choice', p_choice)
  );
end;
$$;

comment on function public.cast_vote is
  'Records caller''s vote_cast choice on an open vote. Idempotent: re-cast updates the existing row.';

-- finalize_vote: closes the vote, computes resolution, emits resolved event.
-- Called by edge function (cron) when closes_at passes, or by RPC when all
-- members have voted.

create or replace function public.finalize_vote(p_vote_id uuid)
returns text  -- returns resolution: 'passed' | 'failed' | 'quorum_failed'
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
    -- Already resolved; return cached resolution from payload
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

  -- Emit system event
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

comment on function public.finalize_vote is
  'Closes vote, computes resolution (passed/failed/quorum_failed), updates counts, emits voteResolved event.';
