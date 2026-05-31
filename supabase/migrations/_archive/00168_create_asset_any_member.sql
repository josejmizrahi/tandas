-- 00144 — Relax `create_asset` permission from `assignSlot` to
-- `is_group_member`.
-- (Originally landed on main as 00142_create_asset_any_member.sql and
-- was applied to prod under that name; renumbered to 00144 to clear
-- the 00142 slot — the Beta 1 Consolidation parallel session also
-- shipped 00142_void_fine_priority_low_and_auto_resolve.sql. Prod
-- state is unaffected: supabase records migrations by timestamp,
-- not filename.)
--
-- Background
-- ==========
-- Mig 00070 gated `create_asset` behind
--   `has_permission(group_id, user_id, 'assignSlot')`
-- which only the `shared_resource` template's `founder` + `seat_owner`
-- roles grant. The dominant template in prod (`recurring_dinner`) has
-- no role with `assignSlot`, so the Universal ResourceWizard's
-- "Activo compartido" card always 403s with
--   `permission denied: assignSlot required`
-- (caught on real-device QA 2026-05-13 after the Tier 6 install).
--
-- The 00070 author conflated two operations:
--   - Creating the parent asset row (this RPC) — config change
--   - Assigning slots within an existing asset (assign_slot RPC) —
--     access control on the slot's holder
--
-- `assignSlot` legitimately gates `assign_slot`. It shouldn't gate
-- `create_asset`. Symmetry: `create_fund` (mig 00139) accepts any
-- group member with the founder framing "money/resources are group
-- activity, not admin-only". The same logic applies to assets.
--
-- Fix: replace the assignSlot check with `is_group_member`. assign_slot
-- + finalize handlers + ResourceTypePicker behavior stay unchanged.

create or replace function public.create_asset(
  p_group_id uuid,
  p_name     text,
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

  -- Tier 6 alignment (00144): any group member can create an asset.
  -- Slot assignment still requires assignSlot — see assign_slot RPC.
  if not public.is_group_member(p_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'asset name required' using errcode = '22023';
  end if;

  insert into public.resources (group_id, resource_type, status, metadata, created_by)
  values (
    p_group_id,
    'asset',
    'active',
    jsonb_build_object(
      'name',     p_name,
      'capacity', p_capacity
    ),
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

comment on function public.create_asset(uuid, text, int) is
  'Phase 2 Slice 2.3 — create a new asset (palco/cabaña/casa). v2 (00144): any group member may call (was assignSlot-gated, which broke recurring_dinner groups whose roles lack that permission). Slot assignment remains gated by assignSlot in assign_slot RPC.';
