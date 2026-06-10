-- R.5Z.fix.EVENT.GUESTS (2026-06-10 founder smoke Campo Marte) — MVP1.
-- Tabla event_guests + 3 RPCs (add / remove / list). Manual source only.
-- Phase 2: cross-context picker + Apple Contacts.

create table if not exists public.event_guests (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.calendar_events(id) on delete cascade,
  display_name text not null,
  count_share int not null default 1 check (count_share >= 1 and count_share <= 20),
  invited_by_actor_id uuid not null references public.actors(id) on delete restrict,
  linked_actor_id uuid references public.actors(id) on delete set null,
  source text not null default 'manual' check (source in ('manual','actor','contact')),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  removed_at timestamptz
);

create index if not exists event_guests_event_idx on public.event_guests(event_id) where removed_at is null;
create index if not exists event_guests_invited_by_idx on public.event_guests(invited_by_actor_id);

alter table public.event_guests enable row level security;

create policy event_guests_read on public.event_guests
  for select using (
    exists (
      select 1 from public.calendar_events ce
      where ce.id = event_guests.event_id
        and public.is_context_member(ce.context_actor_id)
    )
  );

grant select on public.event_guests to authenticated;

create or replace function public.add_event_guest(
  p_event_id uuid,
  p_display_name text,
  p_count_share int default 1,
  p_linked_actor_id uuid default null,
  p_source text default 'manual'
) returns jsonb
language plpgsql security definer set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_ev public.calendar_events%rowtype;
  v_is_participant boolean;
  v_guest_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if length(trim(coalesce(p_display_name, ''))) = 0 then
    raise exception 'display_name is required' using errcode = '22023';
  end if;
  if p_count_share is null or p_count_share < 1 or p_count_share > 20 then
    raise exception 'count_share must be between 1 and 20' using errcode = '22023';
  end if;
  if p_source not in ('manual','actor','contact') then
    raise exception 'invalid source' using errcode = '22023';
  end if;
  select * into v_ev from public.calendar_events where id = p_event_id;
  if v_ev.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if v_ev.status in ('completed','cancelled') then
    raise exception 'cannot add guests to a terminal event' using errcode = '22023';
  end if;
  select exists (
    select 1 from public.event_participants
    where event_id = p_event_id
      and participant_actor_id = v_caller
      and status not in ('cancelled','declined')
  ) into v_is_participant;
  if not v_is_participant
     and v_ev.host_actor_id <> v_caller
     and not public.has_actor_authority(v_ev.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized (solo participants/host/admin pueden agregar invitados)' using errcode = '42501';
  end if;
  insert into public.event_guests
    (event_id, display_name, count_share, invited_by_actor_id, linked_actor_id, source)
  values
    (p_event_id, trim(p_display_name), p_count_share, v_caller, p_linked_actor_id, p_source)
  returning id into v_guest_id;
  return jsonb_build_object(
    'guest_id', v_guest_id, 'event_id', p_event_id,
    'display_name', trim(p_display_name), 'count_share', p_count_share,
    'invited_by', v_caller
  );
end;
$function$;

create or replace function public.remove_event_guest(p_guest_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_guest public.event_guests%rowtype;
  v_ev public.calendar_events%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_guest from public.event_guests where id = p_guest_id;
  if v_guest.id is null then raise exception 'guest not found' using errcode = 'P0002'; end if;
  if v_guest.removed_at is not null then
    return jsonb_build_object('changed', false, 'noop', true);
  end if;
  select * into v_ev from public.calendar_events where id = v_guest.event_id;
  if v_guest.invited_by_actor_id <> v_caller
     and v_ev.host_actor_id <> v_caller
     and not public.has_actor_authority(v_ev.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized to remove this guest' using errcode = '42501';
  end if;
  update public.event_guests set removed_at = now() where id = p_guest_id;
  return jsonb_build_object('changed', true, 'guest_id', p_guest_id);
end;
$function$;

create or replace function public.list_event_guests(p_event_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_ev public.calendar_events%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ev from public.calendar_events where id = p_event_id;
  if v_ev.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if not public.is_context_member(v_ev.context_actor_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', g.id, 'event_id', g.event_id,
      'display_name', g.display_name, 'count_share', g.count_share,
      'invited_by_actor_id', g.invited_by_actor_id,
      'invited_by_display_name', (select display_name from public.actors where id = g.invited_by_actor_id),
      'linked_actor_id', g.linked_actor_id, 'source', g.source,
      'created_at', g.created_at
    ) order by g.created_at desc)
    from public.event_guests g
    where g.event_id = p_event_id and g.removed_at is null
  ), '[]'::jsonb);
end;
$function$;

grant execute on function public.add_event_guest(uuid, text, int, uuid, text) to authenticated;
grant execute on function public.remove_event_guest(uuid) to authenticated;
grant execute on function public.list_event_guests(uuid) to authenticated;
