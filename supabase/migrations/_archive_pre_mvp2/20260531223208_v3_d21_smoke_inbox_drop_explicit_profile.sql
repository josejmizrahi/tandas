-- D.21B fix2 — profiles row is auto-created by trigger on auth.users insert
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

  insert into auth.users (id) values (v_uid), (v_other);

  insert into public.notifications_outbox (recipient_user_id, category, payload)
    values (v_uid, 'test.inbox', '{"message":"first"}'::jsonb) returning id into v_id1;
  insert into public.notifications_outbox (recipient_user_id, category, payload)
    values (v_uid, 'test.inbox', '{"message":"second"}'::jsonb) returning id into v_id2;
  insert into public.notifications_outbox (recipient_user_id, category, payload)
    values (v_other, 'test.inbox', '{"message":"foreign"}'::jsonb) returning id into v_id3;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_uid::text)::text, true);

  v_inbox := public.list_my_inbox();
  if jsonb_array_length(v_inbox) <> 2 then
    raise exception '_smoke_inbox: list_my_inbox expected 2, got %', jsonb_array_length(v_inbox);
  end if;

  v_unread := public.my_inbox_unread_count();
  if v_unread <> 2 then
    raise exception '_smoke_inbox: unread expected 2, got %', v_unread;
  end if;

  perform public.mark_inbox_read(v_id1);
  if public.my_inbox_unread_count() <> 1 then
    raise exception '_smoke_inbox: after mark expected 1';
  end if;

  perform public.mark_inbox_read(v_id3);
  if (select read_at from public.notifications_outbox where id = v_id3) is not null then
    raise exception '_smoke_inbox: foreign mark must be no-op';
  end if;

  v_inbox := public.list_my_inbox(p_unread_only := true);
  if jsonb_array_length(v_inbox) <> 1 then
    raise exception '_smoke_inbox: unread_only expected 1, got %', jsonb_array_length(v_inbox);
  end if;

  v_marked := public.mark_all_inbox_read();
  if v_marked <> 1 then
    raise exception '_smoke_inbox: mark_all expected 1 affected, got %', v_marked;
  end if;
  if public.my_inbox_unread_count() <> 0 then
    raise exception '_smoke_inbox: after mark_all expected 0';
  end if;

  delete from public.notifications_outbox where id in (v_id1, v_id2, v_id3);
  delete from auth.users where id in (v_uid, v_other);
  perform set_config('request.jwt.claims', null, true);

  raise notice '_smoke_inbox passed';
end $$;
