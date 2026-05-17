-- Rollback for 00243_system_event_payload_schemas.sql.
--
-- Restores the plain record_system_event (no validation) and drops
-- the validator + schema table.

create or replace function public.record_system_event(
  p_group_id    uuid,
  p_event_type  text,
  p_resource_id uuid default null,
  p_member_id   uuid default null,
  p_payload     jsonb default '{}'::jsonb
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

drop function if exists public.validate_system_event_payload(text, jsonb);
drop table if exists public.system_event_payload_schemas;
