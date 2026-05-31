-- 00143 — Beta 1 Consolidation W2-E1: hostAssigned date formats in the
-- group's timezone, not UTC.
--
-- Bug
-- ===
-- mig 00133:52 hardcoded `at time zone 'UTC'` when building the body of
-- the hostAssigned user_action. Mexico (UTC-6 / UTC-5 DST) users would
-- see "14 May" for an event that, in their local time, is happening on
-- the 13th — a one-day drift on the inbox copy of any evening event.
--
-- Audit Track E High #5.
--
-- Fix
-- ===
-- Read `groups.timezone` (text, IANA name; seeded by create_group_with_admin)
-- and use it as the conversion target. Falls back to `America/Mexico_City`
-- if the group somehow has a null/empty timezone — same default
-- create_group_with_admin uses.
--
-- Idempotent: CREATE OR REPLACE FUNCTION + drop/create trigger pattern,
-- same as mig 00133.

create or replace function public.on_event_inserted_host_assigned()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tz text;
begin
  -- Skip when no host or when the creator is also the host. The
  -- creator-hosting path produces no surprise; the inbox shouldn't
  -- nag the user for their own choice.
  if new.host_id is null then return new; end if;
  if new.created_by is not null and new.host_id = new.created_by then
    return new;
  end if;

  -- W2-E1: resolve to the group's configured timezone so the body
  -- copy reads in the user's local frame, not UTC.
  select nullif(trim(coalesce(timezone, '')), '')
    into v_tz
    from public.groups
   where id = new.group_id;
  v_tz := coalesce(v_tz, 'America/Mexico_City');

  insert into public.user_actions (
    user_id,
    group_id,
    action_type,
    reference_id,
    title,
    body,
    priority
  ) values (
    new.host_id,
    new.group_id,
    'hostAssigned',
    new.id,
    'Te toca ser anfitrión',
    coalesce(new.title, 'Evento') || ' — ' || to_char(new.starts_at at time zone v_tz, 'DD Mon YYYY'),
    'medium'
  );

  return new;
end;
$$;

revoke execute on function public.on_event_inserted_host_assigned() from public, anon;
grant  execute on function public.on_event_inserted_host_assigned() to authenticated, service_role;

drop trigger if exists trg_on_event_inserted_host_assigned on public.events;
create trigger trg_on_event_inserted_host_assigned
  after insert on public.events
  for each row
  execute function public.on_event_inserted_host_assigned();

comment on function public.on_event_inserted_host_assigned() is
  'Tier 5 Beta + W2-E1 (mig 00143): inserts user_actions(hostAssigned) on event create when host != creator. W2-E1 fix: body date formatted in groups.timezone (fallback America/Mexico_City), not UTC — eliminates one-day drift on evening events for Mexico beta users.';
