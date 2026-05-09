-- Rollback for 00055_update_group_config_active_modules.sql
--
-- Restores the pre-slice-3 7-param signature of update_group_config
-- (without p_active_modules). The 00049 trigger remains in place so
-- the underlying invariant
--   fines_enabled = ('basic_fines' = ANY(active_modules))
-- still holds on every write through the legacy p_fines_enabled path.
--
-- Note: any iOS callers that already migrated to p_active_modules will
-- fail after this rollback — they would need to be reverted in tandem.

drop function if exists public.update_group_config(uuid, text, text, jsonb, boolean, text, text, jsonb);

create or replace function public.update_group_config(
  p_group_id uuid,
  p_event_label text default null,
  p_frequency_type text default null,
  p_frequency_config jsonb default null,
  p_fines_enabled boolean default null,
  p_rotation_mode text default null,
  p_cover_image_name text default null
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'only admins can update group config';
  end if;
  update public.groups
    set event_label       = coalesce(p_event_label, event_label),
        frequency_type    = case when p_frequency_type is not null then p_frequency_type else frequency_type end,
        frequency_config  = case when p_frequency_config is not null then p_frequency_config else frequency_config end,
        fines_enabled     = coalesce(p_fines_enabled, fines_enabled),
        rotation_mode     = coalesce(p_rotation_mode, rotation_mode),
        cover_image_name  = case when p_cover_image_name is not null then p_cover_image_name else cover_image_name end,
        updated_at        = now()
    where id = p_group_id
    returning * into g;
  return g;
end;
$$;

revoke execute on function public.update_group_config(uuid, text, text, jsonb, boolean, text, text) from public, anon;
grant  execute on function public.update_group_config(uuid, text, text, jsonb, boolean, text, text) to authenticated;
