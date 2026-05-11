-- 00098_rollback.sql
-- Removes the lifecycle system_event emits added in 00098. The
-- already-emitted rows in system_events are left untouched. Use only
-- if 00098 starts logging duplicate rows after a follow-up that adds
-- the same emits via triggers or a different RPC.

create or replace function public.close_event_no_fines(p_event_id uuid)
returns public.events
language plpgsql security definer set search_path = public as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not (public.is_group_admin(e.group_id, auth.uid()) or e.host_id = auth.uid()) then
    raise exception 'host or admin only';
  end if;
  update public.events
    set status = 'completed',
        closed_at = now(),
        updated_at = now()
    where id = p_event_id
    returning * into e;
  return e;
end;
$$;

create or replace function public.cancel_event(
  p_event_id uuid,
  p_reason text default null
) returns public.events
language plpgsql security definer set search_path = public as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not (public.is_group_admin(e.group_id, auth.uid()) or e.host_id = auth.uid()) then
    raise exception 'host or admin only';
  end if;
  update public.events
    set status = 'cancelled',
        cancellation_reason = p_reason,
        updated_at = now()
    where id = p_event_id
    returning * into e;
  return e;
end;
$$;

create or replace function public.join_group_by_code(p_code text)
returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups; v_max int;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  select * into g from public.groups where invite_code = p_code;
  if not found then raise exception 'invite code not found'; end if;

  if exists (select 1 from public.group_members where group_id = g.id and user_id = auth.uid()) then
    update public.group_members set active = true where group_id = g.id and user_id = auth.uid();
    return g;
  end if;

  select coalesce(max(turn_order), 0) into v_max from public.group_members where group_id = g.id;
  insert into public.group_members (group_id, user_id, role, turn_order)
  values (g.id, auth.uid(), 'member', v_max + 1);
  return g;
end;
$$;
