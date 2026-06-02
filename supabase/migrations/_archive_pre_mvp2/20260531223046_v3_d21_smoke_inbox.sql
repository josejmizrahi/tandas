-- D.21B — _smoke_inbox: validate read_at column, list/mark/count RPCs against synthetic outbox rows
create or replace function public._smoke_inbox()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_group_count int;
  v_uid uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid();
  v_id1 uuid;
  v_id2 uuid;
  v_id3 uuid;
  v_inbox jsonb;
  v_unread int;
  v_marked int;
begin
  select count(*) into v_group_count from public.groups;
  if v_group_count > 50 then
    raise exception 'refusing to run smoke: too many groups (%)', v_group_count using errcode = 'P0001';
  end if;

  -- seed three outbox rows: two for v_uid (one read, one unread eventually), one for v_other
  insert into public.notifications_outbox (recipient_user_id, category, payload)
    values (v_uid, 'test.inbox', '{"message":"first"}'::jsonb) returning id into v_id1;
  insert into public.notifications_outbox (recipient_user_id, category, payload)
    values (v_uid, 'test.inbox', '{"message":"second"}'::jsonb) returning id into v_id2;
  insert into public.notifications_outbox (recipient_user_id, category, payload)
    values (v_other, 'test.inbox', '{"message":"foreign"}'::jsonb) returning id into v_id3;

  -- impersonate v_uid
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_uid::text)::text, true);

  -- 1. list_my_inbox returns 2 (only own)
  v_inbox := public.list_my_inbox();
  if jsonb_array_length(v_inbox) <> 2 then
    raise exception '_smoke_inbox: list_my_inbox expected 2, got %', jsonb_array_length(v_inbox);
  end if;

  -- 2. unread count = 2
  v_unread := public.my_inbox_unread_count();
  if v_unread <> 2 then
    raise exception '_smoke_inbox: unread expected 2, got %', v_unread;
  end if;

  -- 3. mark_inbox_read on id1
  perform public.mark_inbox_read(v_id1);
  v_unread := public.my_inbox_unread_count();
  if v_unread <> 1 then
    raise exception '_smoke_inbox: after mark unread expected 1, got %', v_unread;
  end if;

  -- 4. mark_inbox_read on foreign id (should be no-op)
  perform public.mark_inbox_read(v_id3);
  if (select read_at from public.notifications_outbox where id = v_id3) is not null then
    raise exception '_smoke_inbox: foreign mark must be no-op';
  end if;

  -- 5. list with unread_only
  v_inbox := public.list_my_inbox(p_unread_only := true);
  if jsonb_array_length(v_inbox) <> 1 then
    raise exception '_smoke_inbox: unread_only expected 1, got %', jsonb_array_length(v_inbox);
  end if;

  -- 6. mark_all_inbox_read
  v_marked := public.mark_all_inbox_read();
  if v_marked <> 1 then
    raise exception '_smoke_inbox: mark_all expected 1 affected, got %', v_marked;
  end if;
  if public.my_inbox_unread_count() <> 0 then
    raise exception '_smoke_inbox: after mark_all unread should be 0';
  end if;

  -- cleanup
  delete from public.notifications_outbox where id in (v_id1, v_id2, v_id3);
  perform set_config('request.jwt.claims', null, true);

  raise notice '_smoke_inbox passed';
end $$;
