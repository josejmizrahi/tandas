-- 00120_rollback.sql
-- Reverts remove_member to the 00115 shape (direct is_group_admin
-- check, no governance gate). Re-introduces the bypass where admins
-- could remove members in groups whose member.remove policy =
-- vote_required.

create or replace function public.remove_member(
  p_group_id uuid,
  p_user_id  uuid,
  p_reason   text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid       uuid := auth.uid();
  v_member_id uuid;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;
  if not public.is_group_admin(p_group_id, v_uid) then
    raise exception 'admin only';
  end if;
  if v_uid = p_user_id then
    raise exception 'admins cannot remove themselves — use leave_group';
  end if;

  select id into v_member_id
    from public.group_members
   where group_id = p_group_id
     and user_id  = p_user_id
     and active   = true;

  if v_member_id is null then
    raise exception 'target user is not an active member of this group';
  end if;

  perform public.record_system_event(
    p_group_id, 'memberLeft', null, v_member_id,
    jsonb_build_object(
      'user_id',    p_user_id,
      'removed_by', v_uid,
      'reason',     coalesce(p_reason, 'admin_removed')
    )
  );

  update public.group_members
     set active     = false,
         updated_at = now()
   where id = v_member_id;
end;
$$;
