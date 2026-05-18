-- Rollback for mig 00324: restore the UPDATE-then-DELETE order that
-- collides with uq_group_turn. Only useful when reverting the full merge
-- engine; do not roll back alone without also reverting mig 00316.

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
      update public.group_members tgt
        set
          turn_order = coalesce(tgt.turn_order, r.turn_order),
          roles = coalesce(tgt.roles, '[]'::jsonb)
                  || coalesce(r.roles, '[]'::jsonb),
          active = tgt.active or r.active
        where tgt.group_id = r.group_id and tgt.user_id = p_target;
      delete from public.group_members
        where group_id = r.group_id and user_id = p_placeholder;
    else
      update public.group_members
        set user_id = p_target
        where group_id = r.group_id and user_id = p_placeholder;
    end if;
  end loop;
end$$;
