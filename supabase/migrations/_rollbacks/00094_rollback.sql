-- 00094_rollback.sql
-- Reverts the membership guard added in 00094. The function returns to
-- the 00093 shape (whitelist NOTICE only, no membership check).
-- WARNING: removing the gate restores the pre-00094 vulnerability where
-- any authenticated user could inject system_events into groups they
-- don't belong to. Only roll back if 00094 breaks a legitimate caller
-- that hasn't been migrated to service_role.

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
begin
  if p_event_type is null or length(trim(p_event_type)) = 0 then
    raise exception 'record_system_event: event_type required';
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

revoke execute on function public.record_system_event(uuid, text, uuid, uuid, jsonb) from public, anon;
grant  execute on function public.record_system_event(uuid, text, uuid, uuid, jsonb) to authenticated, service_role;
