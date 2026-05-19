-- 00340 — Host default location + auto-RSVP on event creation.
-- See Plans/Active/Flow2_Audit_2026-05-18.md S4A + S4D-schema.

-- 1. Schema: host default location columns on profiles
alter table public.profiles
  add column if not exists host_default_location_name text,
  add column if not exists host_default_location_lat  numeric,
  add column if not exists host_default_location_lng  numeric;

comment on column public.profiles.host_default_location_name is
  'mig 00340: when this profile is assigned as event host, prefill event.metadata.location_name from this. Set via set_host_default_location RPC. Editable per-event without affecting this default.';

-- 2. RPC: lets a user update their own host default location
create or replace function public.set_host_default_location(
  p_name text,
  p_lat  numeric default null,
  p_lng  numeric default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'set_host_default_location: auth required';
  end if;
  update public.profiles
     set host_default_location_name = nullif(trim(coalesce(p_name, '')), ''),
         host_default_location_lat  = p_lat,
         host_default_location_lng  = p_lng,
         updated_at                 = now()
   where id = auth.uid();
end;
$$;

revoke execute on function public.set_host_default_location(text, numeric, numeric) from public, anon;
grant  execute on function public.set_host_default_location(text, numeric, numeric) to authenticated;

comment on function public.set_host_default_location(text, numeric, numeric) is
  'mig 00340: caller updates their own profile host default. Used by LocationEditorSheet when host ticks "save as my default".';

-- 3. BEFORE INSERT trigger: prefill event location from host's profile default
create or replace function public.prefill_event_location_from_host_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host_user_id uuid;
  v_default_name text;
  v_default_lat  numeric;
  v_default_lng  numeric;
begin
  if NEW.resource_type <> 'event' then return NEW; end if;
  -- Skip when caller already provided a location
  if length(coalesce(trim(NEW.metadata->>'location_name'), '')) > 0 then
    return NEW;
  end if;
  v_host_user_id := (NEW.metadata->>'host_id')::uuid;
  if v_host_user_id is null then return NEW; end if;

  select host_default_location_name, host_default_location_lat, host_default_location_lng
    into v_default_name, v_default_lat, v_default_lng
    from public.profiles
   where id = v_host_user_id;

  if v_default_name is null then return NEW; end if;

  NEW.metadata := NEW.metadata || jsonb_strip_nulls(jsonb_build_object(
    'location_name',  v_default_name,
    'location_lat',   v_default_lat,
    'location_lng',   v_default_lng,
    'location_source','host_profile_default'
  ));
  return NEW;
end;
$$;

revoke execute on function public.prefill_event_location_from_host_profile() from public, anon;
grant  execute on function public.prefill_event_location_from_host_profile() to authenticated, service_role;

drop trigger if exists trg_prefill_event_location_from_host_profile on public.resources;
create trigger trg_prefill_event_location_from_host_profile
  before insert on public.resources
  for each row
  when (NEW.resource_type = 'event')
  execute function public.prefill_event_location_from_host_profile();

-- 4. AFTER INSERT trigger: auto-RSVP host as going.
-- The host explicitly accepted the rotation slot (or manually became
-- host on create); they're confirmed by definition. The downstream
-- rsvp_actions insert fires mig 00337/00339 which emits
-- system_event(rsvpSubmitted) with payload.via='auto_host_confirm';
-- mig 00341 (next) consumes that to fan out invitations to others.
create or replace function public.auto_rsvp_host_going()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host_user_id   uuid;
  v_host_member_id uuid;
begin
  if NEW.resource_type <> 'event' then return NEW; end if;
  v_host_user_id := (NEW.metadata->>'host_id')::uuid;
  if v_host_user_id is null then return NEW; end if;

  select id into v_host_member_id
    from public.group_members
   where group_id = NEW.group_id
     and user_id  = v_host_user_id
     and active   = true
   limit 1;
  if v_host_member_id is null then return NEW; end if;

  -- Idempotency: skip if an rsvp_actions row already exists for this
  -- (event, host). Covers re-fires during dual-write paths.
  if exists (
    select 1 from public.rsvp_actions
     where resource_id = NEW.id
       and member_id   = v_host_member_id
  ) then return NEW; end if;

  insert into public.rsvp_actions (resource_id, member_id, status, recorded_at, metadata)
  values (NEW.id, v_host_member_id, 'going', now(),
          jsonb_build_object('via', 'auto_host_confirm'));

  return NEW;
end;
$$;

revoke execute on function public.auto_rsvp_host_going() from public, anon;
grant  execute on function public.auto_rsvp_host_going() to authenticated, service_role;

drop trigger if exists trg_auto_rsvp_host_going on public.resources;
create trigger trg_auto_rsvp_host_going
  after insert on public.resources
  for each row
  when (NEW.resource_type = 'event')
  execute function public.auto_rsvp_host_going();

comment on function public.auto_rsvp_host_going() is
  'mig 00340: auto-RSVPs the assigned host as going. The host''s acceptance of the rotation slot IS the RSVP — no separate Confirmar tap. Downstream: rsvp_actions trigger emits rsvpSubmitted with via=auto_host_confirm; mig 00341 consumes that to fan out invitations to non-host members.';;
