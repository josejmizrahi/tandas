-- 00126 — events.series_id + recurrence runtime state on resource_series.
--
-- Background
-- ==========
-- Tier 1 (recurrence end-to-end): the catalog already exposes a
-- `recurrence` capability, build_resource_from_draft (mig 00101) writes
-- the `resource_series.pattern` jsonb from the wizard's draft, and the
-- atom-shape `resources.series_id` (mig 00078) points each occurrence
-- back at its series. But the cohabiting `events` table has no
-- series_id column, so:
--
--   1. create_event_v2 cannot record which series an occurrence
--      belongs to (it accepts no p_series_id).
--   2. The dual-write trigger 00039 (events → resources) sets
--      resources.series_id = NULL even when the caller knows the series.
--   3. The auto-generate-events cron has no way to scope its scan by
--      series ("how many future occurrences of series X exist?") so it
--      falls back to the dropped legacy groups.frequency_type columns.
--
-- Audit 2026-05-12 marked recurrence `.incomplete` in the iOS catalog
-- because of these three gaps. This migration closes #1 (column +
-- index) and #2 (trigger sync). Tier 1.5 rewrites auto-generate-events
-- to consume the new state.
--
-- Changes
-- =======
-- 1. events.series_id uuid → resource_series.id, nullable. ON DELETE
--    SET NULL so dropping a series leaves orphan occurrences instead
--    of cascading (mirrors resources.series_id ON DELETE SET NULL in
--    00078:222).
-- 2. Indices:
--    - idx_events_series           = lookup-by-series.
--    - uniq_events_series_starts_at = idempotency for the generator —
--      same (series, starts_at) cannot exist twice, so re-running the
--      cron is a no-op (ON CONFLICT DO NOTHING).
-- 3. resource_series.generated_until timestamptz — runtime state the
--    generator updates to the latest scheduled timestamp it produced.
--    Lets the next run pick up where the previous left off without
--    re-scanning every series for its full history. Null = "never
--    generated" → start from pattern.startDate.
-- 4. sync_event_to_resource trigger function updated to copy series_id
--    so resources.series_id stays in sync. Existing UPSERT shape kept.
-- 5. create_event_v2 gets a `p_series_id` parameter (default null).
--    Backwards compatible — callers that don't pass it get the old
--    behavior (one-off event).
--
-- Idempotent
-- ==========
-- `add column if not exists`, `create index if not exists`,
-- `create or replace function`. Re-applying is a no-op.

-- =============================================================================
-- 1. events.series_id column
-- =============================================================================

alter table public.events
  add column if not exists series_id uuid null
    references public.resource_series(id) on delete set null;

comment on column public.events.series_id is
  'Recurrence link: when this event is an occurrence generated from a ResourceSeries, points to the series. Null for one-off events. The dual-write trigger 00126 copies this to resources.series_id.';

-- =============================================================================
-- 2. Indices
-- =============================================================================

create index if not exists idx_events_series
  on public.events(series_id)
  where series_id is not null;

-- Idempotency: the generator computes occurrence timestamps
-- deterministically from pattern + last generated. Re-running the cron
-- on the same series must NOT produce duplicates. A unique partial
-- index on (series_id, starts_at) is the contract; ON CONFLICT DO
-- NOTHING in the RPC honors it.
create unique index if not exists uniq_events_series_starts_at
  on public.events(series_id, starts_at)
  where series_id is not null;

-- =============================================================================
-- 3. resource_series.generated_until
-- =============================================================================

alter table public.resource_series
  add column if not exists generated_until timestamptz null;

comment on column public.resource_series.generated_until is
  'Runtime state: the latest `starts_at` the auto-generate-events cron has produced for this series. Null = never generated. Cron scan condition: generated_until IS NULL OR generated_until < (now + horizon).';

-- =============================================================================
-- 4. sync_event_to_resource — mirror series_id
-- =============================================================================

