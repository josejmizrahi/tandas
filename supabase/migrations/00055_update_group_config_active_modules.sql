-- 00055 — Add p_active_modules to update_group_config RPC.
--
-- Audit: Plans/Active/Primitives.md § 3, slice 3.
--
-- Slice 3 transitions iOS write-path off the legacy fines_enabled column.
-- The trigger from 00049 already keeps fines_enabled in sync with
-- active_modules bidirectionally; this migration adds an
-- active_modules-first parameter so iOS can stop sending p_fines_enabled
-- before slice 4 drops the column outright.
--
-- Backwards compatible during the transition window:
--   - p_fines_enabled remains accepted (legacy callers still work via
--     the 00049 trigger).
--   - If both p_active_modules and p_fines_enabled are passed, the
--     trigger reconciles them: p_active_modules sets active_modules
--     directly, then the trigger overwrites fines_enabled to match.
--   - The existing 7-param signature is dropped; the new 8-param is
--     additive at the tail with a default, so RPC calls that name
--     params (PostgREST does this) keep working.
--
-- Rollback: 00055_rollback.sql restores the pre-slice-3 7-param signature.

drop function if exists public.update_group_config(uuid, text, text, jsonb, boolean, text, text);

create or replace function public.update_group_config(
  p_group_id uuid,
  p_event_label text default null,
  p_frequency_type text default null,
  p_frequency_config jsonb default null,
  p_fines_enabled boolean default null,
  p_rotation_mode text default null,
  p_cover_image_name text default null,
  p_active_modules jsonb default null
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'only admins can update group config';
  end if;

  -- p_active_modules is the canonical SoT going forward (slice 3).
  -- The trigger groups_sync_basic_fines_module (00049) ensures
  -- fines_enabled = ('basic_fines' = ANY(active_modules)) on every
  -- write. p_fines_enabled remains accepted as a legacy fallback
  -- and is reconciled by the same trigger.
  update public.groups
    set event_label       = coalesce(p_event_label, event_label),
        frequency_type    = case when p_frequency_type is not null then p_frequency_type else frequency_type end,
        frequency_config  = case when p_frequency_config is not null then p_frequency_config else frequency_config end,
        fines_enabled     = coalesce(p_fines_enabled, fines_enabled),
        rotation_mode     = coalesce(p_rotation_mode, rotation_mode),
        cover_image_name  = case when p_cover_image_name is not null then p_cover_image_name else cover_image_name end,
        active_modules    = coalesce(p_active_modules, active_modules),
        updated_at        = now()
    where id = p_group_id
    returning * into g;

  return g;
end;
$$;

revoke execute on function public.update_group_config(uuid, text, text, jsonb, boolean, text, text, jsonb) from public, anon;
grant  execute on function public.update_group_config(uuid, text, text, jsonb, boolean, text, text, jsonb) to authenticated;

comment on function public.update_group_config(uuid, text, text, jsonb, boolean, text, text, jsonb) is
  'Partial update of group config. p_active_modules is canonical (slice 3); p_fines_enabled is legacy (slice 4 drops the column). See Plans/Active/Primitives.md § 3.';
