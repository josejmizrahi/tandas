-- Rollback 00144 — restore the 00070 body of create_asset
-- (assignSlot-gated). Existing asset rows stay.

create or replace function public.create_asset(
  p_group_id uuid,
  p_name text,
  p_capacity int default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id uuid := auth.uid();
  v_asset_id  uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not public.has_permission(p_group_id, v_caller_id, 'assignSlot') then
    raise exception 'permission denied: assignSlot required' using errcode = '42501';
  end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'asset name required' using errcode = '22023';
  end if;

  insert into public.resources (group_id, resource_type, status, metadata, created_by)
  values (
    p_group_id,
    'asset',
    'active',
    jsonb_build_object('name', p_name, 'capacity', p_capacity),
    v_caller_id
  )
  returning id into v_asset_id;

  perform public.record_system_event(
    p_group_id,
    'assetCreated',
    v_asset_id,
    null,
    jsonb_build_object('name', p_name, 'capacity', p_capacity)
  );

  return v_asset_id;
end;
$$;
