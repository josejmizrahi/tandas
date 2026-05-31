-- 00158 — V2 writer RPCs write resources/atoms directly; events table
-- becomes a writer-less shadow ready to drop in 00159.
--
-- Constitution §14 step 5c-iii.C (full writer refactor) + step 5c-iv prep.
--
-- What changes
-- ============
-- Before: V2 RPCs (create_event_v2, set_rsvp_v2, check_in_v2, cancel_event,
-- close_event, close_event_no_fines) INSERTed/UPDATEd public.events and
-- public.event_attendance. The events_sync_to_resources trigger (mig
-- 00039) mirrored every events write into public.resources. Triggers on
-- the legacy tables (host_assigned, cancel_cascade, set_auto_no_show,
-- emit_rsvp_action, emit_check_in_action, on_event_attendance_rsvp_action)
-- ran the side-effects.
--
-- After: the V2 RPCs INSERT/UPDATE public.resources and the atom tables
-- (rsvp_actions / check_in_actions) directly. The legacy tables receive
-- no writes (and stay alive only as a defensive shadow for 5c-iv to
-- DROP). The dual-write trigger is dropped. Side-effect triggers are
-- re-implemented on the resources / atom tables.
--
-- Return-type compat: RPCs that previously RETURNed public.events now
-- RETURN public.events_view (the drop-in view from mig 00156 with every
-- legacy column). iOS / TS callers decode the JSON body unchanged because
-- column names match. Same for public.event_attendance → public.attendance_view.
--
-- Drop list
-- =========
-- - roll_event_series, evaluate_event_rules: legacy V1, only close_event
--   called them. New close_event drops the calls (rule engine handles
--   fines via the eventClosed system_event).
-- - check_in_attendee: V1, only e2e tests called it (those will need to
--   switch to check_in_v2 in a follow-up).
-- - on_event_inserted_host_assigned, on_event_cancelled_resolve_actions,
--   events_set_auto_no_show_at, events_sync_to_resources triggers.
-- - trg_emit_rsvp_action, trg_emit_check_in_action,
--   trg_on_event_attendance_rsvp_action triggers on event_attendance.
--
-- New triggers
-- ============
-- - on_resource_event_inserted: AFTER INSERT on resources, fires for
--   resource_type=event. Stamps metadata.auto_no_show_at (was the
--   events_set_auto_no_show_at trigger) and emits hostAssigned
--   user_action when metadata.host_id is set and != created_by.
-- - on_resource_event_cancelled: AFTER UPDATE OF status on resources,
--   fires when an event resource flips to 'cancelled' and resolves the
--   dependent inbox rows (hostAssigned, fineProposalReview, rsvpPending).
-- - on_rsvp_action_inserted: AFTER INSERT on rsvp_actions, runs the
--   inbox logic previously in trg_on_event_attendance_rsvp_action —
--   creates rsvpPending nudge for the initial 'pending' atom of a
--   non-host member, and resolves the nudge when status transitions
--   out of 'pending'.
--
-- Helpers kept (rewritten)
-- ========================
-- - event_seat_count(p_resource_id uuid): now reads attendance_view.
-- - next_event_for_group(p_group_id uuid): now reads resources directly.
-- - promote_from_waitlist(p_resource_id uuid): now reads attendance_view +
--   emits rsvp_actions atom.
-- - close_event_no_fines(p_resource_id uuid): now UPDATEs resources.

-- =============================================================================
-- Part 1. Drop legacy V1 helpers that close_event called
-- =============================================================================

drop function if exists public.roll_event_series(uuid);
drop function if exists public.evaluate_event_rules(uuid);
drop function if exists public.check_in_attendee(uuid, uuid, timestamp with time zone);

-- =============================================================================
-- Part 2. Drop the V2 RPCs (will recreate with new return types + bodies)
-- =============================================================================
-- DROP needed because we change RETURNS public.events → public.events_view
-- (and same for event_attendance → attendance_view). CREATE OR REPLACE
-- can't change the return type.

