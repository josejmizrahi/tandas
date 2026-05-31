-- 00014 — Platform Foundation
--
-- Sprint 1a. Lays the generic platform layer (Resource, SystemEvent, Rule
-- with conditions/consequences, UserAction, Appeal) ALONGSIDE existing
-- event-specific tables. Dual-write activates in Sprint 1b/1c; the legacy
-- `events` table is dropped in a posterior sprint after paridad in prod.
--
-- DOES NOT MODIFY existing data. All current event flows keep working.

-- =============================================================================
-- 1. Generic resources envelope
-- =============================================================================

create table if not exists public.resources (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  resource_type text not null,
  status text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.resources is
  'Generic envelope for any platform resource (event, slot, fund, position, asset, contribution). Sprint 1b/1c starts populating; events live in legacy `events` table for now.';
comment on column public.resources.resource_type is
  'event | slot | fund | position | asset | contribution';

create index if not exists resources_group_type_idx
  on public.resources(group_id, resource_type);
create index if not exists resources_status_idx
  on public.resources(status);

create trigger resources_set_updated_at
  before update on public.resources
  for each row execute function public.set_updated_at();

-- events_view — projects existing events table back to a Resource shape so
-- Sprint 1a code can SELECT FROM events_view without knowing where the data
-- physically lives. In Sprint 1b/1c this becomes a UNION with `resources`
-- filtered to type='event'; eventually it reads only from `resources`.

create or replace view public.events_view as
select
  e.id                              as resource_id,
  'event'::text                     as resource_type,
  e.group_id,
  e.status,
  e.created_by,
  e.created_at,
  e.updated_at,
  jsonb_build_object(
    'title',                          e.title,
    'cover_image_name',               e.cover_image_name,
    'cover_image_url',                e.cover_image_url,
    'description',                    e.description,
    'starts_at',                      e.starts_at,
    'ends_at',                        e.ends_at,
    'duration_minutes',               e.duration_minutes,
    'location_name',                  e.location,
    'location_lat',                   e.location_lat,
    'location_lng',                   e.location_lng,
    'host_id',                        e.host_id,
    'cycle_number',                   e.cycle_number,
    'rsvp_deadline',                  e.rsvp_deadline,
    'rules_evaluated_at',             e.rules_evaluated_at,
    'notes',                          e.notes,
    'apply_rules',                    e.apply_rules,
    'is_recurring_generated',         e.is_recurring_generated,
    'parent_event_id',                e.parent_event_id,
    'auto_no_show_at',                e.auto_no_show_at,
    'closed_at',                      e.closed_at,
    'cancellation_reason',            e.cancellation_reason,
    'capacity_max',                   e.capacity_max,
    'allow_plus_ones',                e.allow_plus_ones,
    'max_plus_ones_per_member',       e.max_plus_ones_per_member
  )                                  as metadata
from public.events e;

comment on view public.events_view is
  'Resource-shaped projection of public.events. Sprint 1a alias only; Sprint 1b/1c will UNION with resources table.';

-- =============================================================================
-- 2. System events log — the rule engine's input stream
-- =============================================================================

create table if not exists public.system_events (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  event_type text not null,
  resource_id uuid,
  member_id uuid references public.group_members(id) on delete set null,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  processed_at timestamptz
);

comment on table public.system_events is
  'Append-only event log. The rule engine processes unprocessed events.';
comment on column public.system_events.event_type is
  'eventClosed | rsvpDeadlinePassed | checkInRecorded | checkInMissed | rsvpSubmitted | rsvpChangedSameDay | eventDescriptionMissing | eventCreated | slotAssigned | slotDeclined | slotExpired | fineOfficialized | finePaid | appealCreated | appealResolved | voteCast | fundDeposit | fundThresholdReached | positionChanged | memberJoined | memberLeft | hoursBeforeEvent (synthetic, scheduled by cron)';

create index if not exists system_events_unprocessed_idx
  on public.system_events(occurred_at)
  where processed_at is null;
create index if not exists system_events_group_type_idx
  on public.system_events(group_id, event_type);
create index if not exists system_events_resource_idx
  on public.system_events(resource_id)
  where resource_id is not null;

-- =============================================================================
-- 3. Rules — extend existing table with platform-shape columns
-- =============================================================================

alter table public.rules
  add column if not exists name text,
  add column if not exists is_active boolean not null default true,
  add column if not exists conditions jsonb not null default '[]'::jsonb,
  add column if not exists consequences jsonb not null default '[]'::jsonb;

comment on column public.rules.name is
  'Human-readable rule name. Sprint 1b populates from template defaults.';
comment on column public.rules.conditions is
  'Array of {type, config} — all evaluated with AND.';
comment on column public.rules.consequences is
  'Array of {type, config} — all executed when conditions match.';

-- Backfill `name` from existing `title` where missing (safe: title is text).
update public.rules set name = title where name is null;
update public.rules set is_active = enabled where is_active is null;

-- =============================================================================
-- 4. User actions — unified inbox queue
-- =============================================================================

create table if not exists public.user_actions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  group_id uuid not null references public.groups(id) on delete cascade,
  action_type text not null,
  reference_id uuid not null,
  title text not null,
  body text,
  priority text not null default 'medium',
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

comment on table public.user_actions is
  'Unified inbox row. Sprint 1c renders these as ActionCards in ActionInboxView.';
comment on column public.user_actions.action_type is
  'finePending | appealVotePending | rsvpPending | fineProposalReview | slotPending | votePending | contributionDue | compensationDue';
comment on column public.user_actions.priority is
  'low | medium | high | urgent';

create index if not exists user_actions_user_pending_idx
  on public.user_actions(user_id, created_at)
  where resolved_at is null;
create index if not exists user_actions_group_idx
  on public.user_actions(group_id);

-- =============================================================================
-- 5. Appeals + voting
-- =============================================================================

create table if not exists public.appeals (
  id uuid primary key default gen_random_uuid(),
  fine_id uuid not null references public.fines(id) on delete cascade,
  appellant_member_id uuid not null references public.group_members(id) on delete cascade,
  reason text not null,
  status text not null default 'voting',
  voting_started_at timestamptz not null default now(),
  voting_ends_at timestamptz not null,
  resolved_at timestamptz,
  vote_counts jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column public.appeals.status is
  'voting | resolved_in_favor | resolved_against | expired';

create index if not exists appeals_fine_idx on public.appeals(fine_id);
create index if not exists appeals_status_idx on public.appeals(status);

create trigger appeals_set_updated_at
  before update on public.appeals
  for each row execute function public.set_updated_at();

create table if not exists public.appeal_votes (
  id uuid primary key default gen_random_uuid(),
  appeal_id uuid not null references public.appeals(id) on delete cascade,
  member_id uuid not null references public.group_members(id) on delete cascade,
  choice text not null default 'pending',
  voted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(appeal_id, member_id)
);

comment on column public.appeal_votes.choice is
  'pending | in_favor | against | abstained';

create trigger appeal_votes_set_updated_at
  before update on public.appeal_votes
  for each row execute function public.set_updated_at();

-- Anonymized aggregate view — used by clients so individual ballots stay
-- private even with full table SELECT.
create or replace view public.appeal_vote_counts as
select
  appeal_id,
  count(*) filter (where choice = 'in_favor')  as in_favor,
  count(*) filter (where choice = 'against')   as against,
  count(*) filter (where choice = 'abstained') as abstained,
  count(*) filter (where choice = 'pending')   as pending,
  count(*)                                      as total_eligible
from public.appeal_votes
group by appeal_id;

-- =============================================================================
-- 6. Fine review periods — 24h grace window for host review
-- =============================================================================

create table if not exists public.fine_review_periods (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  proposed_at timestamptz not null default now(),
  expires_at timestamptz not null,
  officialized_at timestamptz,
  officialized_by uuid references public.group_members(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(event_id)
);

comment on table public.fine_review_periods is
  'Hybrid grace period — when an event closes, all proposed fines wait 24h for host review before auto-officializing.';

create index if not exists fine_review_periods_unexpired_idx
  on public.fine_review_periods(expires_at)
  where officialized_at is null;

-- =============================================================================
-- 7. RPCs — record_system_event + appeal lifecycle
-- =============================================================================

create or replace function public.record_system_event(
  p_group_id uuid,
  p_event_type text,
  p_resource_id uuid default null,
  p_member_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
begin
  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (p_group_id, p_event_type, p_resource_id, p_member_id, p_payload)
  returning id into v_event_id;
  return v_event_id;
end;
$$;

comment on function public.record_system_event is
  'Inserts a row into system_events. Caller is responsible for setting the right event_type. Sprint 1a Edge Function process-system-events picks it up.';

create or replace function public.start_appeal(
  p_fine_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appeal_id uuid;
  v_group_id uuid;
  v_appellant_member_id uuid;
  v_voting_hours int := 72;  -- default; future: read from group settings
  v_eligible_member_id uuid;
begin
  -- Resolve group + appellant
  select f.group_id, gm.id
    into v_group_id, v_appellant_member_id
    from public.fines f
    join public.group_members gm on gm.user_id = auth.uid() and gm.group_id = f.group_id
   where f.id = p_fine_id;

  if v_group_id is null then
    raise exception 'fine not found or appellant not a member';
  end if;

  -- Create appeal
  insert into public.appeals (fine_id, appellant_member_id, reason, voting_ends_at)
  values (p_fine_id, v_appellant_member_id, p_reason, now() + (v_voting_hours || ' hours')::interval)
  returning id into v_appeal_id;

  -- Seed pending votes for every active member except the appellant
  for v_eligible_member_id in
    select id from public.group_members
     where group_id = v_group_id
       and active = true
       and id <> v_appellant_member_id
  loop
    insert into public.appeal_votes (appeal_id, member_id, choice)
    values (v_appeal_id, v_eligible_member_id, 'pending')
    on conflict (appeal_id, member_id) do nothing;
  end loop;

  -- Emit system event
  perform public.record_system_event(
    v_group_id,
    'appealCreated',
    v_appeal_id,
    v_appellant_member_id,
    jsonb_build_object('fine_id', p_fine_id)
  );

  return v_appeal_id;
end;
$$;

create or replace function public.cast_appeal_vote(
  p_appeal_id uuid,
  p_choice text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
  v_group_id uuid;
begin
  if p_choice not in ('in_favor', 'against', 'abstained') then
    raise exception 'invalid choice: %', p_choice;
  end if;

  select gm.id, a.fine_id
    into v_member_id, v_group_id
    from public.appeals a
    join public.fines f on f.id = a.fine_id
    join public.group_members gm on gm.user_id = auth.uid() and gm.group_id = f.group_id
   where a.id = p_appeal_id;

  if v_member_id is null then
    raise exception 'appeal not found or voter not eligible';
  end if;

  update public.appeal_votes
     set choice = p_choice,
         voted_at = now()
   where appeal_id = p_appeal_id
     and member_id = v_member_id;

  if not found then
    raise exception 'voter is not in the eligible list for this appeal';
  end if;

  -- Resolve group_id from appeal for the system event
  select f.group_id into v_group_id
    from public.appeals a
    join public.fines f on f.id = a.fine_id
   where a.id = p_appeal_id;

  perform public.record_system_event(
    v_group_id,
    'voteCast',
    p_appeal_id,
    v_member_id,
    jsonb_build_object('choice', p_choice)
  );
end;
$$;

create or replace function public.close_appeal_vote(
  p_appeal_id uuid
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_in_favor int;
  v_against int;
  v_abstained int;
  v_pending int;
  v_total int;
  v_quorum_pct int := 50;
  v_threshold_pct int := 50;
  v_decisive int;
  v_outcome text;
  v_fine_id uuid;
  v_group_id uuid;
begin
  select in_favor, against, abstained, pending, total_eligible
    into v_in_favor, v_against, v_abstained, v_pending, v_total
    from public.appeal_vote_counts
   where appeal_id = p_appeal_id;

  if v_total is null then
    raise exception 'appeal has no eligible voters';
  end if;

  v_decisive := v_in_favor + v_against;

  -- Quorum: at least quorum_pct of eligible voted (not pending and not abstained)
  if (v_decisive::numeric / v_total) * 100 < v_quorum_pct then
    v_outcome := 'expired';
  elsif (v_in_favor::numeric / nullif(v_decisive, 0)) * 100 >= v_threshold_pct then
    v_outcome := 'resolved_in_favor';
  else
    v_outcome := 'resolved_against';
  end if;

  update public.appeals
     set status = v_outcome,
         resolved_at = now(),
         vote_counts = jsonb_build_object(
           'in_favor', v_in_favor,
           'against', v_against,
           'abstained', v_abstained,
           'pending', v_pending,
           'total_eligible', v_total
         )
   where id = p_appeal_id
   returning fine_id into v_fine_id;

  -- If appeal succeeded, void the fine
  if v_outcome = 'resolved_in_favor' then
    update public.fines set status = 'voided' where id = v_fine_id;
  end if;

  -- Emit system event
  select f.group_id into v_group_id from public.fines f where f.id = v_fine_id;
  perform public.record_system_event(
    v_group_id,
    'appealResolved',
    p_appeal_id,
    null,
    jsonb_build_object('outcome', v_outcome, 'fine_id', v_fine_id)
  );

  return v_outcome;
end;
$$;

-- =============================================================================
-- 8. RLS — appeals + appeal_votes + system_events + user_actions
-- =============================================================================

alter table public.resources         enable row level security;
alter table public.system_events     enable row level security;
alter table public.user_actions      enable row level security;
alter table public.appeals           enable row level security;
alter table public.appeal_votes      enable row level security;
alter table public.fine_review_periods enable row level security;

-- resources: members can read their group's resources
create policy "resources_read_member"
  on public.resources for select
  using (
    exists (
      select 1 from public.group_members gm
       where gm.group_id = resources.group_id
         and gm.user_id = auth.uid()
         and gm.active = true
    )
  );

-- system_events: members can read their group's events; only service role inserts
create policy "system_events_read_member"
  on public.system_events for select
  using (
    exists (
      select 1 from public.group_members gm
       where gm.group_id = system_events.group_id
         and gm.user_id = auth.uid()
         and gm.active = true
    )
  );

-- user_actions: only the targeted user can read their own
create policy "user_actions_read_own"
  on public.user_actions for select
  using (user_id = auth.uid());
create policy "user_actions_update_own"
  on public.user_actions for update
  using (user_id = auth.uid());

-- appeals: members of the fine's group can read; only RPC inserts
create policy "appeals_read_member"
  on public.appeals for select
  using (
    exists (
      select 1
        from public.fines f
        join public.group_members gm on gm.group_id = f.group_id
       where f.id = appeals.fine_id
         and gm.user_id = auth.uid()
         and gm.active = true
    )
  );

-- appeal_votes: a voter can read THEIR OWN ballot (for UI state). Aggregates
-- via the appeal_vote_counts view are public to group members.
create policy "appeal_votes_read_own_or_aggregate"
  on public.appeal_votes for select
  using (
    member_id in (
      select id from public.group_members
       where user_id = auth.uid()
    )
  );

-- fine_review_periods: members of the event's group
create policy "fine_review_periods_read_member"
  on public.fine_review_periods for select
  using (
    exists (
      select 1
        from public.events e
        join public.group_members gm on gm.group_id = e.group_id
       where e.id = fine_review_periods.event_id
         and gm.user_id = auth.uid()
         and gm.active = true
    )
  );

-- =============================================================================
-- 9. Grants
-- =============================================================================

grant execute on function public.record_system_event(uuid, text, uuid, uuid, jsonb) to authenticated, service_role;
grant execute on function public.start_appeal(uuid, text) to authenticated;
grant execute on function public.cast_appeal_vote(uuid, text) to authenticated;
grant execute on function public.close_appeal_vote(uuid) to service_role;

grant select on public.events_view to authenticated;
grant select on public.appeal_vote_counts to authenticated;