create or replace function public.sync_event_to_resource()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'DELETE' then
    delete from public.resources where id = OLD.id;
    return OLD;
  end if;

  insert into public.resources (
    id, group_id, resource_type, status, metadata,
    series_id,
    created_by, created_at, updated_at
  ) values (
    NEW.id,
    NEW.group_id,
    'event',
    NEW.status,
    jsonb_build_object(
      'title',                      NEW.title,
      'cover_image_name',           NEW.cover_image_name,
      'cover_image_url',            NEW.cover_image_url,
      'description',                NEW.description,
      'starts_at',                  NEW.starts_at,
      'ends_at',                    NEW.ends_at,
      'duration_minutes',           NEW.duration_minutes,
      'location_name',              NEW.location,
      'location_lat',               NEW.location_lat,
      'location_lng',               NEW.location_lng,
      'host_id',                    NEW.host_id,
      'cycle_number',               NEW.cycle_number,
      'rsvp_deadline',              NEW.rsvp_deadline,
      'rules_evaluated_at',         NEW.rules_evaluated_at,
      'notes',                      NEW.notes,
      'apply_rules',                NEW.apply_rules,
      'is_recurring_generated',     NEW.is_recurring_generated,
      'parent_event_id',            NEW.parent_event_id,
      'auto_no_show_at',            NEW.auto_no_show_at,
      'closed_at',                  NEW.closed_at,
      'cancellation_reason',        NEW.cancellation_reason,
      'capacity_max',               NEW.capacity_max,
      'allow_plus_ones',            NEW.allow_plus_ones,
      'max_plus_ones_per_member',   NEW.max_plus_ones_per_member
    ),
    NEW.series_id,
    NEW.created_by,
    NEW.created_at,
    NEW.updated_at
  )
  on conflict (id) do update
  set group_id      = excluded.group_id,
      resource_type = excluded.resource_type,
      status        = excluded.status,
      metadata      = excluded.metadata,
      series_id     = excluded.series_id,
      updated_at    = excluded.updated_at;

  return NEW;
end;
$$;

comment on function public.sync_event_to_resource() is
  'Dual-write trigger: mirrors INSERT/UPDATE/DELETE on events into resources. resources.id = events.id; resources.series_id = events.series_id (post-00126 for recurrence E2E).';

-- The trigger itself is unchanged (still AFTER INSERT OR UPDATE OR DELETE
-- on events), so we don't need to drop+recreate. The CREATE OR REPLACE
-- on the function above is sufficient — Postgres re-binds existing
-- triggers to the new function body.

-- =============================================================================
-- 5. create_event_v2 — accept p_series_id
-- =============================================================================
--
-- Drop the 13-parameter signature from 00097 before creating the new
-- 15-parameter one. Without this, Postgres treats them as separate
-- overloads (sig matched by param types) and any call with default
-- args raises "function name is not unique" — local supabase CI hit
-- this on fresh apply once the 00011 rollback PK conflict was fixed.
-- All callers (iOS LiveEventRepository, e2e tests) use keyword args,
-- so dropping the 13-param overload is safe.
drop function if exists public.create_event_v2(
  uuid,                       -- p_group_id
  text,                       -- p_title
  timestamp with time zone,   -- p_starts_at
  integer,                    -- p_duration_minutes
  text,                       -- p_location_name
  numeric,                    -- p_location_lat
  numeric,                    -- p_location_lng
  uuid,                       -- p_host_id
  text,                       -- p_cover_image_name
  text,                       -- p_cover_image_url
  text,                       -- p_description
  boolean,                    -- p_apply_rules
  boolean                     -- p_is_recurring_generated
);

create or replace function public.create_event_v2(
  p_group_id              uuid,
  p_title                 text,
  p_starts_at             timestamp with time zone,
  p_duration_minutes      integer default 180,
  p_location_name         text default null,
  p_location_lat          numeric default null,
  p_location_lng          numeric default null,
  p_host_id               uuid default null,
  p_cover_image_name      text default null,
  p_cover_image_url       text default null,
  p_description           text default null,
  p_apply_rules           boolean default true,
  p_is_recurring_generated boolean default false,
  p_series_id             uuid default null,
  p_rsvp_deadline         timestamp with time zone default null
) returns public.events
language plpgsql security definer set search_path = public as $$
declare
  e               public.events;
  g               public.groups;
  v_cycle         int;
  v_host          uuid;
  v_ends_at       timestamptz;
  v_rotation_on   boolean;
  v_rsvp_deadline timestamptz;