drop function if exists public.cancel_event(uuid, text);
drop function if exists public.close_event(uuid);
drop function if exists public.close_event_no_fines(uuid);
drop function if exists public.create_event_v2(
  uuid, text, timestamp with time zone, integer, text, numeric, numeric,
  uuid, text, text, text, boolean, boolean, uuid, timestamp with time zone
);
drop function if exists public.set_rsvp_v2(uuid, text, integer, text);
drop function if exists public.check_in_v2(
  uuid, uuid, text, boolean, timestamp with time zone
);
drop function if exists public.event_seat_count(uuid);
drop function if exists public.next_event_for_group(uuid);
drop function if exists public.promote_from_waitlist(uuid);

-- =============================================================================
-- Part 3. Drop legacy triggers on events / event_attendance
-- =============================================================================
-- All side-effects move to resources / atom tables in Part 4.

drop trigger if exists events_set_auto_no_show_at        on public.events;
drop trigger if exists trg_on_event_inserted_host_assigned on public.events;
drop trigger if exists trg_on_event_cancelled_resolve_actions on public.events;
drop trigger if exists events_sync_to_resources          on public.events;
-- events_set_updated_at is harmless to keep (won't fire — no writes) but
-- we drop it for hygiene; the events table goes away in 00159 anyway.
drop trigger if exists events_set_updated_at             on public.events;

drop trigger if exists trg_emit_rsvp_action              on public.event_attendance;
drop trigger if exists trg_emit_check_in_action          on public.event_attendance;
drop trigger if exists trg_on_event_attendance_rsvp_action on public.event_attendance;

-- Drop the now-orphan trigger functions (no consumers in this DB).
drop function if exists public.sync_event_to_resource();
drop function if exists public.set_auto_no_show_at();
drop function if exists public.on_event_inserted_host_assigned();
drop function if exists public.on_event_cancelled_resolve_actions();
drop function if exists public.emit_rsvp_action_from_attendance();
drop function if exists public.emit_check_in_action_from_attendance();
drop function if exists public.on_event_attendance_rsvp_action();

-- =============================================================================
-- Part 4. New triggers on resources / atom tables
-- =============================================================================

-- 4a. Stamp auto_no_show_at + emit hostAssigned on event-resource insert.
create or replace function public.on_resource_event_inserted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host_id    uuid;
  v_starts_at  timestamptz;
  v_tz         text;
  v_title      text;
begin
  if NEW.resource_type <> 'event' then return NEW; end if;

  v_host_id   := (NEW.metadata->>'host_id')::uuid;
  v_starts_at := (NEW.metadata->>'starts_at')::timestamptz;
  v_title     := NEW.metadata->>'title';

  -- Host inbox nudge: matches the legacy on_event_inserted_host_assigned
  -- shape from mig 00133/00143.
  if v_host_id is not null
     and (NEW.created_by is null or v_host_id <> NEW.created_by) then
    select nullif(trim(coalesce(timezone, '')), '')
      into v_tz
      from public.groups
     where id = NEW.group_id;
    v_tz := coalesce(v_tz, 'America/Mexico_City');

    insert into public.user_actions (
      user_id, group_id, action_type, reference_id, title, body, priority
    ) values (
      v_host_id,
      NEW.group_id,
      'hostAssigned',
      NEW.id,
      'Te toca ser anfitrión',
      coalesce(v_title, 'Evento') || ' — ' || to_char(v_starts_at at time zone v_tz, 'DD Mon YYYY'),
      'medium'
    );
  end if;

  return NEW;
end;
$$;

drop trigger if exists trg_on_resource_event_inserted on public.resources;
create trigger trg_on_resource_event_inserted
  after insert on public.resources
  for each row execute function public.on_resource_event_inserted();

comment on function public.on_resource_event_inserted() is
  'Constitution §14 step 5c-iii.C: side-effects on event-resource INSERT (host inbox nudge). Replaces the legacy on_event_inserted_host_assigned trigger that fired on public.events.';

-- 4b. Resolve dependent inbox rows when an event resource is cancelled.
create or replace function public.on_resource_event_cancelled()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.resource_type <> 'event' then return NEW; end if;
  if NEW.status <> 'cancelled' then return NEW; end if;
  if OLD.status is not null and OLD.status = 'cancelled' then return NEW; end if;

  update public.user_actions
     set resolved_at = now()
   where reference_id = NEW.id
     and resolved_at  is null
     and action_type in ('hostAssigned', 'fineProposalReview', 'rsvpPending');

  return NEW;
end;
$$;

drop trigger if exists trg_on_resource_event_cancelled on public.resources;
create trigger trg_on_resource_event_cancelled
  after update of status on public.resources
  for each row execute function public.on_resource_event_cancelled();

comment on function public.on_resource_event_cancelled() is
  'Constitution §14 step 5c-iii.C: resolves hostAssigned / fineProposalReview / rsvpPending user_actions when an event resource flips to cancelled. Replaces the legacy on_event_cancelled_resolve_actions trigger on public.events.';

-- 4c. Inbox lifecycle from rsvp_actions atoms.
-- Replaces trg_on_event_attendance_rsvp_action (mig 00145) which keyed
-- off the legacy event_attendance UPSERT lifecycle. New keying: every
-- INSERT into rsvp_actions either spawns a nudge (initial 'pending' for
-- a non-host) or resolves one (atom with non-pending status replaces
-- the pending nudge for the same (resource, member)).
create or replace function public.on_rsvp_action_inserted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource    public.resources;
  v_user_id     uuid;
  v_host_id     uuid;
  v_event_title text;
  v_prev_atom_count int;
begin
  select * into v_resource from public.resources where id = NEW.resource_id;
  if v_resource.id is null or v_resource.resource_type <> 'event' then
    return NEW;
  end if;

  select user_id into v_user_id from public.group_members where id = NEW.member_id;
  if v_user_id is null then return NEW; end if;

  v_host_id     := (v_resource.metadata->>'host_id')::uuid;
  v_event_title := v_resource.metadata->>'title';

  -- Initial 'pending' atom (the only one for the (resource, member)
  -- pair) → spawn the inbox nudge, unless the member is the host.
  if NEW.status = 'pending' then
    select count(*) into v_prev_atom_count
      from public.rsvp_actions
     where resource_id = NEW.resource_id
       and member_id   = NEW.member_id
       and id <> NEW.id;
    if v_prev_atom_count = 0
       and (v_host_id is null or v_host_id <> v_user_id) then
      insert into public.user_actions (
        user_id, group_id, action_type, reference_id,
        title, body, priority
      ) values (
        v_user_id,
        v_resource.group_id,
        'rsvpPending',
        NEW.resource_id,
        '¿Vas a ' || coalesce(nullif(trim(v_event_title), ''), 'el evento') || '?',
        'Confirma tu asistencia.',
        'medium'
      );
    end if;
    return NEW;
  end if;

  -- Non-pending atom → resolve the standing nudge if any.
  update public.user_actions
     set resolved_at = now()
   where user_id      = v_user_id
     and reference_id = NEW.resource_id
     and action_type  = 'rsvpPending'
     and resolved_at  is null;

  return NEW;
end;
$$;

drop trigger if exists trg_on_rsvp_action_inserted on public.rsvp_actions;
create trigger trg_on_rsvp_action_inserted
  after insert on public.rsvp_actions
  for each row execute function public.on_rsvp_action_inserted();

comment on function public.on_rsvp_action_inserted() is
  'Constitution §14 step 5c-iii.C: inbox lifecycle (rsvpPending nudge spawn + resolve) driven by rsvp_actions atoms. Replaces the legacy trg_on_event_attendance_rsvp_action trigger.';

-- =============================================================================
-- Part 5. Helper RPCs rewritten over the resources/atoms primitives
-- =============================================================================

-- 5a. event_seat_count: count 1+plus_ones for members whose latest
-- rsvp_action status is 'going'.
create function public.event_seat_count(p_resource_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(1 + plus_ones), 0)::int
    from public.attendance_view
   where resource_id = p_resource_id
     and rsvp_status = 'going';
$$;

comment on function public.event_seat_count(uuid) is
  'Reads attendance_view for the latest-per-member RSVP. §14 step 5c-iii.C: switched from event_attendance to atom-derived projection.';

-- 5b. next_event_for_group: next scheduled event for a group.
create function public.next_event_for_group(p_group_id uuid)
returns public.events_view
language sql
stable
security definer
set search_path = public
as $$
  select * from public.events_view
   where group_id = p_group_id
     and status   = 'scheduled'
     and starts_at >= now()
   order by starts_at asc
   limit 1;
$$;

comment on function public.next_event_for_group(uuid) is
  '§14 step 5c-iii.C: reads events_view (resources projection); returns events_view row.';

-- 5c. promote_from_waitlist: pick the next waitlisted member, emit an
-- rsvp_action atom with status='going'.
create function public.promote_from_waitlist(p_resource_id uuid)
returns public.attendance_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource    public.resources;
  v_uid         uuid := auth.uid();
  v_host_id     uuid;
  v_next        public.attendance_view;
  v_capacity    int;
  v_taken       int;
  v_needed      int;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  select * into v_resource from public.resources where id = p_resource_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  v_host_id := (v_resource.metadata->>'host_id')::uuid;
  if not (public.is_group_admin(v_resource.group_id, v_uid) or v_host_id = v_uid) then
    raise exception 'host or admin only';
  end if;

  select * into v_next
    from public.attendance_view
   where resource_id = p_resource_id
     and rsvp_status = 'waitlisted'
   order by waitlist_position asc nulls last, rsvp_at asc
   limit 1;
  if v_next.member_id is null then raise exception 'no one on waitlist'; end if;

  v_capacity := (v_resource.metadata->>'capacity_max')::int;
  v_taken := public.event_seat_count(p_resource_id);
  v_needed := 1 + coalesce(v_next.plus_ones, 0);
  if v_capacity is not null and (v_taken + v_needed) > v_capacity then
    raise exception 'not enough capacity to promote';
  end if;

  insert into public.rsvp_actions (
    resource_id, member_id, status, recorded_at, metadata
  ) values (
    p_resource_id,
    v_next.member_id,
    'going',
    now(),
    jsonb_strip_nulls(jsonb_build_object(
      'plus_ones',         v_next.plus_ones,
      'waitlist_position', null,
      'via',               'promote_from_waitlist'
    ))
  );

  select * into v_next from public.attendance_view
   where resource_id = p_resource_id and member_id = v_next.member_id;
  return v_next;
end;
$$;

comment on function public.promote_from_waitlist(uuid) is
  '§14 step 5c-iii.C: emits an rsvp_actions atom (status=going) instead of UPDATing event_attendance.';

-- =============================================================================
-- Part 6. Refactored V2 writer RPCs
-- =============================================================================

-- 6a. create_event_v2: INSERT into resources + INSERT rsvp_actions per
-- active member. Returns the events_view row of the new resource.
create function public.create_event_v2(
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
)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  g                   public.groups;
  v_new_id            uuid;
  v_cycle             int;
  v_host              uuid;
  v_ends_at           timestamptz;
  v_rotation_on       boolean;
  v_rsvp_deadline     timestamptz;
  v_auto_no_show_at   timestamptz;
  v_metadata          jsonb;
  v_view_row          public.events_view;
begin
  if auth.uid() is not null
     and not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'forbidden: not a member of group';
  end if;

  select * into g from public.groups where id = p_group_id;
  if not found then raise exception 'group not found'; end if;

  if p_series_id is not null then
    if not exists (
      select 1 from public.resource_series
       where id = p_series_id and group_id = p_group_id
    ) then
      raise exception 'series % not found in group %', p_series_id, p_group_id;
    end if;
  end if;

  -- Idempotency on (series_id, starts_at): if a row already exists,
  -- return it without re-creating. The unique index was on the events
  -- table (mig 00126); replicated here as an explicit SELECT.
  if p_series_id is not null then
    select * into v_view_row from public.events_view
     where series_id = p_series_id and starts_at = p_starts_at
     limit 1;
    if v_view_row.id is not null then return v_view_row; end if;
  end if;

  v_cycle := coalesce(
    (select max((metadata->>'cycle_number')::int) from public.resources where group_id = p_group_id and resource_type='event'),
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
  v_rsvp_deadline := coalesce(p_rsvp_deadline, p_starts_at - interval '4 hours');
  v_auto_no_show_at := p_starts_at + interval '60 minutes';

  v_metadata := jsonb_strip_nulls(jsonb_build_object(
    'title',                    p_title,
    'cover_image_name',         p_cover_image_name,
    'cover_image_url',          p_cover_image_url,
    'description',              p_description,
    'starts_at',                p_starts_at,
    'ends_at',                  v_ends_at,
    'duration_minutes',         coalesce(p_duration_minutes, 180),
    'location_name',            p_location_name,
    'location_lat',             p_location_lat,
    'location_lng',             p_location_lng,
    'host_id',                  v_host,
    'cycle_number',             v_cycle,
    'rsvp_deadline',            v_rsvp_deadline,
    'apply_rules',              coalesce(p_apply_rules, true),
    'is_recurring_generated',   coalesce(p_is_recurring_generated, false),
    'auto_no_show_at',          v_auto_no_show_at,
    'allow_plus_ones',          false,
    'max_plus_ones_per_member', 0
  ));

  insert into public.resources (
    group_id, resource_type, status, metadata, series_id, created_by
  ) values (
    p_group_id, 'event', 'scheduled', v_metadata, p_series_id, auth.uid()
  )
  returning id into v_new_id;

  -- Materialize pending rsvp_actions for each active member. The
  -- on_rsvp_action_inserted trigger fires the inbox nudges.
  insert into public.rsvp_actions (resource_id, member_id, status, recorded_at, metadata)
  select v_new_id, gm.id, 'pending', now(),
         jsonb_build_object('via', 'create_event_v2', 'plus_ones', 0)
    from public.group_members gm
   where gm.group_id = p_group_id and gm.active;

  perform public.record_system_event(
    p_group_id,
    'eventCreated',
    v_new_id,
    null,
    jsonb_build_object(
      'title',     p_title,
      'starts_at', p_starts_at,
      'host_id',   v_host,
      'series_id', p_series_id
    )
  );

  select * into v_view_row from public.events_view where id = v_new_id;
  return v_view_row;
end;
$$;

comment on function public.create_event_v2(
  uuid, text, timestamp with time zone, integer, text, numeric, numeric,
  uuid, text, text, text, boolean, boolean, uuid, timestamp with time zone
) is
  '§14 step 5c-iii.C: writes resources + rsvp_actions directly. Returns events_view row (drop-in for legacy events row shape).';

-- 6b. set_rsvp_v2: emit an rsvp_actions atom. Capacity / waitlist
-- handled inline.
create function public.set_rsvp_v2(
  p_event_id   uuid,
  p_status     text,
  p_plus_ones  integer default 0,
  p_reason     text default null
)
returns public.attendance_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource           public.resources;
  v_uid                uuid := auth.uid();
  v_member_id          uuid;
  v_seats_taken        int;
  v_max_plus_ones      int;
  v_capacity_max       int;
  v_allow_plus_ones    boolean;
  v_effective_status   text := p_status;
  v_next_position      int;
  v_my_existing        int := 0;
  v_view_row           public.attendance_view;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  if p_status not in ('pending','going','maybe','declined') then
    raise exception 'invalid rsvp_status: %', p_status;
  end if;
  if p_plus_ones < 0 then raise exception 'plus_ones must be >= 0'; end if;

  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  if not public.is_group_member(v_resource.group_id, v_uid) then
    raise exception 'not a member';
  end if;

  v_allow_plus_ones := coalesce((v_resource.metadata->>'allow_plus_ones')::boolean, false);
  v_max_plus_ones   := coalesce((v_resource.metadata->>'max_plus_ones_per_member')::int, 0);
  v_capacity_max    := (v_resource.metadata->>'capacity_max')::int;

  if p_plus_ones > 0 then
    if not v_allow_plus_ones then raise exception 'plus_ones not allowed'; end if;
    if p_plus_ones > v_max_plus_ones then
      raise exception 'plus_ones exceeds max % per member', v_max_plus_ones;
    end if;
  end if;

  select id into v_member_id from public.group_members
   where group_id = v_resource.group_id and user_id = v_uid limit 1;
  if v_member_id is null then raise exception 'membership not found'; end if;

  -- Capacity check / waitlist conversion (matches the legacy logic).
  if p_status = 'going' and v_capacity_max is not null then
    v_seats_taken := public.event_seat_count(p_event_id);
    select coalesce(1 + plus_ones, 0) into v_my_existing
      from public.attendance_view
     where resource_id = p_event_id and member_id = v_member_id and rsvp_status = 'going';
    if v_my_existing is null then v_my_existing := 0; end if;
    v_seats_taken := v_seats_taken - v_my_existing;
    if (v_seats_taken + 1 + p_plus_ones) > v_capacity_max then
      v_effective_status := 'waitlisted';
      select coalesce(max(waitlist_position), 0) + 1 into v_next_position
        from public.attendance_view
       where resource_id = p_event_id and rsvp_status = 'waitlisted';
    end if;
  end if;

  insert into public.rsvp_actions (
    resource_id, member_id, status, recorded_at, metadata
  ) values (
    p_event_id,
    v_member_id,
    v_effective_status,
    now(),
    jsonb_strip_nulls(jsonb_build_object(
      'plus_ones',          p_plus_ones,
      'waitlist_position',  case when v_effective_status = 'waitlisted' then v_next_position else null end,
      'cancelled_reason',   case when v_effective_status = 'declined' then p_reason else null end,
      'cancelled_same_day', case
        when v_effective_status = 'declined'
         and (v_resource.metadata->>'starts_at')::timestamptz - now() < interval '24 hours'
        then true else null end,
      'via',                'set_rsvp_v2'
    ))
  );

  select * into v_view_row from public.attendance_view
   where resource_id = p_event_id and member_id = v_member_id;
  return v_view_row;
end;
$$;

comment on function public.set_rsvp_v2(uuid, text, integer, text) is
  '§14 step 5c-iii.C: emits an rsvp_actions atom. Capacity / waitlist gating preserved. Returns attendance_view row.';

-- 6c. check_in_v2: emit a check_in_actions atom.
create function public.check_in_v2(
  p_event_id           uuid,
  p_user_id            uuid,
  p_method             text default 'self',
  p_location_verified  boolean default false,
  p_arrived_at         timestamp with time zone default null
)
returns public.attendance_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource  public.resources;
  v_member_id uuid;
  v_view_row  public.attendance_view;
begin
  if p_method not in ('self', 'qr_scan', 'host_marked') then
    raise exception 'invalid method: %', p_method;
  end if;
  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  if not (auth.uid() = p_user_id or public.is_group_admin(v_resource.group_id, auth.uid())) then
    raise exception 'not allowed';
  end if;

  select id into v_member_id from public.group_members
   where group_id = v_resource.group_id and user_id = p_user_id limit 1;
  if v_member_id is null then raise exception 'membership not found'; end if;

  insert into public.check_in_actions (
    resource_id, member_id, arrived_at, metadata
  ) values (
    p_event_id,
    v_member_id,
    coalesce(p_arrived_at, now()),
    jsonb_strip_nulls(jsonb_build_object(
      'check_in_method',            p_method,
      'check_in_location_verified', coalesce(p_location_verified, false),
      'marked_by',                  auth.uid(),
      'via',                        'check_in_v2'
    ))
  );

  select * into v_view_row from public.attendance_view
   where resource_id = p_event_id and member_id = v_member_id;
  return v_view_row;
end;
$$;

comment on function public.check_in_v2(
  uuid, uuid, text, boolean, timestamp with time zone
) is
  '§14 step 5c-iii.C: emits a check_in_actions atom. Returns attendance_view row.';

-- 6d. cancel_event: UPDATE resources.status='cancelled'.
create function public.cancel_event(
  p_event_id uuid,
  p_reason   text default null
)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
  v_host_id  uuid;
begin
  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  v_host_id := (v_resource.metadata->>'host_id')::uuid;
  if not (public.is_group_admin(v_resource.group_id, auth.uid()) or v_host_id = auth.uid()) then
    raise exception 'host or admin only';
  end if;

  update public.resources
     set status   = 'cancelled',
         metadata = case
           when p_reason is null then metadata
           else jsonb_set(metadata, '{cancellation_reason}', to_jsonb(p_reason::text))
         end,
         updated_at = now()
   where id = p_event_id;

  perform public.record_system_event(
    v_resource.group_id,
    'eventClosed',
    p_event_id,
    null,
    jsonb_build_object(
      'title',  v_resource.metadata->>'title',
      'status', 'cancelled',
      'reason', p_reason
    )
  );

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.cancel_event(uuid, text) is
  '§14 step 5c-iii.C: UPDATEs resources.status=cancelled. Returns events_view row.';

-- 6e. close_event_no_fines: UPDATE resources.status='completed'.
create function public.close_event_no_fines(p_event_id uuid)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
  v_host_id  uuid;
begin
  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  v_host_id := (v_resource.metadata->>'host_id')::uuid;
  if not (public.is_group_admin(v_resource.group_id, auth.uid()) or v_host_id = auth.uid()) then
    raise exception 'host or admin only';
  end if;

  update public.resources
     set status   = 'completed',
         metadata = jsonb_set(metadata, '{closed_at}', to_jsonb(now()::text)),
         updated_at = now()
   where id = p_event_id;

  perform public.record_system_event(
    v_resource.group_id,
    'eventClosed',
    p_event_id,
    null,
    jsonb_build_object(
      'title',     v_resource.metadata->>'title',
      'closed_at', now(),
      'status',    'completed'
    )
  );

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.close_event_no_fines(uuid) is
  '§14 step 5c-iii.C: UPDATEs resources.status=completed. Returns events_view row.';

-- 6f. close_event: UPDATE resources.status='completed' (no more
-- evaluate_event_rules / roll_event_series calls — the rule engine
-- handles fines via the eventClosed system_event emitted below; series
-- continuation is driven by the auto-generate-events cron over
-- resource_series).
create function public.close_event(p_event_id uuid)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
begin
  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  if not public.is_group_admin(v_resource.group_id, auth.uid()) then
    raise exception 'admin only';
  end if;

  update public.resources
     set status   = 'completed',
         metadata = jsonb_set(metadata, '{closed_at}', to_jsonb(now()::text)),
         updated_at = now()
   where id = p_event_id;

  perform public.record_system_event(
    v_resource.group_id,
    'eventClosed',
    p_event_id,
    null,
    jsonb_build_object(
      'title',     v_resource.metadata->>'title',
      'closed_at', now(),
      'status',    'completed'
    )
  );

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.close_event(uuid) is
  '§14 step 5c-iii.C: UPDATEs resources.status=completed; the eventClosed system_event drives rule engine fine proposals via process-system-events. Returns events_view row.';

-- =============================================================================
-- Part 7. Grants — same shape as before the DROP
-- =============================================================================

revoke execute on function public.create_event_v2(
  uuid, text, timestamp with time zone, integer, text, numeric, numeric,
  uuid, text, text, text, boolean, boolean, uuid, timestamp with time zone
) from public, anon;
grant  execute on function public.create_event_v2(
  uuid, text, timestamp with time zone, integer, text, numeric, numeric,
  uuid, text, text, text, boolean, boolean, uuid, timestamp with time zone
) to authenticated, service_role;

revoke execute on function public.set_rsvp_v2(uuid, text, integer, text) from public, anon;
grant  execute on function public.set_rsvp_v2(uuid, text, integer, text) to authenticated, service_role;

revoke execute on function public.check_in_v2(uuid, uuid, text, boolean, timestamp with time zone) from public, anon;
grant  execute on function public.check_in_v2(uuid, uuid, text, boolean, timestamp with time zone) to authenticated, service_role;

revoke execute on function public.cancel_event(uuid, text) from public, anon;
grant  execute on function public.cancel_event(uuid, text) to authenticated, service_role;

revoke execute on function public.close_event(uuid) from public, anon;
grant  execute on function public.close_event(uuid) to authenticated, service_role;

revoke execute on function public.close_event_no_fines(uuid) from public, anon;
grant  execute on function public.close_event_no_fines(uuid) to authenticated, service_role;

revoke execute on function public.event_seat_count(uuid) from public, anon;
grant  execute on function public.event_seat_count(uuid) to authenticated, service_role;

revoke execute on function public.next_event_for_group(uuid) from public, anon;
grant  execute on function public.next_event_for_group(uuid) to authenticated, service_role;

revoke execute on function public.promote_from_waitlist(uuid) from public, anon;
grant  execute on function public.promote_from_waitlist(uuid) to authenticated, service_role;
