-- =========================================================
-- Migration 00012 — Event Layer V1
--
-- Aditiva: extiende events + event_attendance, agrega tabla
-- notification_tokens, agrega flag groups.auto_generate_events,
-- y crea 4 RPCs nuevas (create_event_v2, check_in_v2,
-- cancel_event, close_event_no_fines, next_event_for_group).
--
-- NO modifica el rule engine — close_event_no_fines NO llama
-- evaluate_event_rules. Phase 4 agregará close_event_with_fines.
-- =========================================================

-- =========================================================
-- 1. groups: opt-in flag for automatic recurring event generation
-- =========================================================
alter table public.groups
  add column if not exists auto_generate_events boolean not null default false;

-- =========================================================
-- 2. events: cover, description, geo, apply_rules, recurrence flag,
--           cancellation reason, closed_at, duration_minutes
-- =========================================================
alter table public.events
  add column if not exists cover_image_name text,
  add column if not exists cover_image_url text,
  add column if not exists description text,
  add column if not exists location_lat numeric(10, 7),
  add column if not exists location_lng numeric(10, 7),
  add column if not exists apply_rules boolean not null default true,
  add column if not exists is_recurring_generated boolean not null default false,
  add column if not exists closed_at timestamptz,
  add column if not exists cancellation_reason text,
  add column if not exists duration_minutes int default 180;

create index if not exists idx_events_starts_at_status
  on public.events(starts_at, status) where status in ('scheduled', 'in_progress');

-- =========================================================
-- 3. event_attendance: check-in method + location verification
-- =========================================================
alter table public.event_attendance
  add column if not exists check_in_method text
    check (check_in_method is null or check_in_method in ('self', 'qr_scan', 'host_marked')),
  add column if not exists check_in_location_verified boolean not null default false;

-- =========================================================
-- 4. notification_tokens: per-device APNs / FCM tokens
-- =========================================================
create table if not exists public.notification_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token text not null,
  platform text not null default 'ios' check (platform in ('ios', 'android', 'web')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, token)
);

create index if not exists idx_notif_tokens_user on public.notification_tokens(user_id);

create trigger notification_tokens_set_updated_at
  before update on public.notification_tokens
  for each row execute function public.set_updated_at();

alter table public.notification_tokens enable row level security;

drop policy if exists notif_tokens_self on public.notification_tokens;
create policy notif_tokens_self on public.notification_tokens
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- =========================================================
-- 5. RPCs
-- =========================================================

-- create_event_v2: richer signature for V1 onboarding events.
-- Wraps existing create_event semantics + adds cover, description,
-- geo, apply_rules, is_recurring_generated.
create or replace function public.create_event_v2(
  p_group_id uuid,
  p_title text,
  p_starts_at timestamptz,
  p_duration_minutes int default 180,
  p_location_name text default null,
  p_location_lat numeric default null,
  p_location_lng numeric default null,
  p_host_id uuid default null,
  p_cover_image_name text default null,
  p_cover_image_url text default null,
  p_description text default null,
  p_apply_rules boolean default true,
  p_is_recurring_generated boolean default false
) returns public.events
language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  g public.groups;
  v_cycle int;
  v_host uuid;
  v_ends_at timestamptz;
begin
  if not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'not a member';
  end if;

  select * into g from public.groups where id = p_group_id;
  if not found then raise exception 'group not found'; end if;

  v_cycle := (select coalesce(max(cycle_number), 0) + 1
              from public.events where group_id = p_group_id);
  v_host := coalesce(p_host_id,
    case when g.rotation_enabled then public.next_host_for_group(p_group_id, v_cycle) else null end);
  v_ends_at := p_starts_at + make_interval(mins => coalesce(p_duration_minutes, 180));

  insert into public.events (
    group_id, title, starts_at, ends_at, location, location_lat, location_lng,
    host_id, cycle_number, rsvp_deadline, cover_image_name, cover_image_url,
    description, apply_rules, is_recurring_generated, duration_minutes, created_by
  ) values (
    p_group_id, p_title, p_starts_at, v_ends_at,
    p_location_name, p_location_lat, p_location_lng,
    v_host, v_cycle, p_starts_at - interval '4 hours',
    p_cover_image_name, p_cover_image_url, p_description,
    coalesce(p_apply_rules, true), coalesce(p_is_recurring_generated, false),
    coalesce(p_duration_minutes, 180), auth.uid()
  ) returning * into e;

  -- Pre-create attendance rows for all active members (existing pattern).
  insert into public.event_attendance (event_id, user_id)
    select e.id, gm.user_id
    from public.group_members gm
    where gm.group_id = p_group_id and gm.active
    on conflict do nothing;

  return e;
