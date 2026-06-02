-- D.21B — Inbox surface for notifications_outbox
-- Adds read_at column, unread index, and 4 RPCs so iOS can render in-app inbox.

alter table public.notifications_outbox
  add column if not exists read_at timestamp with time zone;

create index if not exists notifications_outbox_unread_idx
  on public.notifications_outbox (recipient_user_id, created_at desc)
  where read_at is null;

create or replace function public.list_my_inbox(
  p_group_id uuid default null,
  p_unread_only boolean default false,
  p_limit integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = 'P0001';
  end if;
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', n.id,
        'group_id', n.group_id,
        'category', n.category,
        'payload', n.payload,
        'dispatch_status', n.dispatch_status,
        'dispatched_at', n.dispatched_at,
        'read_at', n.read_at,
        'created_at', n.created_at
      ) order by n.created_at desc
    ),
    '[]'::jsonb
  )
  into v_result
  from (
    select * from public.notifications_outbox
    where recipient_user_id = v_uid
      and (p_group_id is null or group_id = p_group_id)
      and (not p_unread_only or read_at is null)
    order by created_at desc
    limit p_limit
  ) n;
  return v_result;
end $$;

grant execute on function public.list_my_inbox(uuid, boolean, integer) to authenticated;

create or replace function public.mark_inbox_read(p_outbox_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = 'P0001';
  end if;
  update public.notifications_outbox
     set read_at = now()
   where id = p_outbox_id
     and recipient_user_id = v_uid
     and read_at is null;
end $$;

grant execute on function public.mark_inbox_read(uuid) to authenticated;

create or replace function public.mark_all_inbox_read(p_group_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_count integer;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = 'P0001';
  end if;
  with upd as (
    update public.notifications_outbox
       set read_at = now()
     where recipient_user_id = v_uid
       and read_at is null
       and (p_group_id is null or group_id = p_group_id)
    returning 1
  )
  select count(*)::int into v_count from upd;
  return coalesce(v_count, 0);
end $$;

grant execute on function public.mark_all_inbox_read(uuid) to authenticated;

create or replace function public.my_inbox_unread_count(p_group_id uuid default null)
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  select coalesce(count(*)::int, 0)
  from public.notifications_outbox
  where recipient_user_id = auth.uid()
    and read_at is null
    and (p_group_id is null or group_id = p_group_id);
$$;

grant execute on function public.my_inbox_unread_count(uuid) to authenticated;
