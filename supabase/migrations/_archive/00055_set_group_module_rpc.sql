-- 00055 — Module-aware write path: set_group_module RPC.
--
-- Audit: Plans/Active/Primitives.md § 3, slice 3.
--
-- Context:
--   Slice 1 (mig 00049) made groups.active_modules canonical and added a
--   trigger that derives fines_enabled from it.
--   Slice 2 (commit 62adfa9) migrated 5 iOS read-path callsites to
--   CapabilityResolver, which reads from active_modules.
--   Slice 3 (this migration + iOS changes) migrates the write-path:
--   onboarding + group-settings stop pushing the legacy fines_enabled
--   boolean and instead toggle module membership directly in
--   active_modules. The trigger keeps fines_enabled in sync until the
--   column drop in Slice 4 (~2 weeks paridad window).
--
-- This RPC is intentionally generic ("set any module slug for any group")
-- rather than a basic_fines-specific helper. Any L2/L3/L4 primitive that
-- ships as a GroupModule (rotation, fund, asset, slot, …) reuses the same
-- write path with no schema change.
--
-- Idempotency: calling with p_enabled=true on an already-enabled module is
-- a no-op (the trigger sees no jsonb diff and skips the sync branch). Same
-- for p_enabled=false on an already-disabled module.
--
-- Permission model: admin-only via is_group_admin. RLS on the underlying
-- groups row also requires admin via groups_update_admin (mig 00019), but
-- we double-gate at the RPC layer so non-admins get a clear error instead
-- of an empty result set.
--
-- Out of scope:
--   - Module dependency / conflict validation (e.g. enabling appeal_voting
--     while basic_fines is off). The iOS ModuleRegistry already validates
--     this client-side; server enforcement is a separate slice tracked
--     under capability resolver hardening.
--   - Returning the canonical Module list. The iOS app already knows
--     ModuleRegistry.v1Modules at compile time.
--
-- Rollback: 00055_rollback.sql drops the RPC. The data state is unaffected.

create or replace function public.set_group_module(
  p_group_id    uuid,
  p_module_slug text,
  p_enabled     boolean
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
begin
  if p_module_slug is null or length(trim(p_module_slug)) = 0 then
    raise exception 'set_group_module: p_module_slug is required';
  end if;

  if p_enabled is null then
    raise exception 'set_group_module: p_enabled is required';
  end if;

  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'only admins can change group modules';
  end if;

  if p_enabled then
    update public.groups
       set active_modules = case
             when active_modules ? p_module_slug then active_modules
             else active_modules || jsonb_build_array(p_module_slug)
           end,
           updated_at = now()
     where id = p_group_id
     returning * into g;
  else
    update public.groups
       set active_modules = case
             when active_modules ? p_module_slug then active_modules - p_module_slug
             else active_modules
           end,
           updated_at = now()
     where id = p_group_id
     returning * into g;
  end if;

  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  return g;
end;
$$;

comment on function public.set_group_module(uuid, text, boolean) is
  'Toggles module slug membership in groups.active_modules. Admin-only. Trigger from mig 00049 derives groups.fines_enabled when slug=basic_fines. See Plans/Active/Primitives.md § 3 (slice 3).';

revoke execute on function public.set_group_module(uuid, text, boolean) from public, anon;
grant  execute on function public.set_group_module(uuid, text, boolean) to authenticated;
