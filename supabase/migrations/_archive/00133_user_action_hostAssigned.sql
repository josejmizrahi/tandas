-- 00133 — Tier 5 Beta: emit user_action(hostAssigned) when an event is
-- created with a host_id different from the creator.
--
-- Why a trigger and not inside create_event_v2: keeping the user_action
-- write at the trigger layer means recurrence-generated occurrences
-- (auto-generate-events runs as service_role) get the user_action
-- without auth.uid() shenanigans. The trigger fires AFTER INSERT on
-- events regardless of the calling path.
--
-- Skip rule: when host_id IS NULL or host_id = created_by, no inbox
-- entry. The creator already knows they're hosting; the surprise case
-- the inbox is for is "someone (or rotation) put you on the spot".
-- Rotation-generated occurrences from auto-generate-events have
-- created_by = NULL (service_role), so the != check is satisfied
-- whenever host_id resolves via next_host_for_series.
--
-- Idempotency: events insert is the only fire path; ON CONFLICT on the
-- (resource_id, recipient_user_id, action_type) composite isn't needed
-- because each event row inserts once. If a host gets reassigned via
-- a future swap mechanism, that's a separate emit point (deferred to
-- Tier 5+, per founder scope — out of Beta).

create or replace function public.on_event_inserted_host_assigned()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Skip when no host or when the creator is also the host. The
  -- creator-hosting path produces no surprise; the inbox shouldn't
  -- nag the user for their own choice.
  if new.host_id is null then return new; end if;
  if new.created_by is not null and new.host_id = new.created_by then
    return new;
  end if;

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
    coalesce(new.title, 'Evento') || ' — ' || to_char(new.starts_at at time zone 'UTC', 'DD Mon YYYY'),
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
  'Tier 5 Beta: inserts a user_actions(hostAssigned) row when a freshly created event has a host_id different from the creator. Closes the loop between auto-generate-events rotation resolution and the inbox surface.';
