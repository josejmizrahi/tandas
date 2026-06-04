-- F.EVENT.5 — events must always have a location, unless they are virtual.
-- Founder doctrine 2026-06-04: "siempre tiene que tener ubicacion un evento. si es virtual no".

-- 1. New column `is_virtual` default false.
alter table public.calendar_events
  add column if not exists is_virtual boolean not null default false;

-- 2. Backfill: 15 existing events have NULL location_text and were created before the rule.
--    Marking them with a placeholder "Por definir" so the CHECK constraint passes;
--    founder can edit each one (or flip is_virtual=true) afterwards.
update public.calendar_events
   set location_text = 'Por definir'
 where (location_text is null or btrim(location_text) = '')
   and is_virtual = false;

-- 3. CHECK constraint: location required unless virtual.
alter table public.calendar_events
  drop constraint if exists calendar_events_location_required;
alter table public.calendar_events
  add constraint calendar_events_location_required
  check (is_virtual = true OR (location_text is not null and length(btrim(location_text)) > 0));

-- 4. Drop the old RPC signature so we can extend it with p_is_virtual.
drop function if exists public.create_calendar_event(
  uuid, text, text, timestamptz, timestamptz, text, text, text, text, uuid, boolean, jsonb, text
);

-- 5. Recreate with p_is_virtual + server-side validation.
create or replace function public.create_calendar_event(
  p_context_actor_id uuid,
  p_title text,
  p_event_type text,
  p_starts_at timestamptz,
  p_ends_at timestamptz default null,
  p_description text default null,
  p_timezone text default 'America/Mexico_City',
  p_location_text text default null,
  p_recurrence_rule text default null,
  p_host_actor_id uuid default null,
  p_invite_all_members boolean default true,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null,
  p_is_virtual boolean default false
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
  v_existing uuid;
  v_location text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'events.create') then
    raise exception 'not authorized to create events in context %', p_context_actor_id using errcode = '42501';
  end if;

  -- F.EVENT.5: enforce location requirement.
  v_location := nullif(btrim(coalesce(p_location_text, '')), '');
  if not p_is_virtual and v_location is null then
    raise exception 'location_required: events must have a location unless marked as virtual'
      using errcode = '22023';
  end if;

  -- idempotencia por client_id
  if p_client_id is not null then
    select id into v_existing from public.calendar_events
     where context_actor_id = p_context_actor_id and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('event_id', v_existing,
        'event', (select to_jsonb(e) from public.calendar_events e where e.id = v_existing));
    end if;
  end if;

  insert into public.calendar_events
    (context_actor_id, title, description, event_type, starts_at, ends_at, timezone,
     location_text, recurrence_rule, host_actor_id, metadata, client_id, created_by_actor_id, is_virtual)
  values
    (p_context_actor_id, btrim(p_title), p_description, p_event_type, p_starts_at, p_ends_at, p_timezone,
     v_location, p_recurrence_rule, coalesce(p_host_actor_id, v_caller),
     coalesce(p_metadata, '{}'::jsonb), p_client_id, v_caller, p_is_virtual)
  returning id into v_id;

  -- R.2D: todos los miembros activos quedan 'invited'.
  if p_invite_all_members and p_context_actor_id <> v_caller then
    insert into public.event_participants (event_id, participant_actor_id, status)
    select v_id, am.member_actor_id, 'invited'
      from public.actor_memberships am
     where am.context_actor_id = p_context_actor_id and am.membership_status = 'active'
    on conflict (event_id, participant_actor_id) do nothing;
  else
    insert into public.event_participants (event_id, participant_actor_id, status, rsvp_at)
    values (v_id, v_caller, 'going', now())
    on conflict (event_id, participant_actor_id) do nothing;
  end if;

  perform public._emit_activity(p_context_actor_id, v_caller, 'event.created', 'calendar_event', v_id,
    jsonb_build_object('title', btrim(p_title), 'event_type', p_event_type, 'starts_at', p_starts_at,
                       'is_virtual', p_is_virtual));

  return jsonb_build_object('event_id', v_id,
    'event', (select to_jsonb(e) from public.calendar_events e where e.id = v_id),
    'participants', (select count(*) from public.event_participants where event_id = v_id));
end; $$;

-- 6. GRANTs (memory pattern: REVOKE FROM anon + GRANT EXECUTE TO authenticated, service_role).
revoke all on function public.create_calendar_event(
  uuid, text, text, timestamptz, timestamptz, text, text, text, text, uuid, boolean, jsonb, text, boolean
) from public, anon;
grant execute on function public.create_calendar_event(
  uuid, text, text, timestamptz, timestamptz, text, text, text, text, uuid, boolean, jsonb, text, boolean
) to authenticated, service_role;
