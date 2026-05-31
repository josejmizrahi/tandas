-- 00094 — Gate record_system_event on group membership for authenticated
-- callers. Closes the last advisor warn on the function
-- (authenticated_security_definer_function_executable) and the real
-- vulnerability behind it: any iOS user with a session token could
-- previously insert system_events for any group_id and inject events
-- into groups they don't belong to (e.g. trigger fines on Bob's group
-- members while authed as Alice).
--
-- Auth model:
--   - service_role / edge functions  → auth.uid() returns null → bypass
--     the membership check (cron + RPCs that record events on behalf of
--     the platform stay unaffected).
--   - authenticated iOS user         → must be an active member of the
--     target group. iOS only ever emits events for the group it's
--     currently viewing (RLS already enforces visibility), so this gate
--     matches the legitimate-flow assumption explicitly.
--
-- Inactive members are rejected too: a kicked / left member shouldn't
-- be able to keep emitting events into the group.

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
  v_uid uuid := auth.uid();
begin
  if p_event_type is null or length(trim(p_event_type)) = 0 then
    raise exception 'record_system_event: event_type required';
  end if;

  -- Membership gate: enforced for authenticated callers; service_role
  -- (no auth.uid()) skips because edge functions / cron jobs emit events
  -- on behalf of the platform without a user identity.
  if v_uid is not null then
    if not exists (
      select 1
        from public.group_members gm
       where gm.group_id = p_group_id
         and gm.user_id  = v_uid
         and gm.active   = true
    ) then
      raise exception 'record_system_event: caller % is not an active member of group %', v_uid, p_group_id;
    end if;
  end if;

  if not public.is_known_system_event_type(p_event_type) then
    raise notice 'record_system_event: unknown event_type % (group=% resource=%) — row inserted but no rule engine evaluator will match; either ship a whitelist update or fix the caller.',
      p_event_type, p_group_id, p_resource_id;
  end if;

  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (p_group_id, p_event_type, p_resource_id, p_member_id, p_payload)
  returning id into v_event_id;

  return v_event_id;
end;
$$;

comment on function public.record_system_event is
  'Inserts a row into system_events. Authenticated callers must be active members of p_group_id (service_role bypasses the gate). Unknown event_types RAISE NOTICE; see is_known_system_event_type for the whitelist.';

revoke execute on function public.record_system_event(uuid, text, uuid, uuid, jsonb) from public, anon;
grant  execute on function public.record_system_event(uuid, text, uuid, uuid, jsonb) to authenticated, service_role;
