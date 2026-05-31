-- Mig 00326: _merge_group_members — in conflict-case (target is already a
-- member of the same group), DEACTIVATE the placeholder row instead of
-- DELETEing it. The DELETE cascades to system_events.member_id via
-- ON DELETE SET NULL (mig 00014), which then triggers the atom guard
-- (mig 00162) since UPDATEs on system_events are blocked except for
-- processed_at — append-only.
--
-- Discovered in Phase 2 smoke retry on 2026-05-18:
--   ERROR: atom row public.system_events is append-only; only processed_at
--   may transition
--
-- Trade-off: the placeholder GM row stays in the table forever, with
-- active=false. Queries that filter on active=true (the canonical
-- "current roster" projection) naturally exclude it. The placeholder's
-- user_id remains; the identity_resolver view bridges any user-id-based
-- aggregation post-merge. No atoms are mutated.
--
-- Simple-case (target NOT already a member) is unchanged — we UPDATE
-- group_members.user_id in place. That keeps group_members.id stable so
-- all atoms that reference member_id auto-inherit the target user.

create or replace function public._merge_group_members(
  p_placeholder uuid,
  p_target uuid
) returns void
language plpgsql security definer set search_path = public, pg_catalog
as $$
declare
  r record;
begin
  for r in
    select gm_p.*
    from public.group_members gm_p
    where gm_p.user_id = p_placeholder
  loop
    if exists (
      select 1 from public.group_members
      where group_id = r.group_id and user_id = p_target
    ) then
      -- Conflict: target already a member.
      --
      -- We CANNOT DELETE the placeholder GM row because:
      --   1. system_events.member_id has ON DELETE SET NULL (mig 00014).
      --   2. system_events atom guard blocks the SET NULL update.
      --
      -- Instead: deactivate placeholder GM (active=false, turn_order=NULL
      -- to free the slot) and merge metadata into the target row.
      update public.group_members
        set active = false, turn_order = null
        where group_id = r.group_id and user_id = p_placeholder;

      update public.group_members tgt
        set
          turn_order = coalesce(tgt.turn_order, r.turn_order),
          roles = coalesce(tgt.roles, '[]'::jsonb)
                  || coalesce(r.roles, '[]'::jsonb),
          active = tgt.active or r.active
        where tgt.group_id = r.group_id and tgt.user_id = p_target;
    else
      -- Simple-case: reassign user_id in place. group_members.id is
      -- stable, so atoms referencing member_id auto-inherit the target.
      update public.group_members
        set user_id = p_target
        where group_id = r.group_id and user_id = p_placeholder;
    end if;
  end loop;
end$$;

revoke all on function public._merge_group_members(uuid, uuid) from public, anon, authenticated;