end;
$$;

revoke execute on function public.create_event_v2(
  uuid, text, timestamptz, int, text, numeric, numeric, uuid, text, text, text, boolean, boolean
) from public, anon;
grant execute on function public.create_event_v2(
  uuid, text, timestamptz, int, text, numeric, numeric, uuid, text, text, text, boolean, boolean
) to authenticated;

-- check_in_v2: extends check_in_attendee with method + location flag.
create or replace function public.check_in_v2(
  p_event_id uuid,
  p_user_id uuid,
  p_method text default 'self',
  p_location_verified boolean default false,
  p_arrived_at timestamptz default null
) returns public.event_attendance
language plpgsql security definer set search_path = public as $$
declare
  g uuid; att public.event_attendance;
begin
  if p_method not in ('self', 'qr_scan', 'host_marked') then
    raise exception 'invalid method: %', p_method;
  end if;
  select group_id into g from public.events where id = p_event_id;
  if g is null then raise exception 'event not found'; end if;
  if not (auth.uid() = p_user_id or public.is_group_admin(g, auth.uid())) then
    raise exception 'not allowed';
  end if;
  update public.event_attendance
    set arrived_at = coalesce(p_arrived_at, now()),
        marked_by = auth.uid(),
        check_in_method = p_method,
        check_in_location_verified = coalesce(p_location_verified, false)
    where event_id = p_event_id and user_id = p_user_id
    returning * into att;
  if not found then raise exception 'attendance row not found'; end if;
  return att;
end;
$$;

revoke execute on function public.check_in_v2(uuid, uuid, text, boolean, timestamptz) from public, anon;
grant  execute on function public.check_in_v2(uuid, uuid, text, boolean, timestamptz) to authenticated;

-- cancel_event: marks event cancelled with optional reason. Host or admin only.
create or replace function public.cancel_event(
  p_event_id uuid,
  p_reason text default null
) returns public.events
language plpgsql security definer set search_path = public as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not (public.is_group_admin(e.group_id, auth.uid()) or e.host_id = auth.uid()) then
    raise exception 'host or admin only';
  end if;
  update public.events
    set status = 'cancelled',
        cancellation_reason = p_reason,
        updated_at = now()
    where id = p_event_id
    returning * into e;
  return e;
end;
$$;

revoke execute on function public.cancel_event(uuid, text) from public, anon;
grant  execute on function public.cancel_event(uuid, text) to authenticated;

-- close_event_no_fines: V1 — closes event WITHOUT firing rule engine.
-- Phase 4 will add close_event_with_fines that invokes evaluate_event_rules.
-- This is intentionally separate from existing close_event (which DOES
-- call evaluate + auto-rolls next event); event layer V1 keeps the
-- generation client-side per plan §5.4.
create or replace function public.close_event_no_fines(p_event_id uuid)
returns public.events
language plpgsql security definer set search_path = public as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not (public.is_group_admin(e.group_id, auth.uid()) or e.host_id = auth.uid()) then
    raise exception 'host or admin only';
  end if;
  update public.events
    set status = 'completed',
        closed_at = now(),
        updated_at = now()
    where id = p_event_id
    returning * into e;
  return e;
end;
$$;

revoke execute on function public.close_event_no_fines(uuid) from public, anon;
grant  execute on function public.close_event_no_fines(uuid) to authenticated;

-- next_event_for_group: cheap lookup for HomeView "next event" hero.
create or replace function public.next_event_for_group(p_group_id uuid)
returns public.events
language sql stable security definer set search_path = public as $$
  select * from public.events
  where group_id = p_group_id
    and status = 'scheduled'
    and starts_at >= now()
  order by starts_at asc
  limit 1;
$$;

grant execute on function public.next_event_for_group(uuid) to authenticated;
