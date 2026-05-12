-- 00092_rollback.sql
-- Reverts the soft-validation layer on record_system_event back to the
-- pre-00092 shape (no whitelist check, no NOTICE). Keeps system_events
-- rows untouched.

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
  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (p_group_id, p_event_type, p_resource_id, p_member_id, p_payload)
  returning id into v_event_id;
  return v_event_id;
end;
$$;

drop function if exists public.is_known_system_event_type(text);
