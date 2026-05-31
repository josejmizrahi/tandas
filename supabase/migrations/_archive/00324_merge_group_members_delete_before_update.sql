-- Mig 00324: _merge_group_members — DELETE placeholder row BEFORE updating
-- target row, so the UPDATE doesn't trip the uq_group_turn unique
-- constraint when both rows briefly share the same turn_order.
--
-- Repro from Phase 2 smoke retry (2026-05-18):
--   - admin has turn_order=1
--   - real target has turn_order=NULL
--   - placeholder created via finalize → turn_order=2
--   - merge: UPDATE target.turn_order = coalesce(NULL, 2) = 2
--     fires BEFORE DELETE placeholder → violates uq_group_turn since
--     placeholder still has 2.
--
-- Fix: capture the merge-source fields into local variables, DELETE the
-- placeholder first, then UPDATE the target. Order matters; the fix is
-- atomic within the FOR loop iteration.

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
      -- Conflict: target already a member of this group.
      --
      -- DELETE the placeholder row FIRST so the UPDATE below cannot
      -- collide with uq_group_turn(group_id, turn_order). All the fields
      -- we need from the placeholder are already captured in `r` from
      -- the FOR loop snapshot.
      delete from public.group_members
        where group_id = r.group_id and user_id = p_placeholder;

      update public.group_members tgt
        set
          turn_order = coalesce(tgt.turn_order, r.turn_order),
          roles = coalesce(tgt.roles, '[]'::jsonb)
                  || coalesce(r.roles, '[]'::jsonb),
          active = tgt.active or r.active
        where tgt.group_id = r.group_id and tgt.user_id = p_target;
    else
      -- No conflict: simple reassign keeps the same row id, so atoms +
      -- projections referencing group_members.id auto-inherit.
      update public.group_members
        set user_id = p_target
        where group_id = r.group_id and user_id = p_placeholder;
    end if;
  end loop;
end$$;

revoke all on function public._merge_group_members(uuid, uuid) from public, anon, authenticated;