begin
  -- Membership gate. Service-role callers (auth.uid() IS NULL) bypass:
  -- this covers cron paths like auto-generate-events (post-Tier-1.5)
  -- that call create_event_v2 to materialize recurrence occurrences,
  -- and any future system-level event creation. The function stays
  -- SECURITY DEFINER but trusts the service_role JWT only for the
  -- membership-gate skip; everything downstream (cycle_number, host
  -- selection, rsvp_deadline, ON CONFLICT idempotency) is identical.
  if auth.uid() is not null
     and not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'forbidden: not a member of group';
  end if;

  select * into g from public.groups where id = p_group_id;
  if not found then
    raise exception 'group not found';
  end if;

  -- If a series was supplied, validate it belongs to the same group.
  -- Prevents a caller from linking an occurrence to a series in a
  -- different group via a forged p_series_id.
  if p_series_id is not null then
    if not exists (
      select 1 from public.resource_series
       where id = p_series_id and group_id = p_group_id
    ) then
      raise exception 'series % not found in group %', p_series_id, p_group_id;
    end if;
  end if;

  v_cycle := coalesce(
    (select max(cycle_number) from public.events where group_id = p_group_id),
    0
  ) + 1;

  v_rotation_on := coalesce(
    (select 'rotating_host' = any (
       select jsonb_array_elements_text(g.active_modules)
     )),
    false
  );

  v_host := coalesce(
    p_host_id,
    case when v_rotation_on
         then public.next_host_for_group(p_group_id, v_cycle)
         else null
    end,
    auth.uid()
  );

  v_ends_at := p_starts_at + make_interval(mins => coalesce(p_duration_minutes, 180));

  -- RSVP deadline: explicit p_rsvp_deadline wins, else starts_at - 4h
  -- legacy default. New Tier 1.1 contract: the wizard passes the
  -- deadline as an absolute timestamp (resolved from capability config
  -- on the iOS side), so the cron-driven generator can pass per-series
  -- deadlines instead of hardcoded T-4h.
  v_rsvp_deadline := coalesce(p_rsvp_deadline, p_starts_at - interval '4 hours');

  -- ON CONFLICT (series_id, starts_at) DO NOTHING enforces idempotency
  -- for the cron generator. Without a series_id, the partial unique
  -- index doesn't apply and the INSERT proceeds normally for one-off
  -- events. RETURNING * INTO e populates only on actual insert; the
  -- caller checks FOUND for the no-op case below.
  insert into public.events (
    group_id, title, starts_at, ends_at, location, location_lat, location_lng,
    host_id, cycle_number, rsvp_deadline, cover_image_name, cover_image_url,
    description, apply_rules, is_recurring_generated, duration_minutes,
    series_id, created_by
  ) values (
    p_group_id, p_title, p_starts_at, v_ends_at,
    p_location_name, p_location_lat, p_location_lng,
    v_host, v_cycle, v_rsvp_deadline,
    p_cover_image_name, p_cover_image_url, p_description,
    coalesce(p_apply_rules, true), coalesce(p_is_recurring_generated, false),
    coalesce(p_duration_minutes, 180),
    p_series_id, auth.uid()
  )
  on conflict (series_id, starts_at) where series_id is not null do nothing
  returning * into e;

  -- ON CONFLICT skipped the insert. Return the existing row so the
  -- caller sees a normal result (idempotent re-run shouldn't fail).
  if not found then
    select * into e from public.events
     where series_id = p_series_id and starts_at = p_starts_at
     limit 1;
    if not found then
      raise exception 'create_event_v2 race: conflict reported but row not found';
    end if;
    -- Skip downstream seeding (attendance, eventCreated event_attendance)
    -- since the row already exists. Caller already saw all that.
    return e;
  end if;

  insert into public.event_attendance (event_id, user_id)
    select e.id, gm.user_id
      from public.group_members gm
     where gm.group_id = p_group_id and gm.active
    on conflict do nothing;

  perform public.record_system_event(
    p_group_id,
    'eventCreated',
    e.id,
    null,
    jsonb_build_object(
      'title',     e.title,
      'starts_at', e.starts_at,
      'host_id',   e.host_id,
      'series_id', e.series_id
    )
  );

  return e;
end;
$$;

comment on function public.create_event_v2(
  uuid, text, timestamp with time zone, integer, text, numeric, numeric,
  uuid, text, text, text, boolean, boolean, uuid, timestamp with time zone
) is
  'Event creation post-BigBang. v3 (00126): accepts p_series_id (recurrence link) and p_rsvp_deadline (explicit override of legacy starts_at - 4h). Idempotent on (series_id, starts_at) for cron-generated occurrences. Emits eventCreated to system_events (00097) including series_id.';
