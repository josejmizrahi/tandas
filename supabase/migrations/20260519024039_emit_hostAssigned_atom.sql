-- 00332 — Emit `hostAssigned` as a system_event atom alongside the
-- existing user_action(hostAssigned) row.
--
-- Plans/Active/Flow1_Audit_2026-05-18.md §B.4 (closes feed gap).
--
-- Problem
-- =======
-- Trigger 00133 only inserts a `user_actions(hostAssigned)` row when an
-- event is created with a host different from the creator (manual or
-- rotation-resolved). user_actions is RLS-gated to the targeted user
-- (`user_id = auth.uid()`), so the activity feed — which renders
-- system_events for the whole group — never shows "Ana es la anfitriona
-- del jueves" to anyone other than Ana.
--
-- Fix
-- ===
-- Register `hostAssigned` in the atom catalog and extend the
-- on_event_inserted_host_assigned() trigger to ALSO insert a
-- public.system_events row. system_events SELECT is group-scoped via
-- existing RLS, so every member of the group sees the atom in their
-- feed. The user_action insert stays (inbox card for the targeted host).
--
-- Payload contract
-- ================
-- system_events.event_type = 'hostAssigned'
-- system_events.member_id  = host_id  (the new anfitrión)
-- system_events.resource_id = event.id
-- system_events.payload    = { title, starts_at, assigned_by, cycle? }

select public.register_event_type(
  'hostAssigned',
  'mig_00332',
  'Tier 5 Beta: emitted alongside user_action(hostAssigned) so group members see rotation in the activity feed (user_actions RLS is single-user).'
);

create or replace function public.on_event_inserted_host_assigned()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payload jsonb;
begin
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

  v_payload := jsonb_build_object(
    'title',       coalesce(new.title, 'Evento'),
    'starts_at',   to_char(new.starts_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'assigned_by', new.created_by,
    'cycle',       new.cycle_number
  );

  perform public.record_system_event(
    p_group_id    => new.group_id,
    p_event_type  => 'hostAssigned',
    p_resource_id => new.id,
    p_member_id   => new.host_id,
    p_payload     => v_payload
  );

  return new;
end;
$$;

revoke execute on function public.on_event_inserted_host_assigned() from public, anon;
grant  execute on function public.on_event_inserted_host_assigned() to authenticated, service_role;

comment on function public.on_event_inserted_host_assigned() is
  'mig 00332: emits BOTH user_action(hostAssigned) (inbox, scoped to host) and system_event(hostAssigned) (activity feed, scoped to group) on event INSERT when host_id is set and differs from created_by. Tier 5 Beta rotation visibility.';;
