-- ============================================================================
-- R.5A.B.2 fixup: convencion has_actor_authority(p_context, p_actor, p_perm)
-- En set_resource_capability_override los args estaban invertidos.
-- ============================================================================
create or replace function public.set_resource_capability_override(
  p_resource_id uuid,
  p_capability_key text,
  p_enabled boolean,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_actor uuid;
  v_owner uuid;
begin
  if auth.uid() is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  v_actor := public.current_actor_id();
  if v_actor is null then
    raise exception 'missing person actor' using errcode = '42501';
  end if;

  if not exists (select 1 from public.resource_capabilities_catalog where capability_key = p_capability_key) then
    raise exception 'unknown capability %', p_capability_key using errcode = '22023';
  end if;

  select canonical_owner_actor_id into v_owner from public.resources where id = p_resource_id;
  if v_owner is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;

  -- CONVENCION: has_actor_authority(context, actor, permission)
  if not public.has_actor_authority(v_owner, v_actor, 'resources.manage') then
    raise exception 'missing permission resources.manage' using errcode = '42501';
  end if;

  insert into public.resource_capability_overrides (resource_id, capability_key, enabled, reason, created_by_actor_id)
    values (p_resource_id, p_capability_key, p_enabled, p_reason, v_actor)
    on conflict (resource_id, capability_key) do update
      set enabled = excluded.enabled,
          reason = excluded.reason,
          updated_at = now();

  return public.effective_resource_capabilities(p_resource_id);
end;
$$;

revoke all on function public.set_resource_capability_override(uuid, text, boolean, text) from public, anon;
grant execute on function public.set_resource_capability_override(uuid, text, boolean, text) to authenticated, service_role;
