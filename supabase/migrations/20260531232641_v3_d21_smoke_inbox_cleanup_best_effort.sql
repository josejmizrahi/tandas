-- D.21D: make _smoke_inbox cleanup best-effort so it runs in non-superuser contexts
-- (e.g. Supabase branch MCP) without crashing. The 6 substantive Inbox MVP
-- assertions run before the cleanup block, so a cleanup error after they pass
-- still means the feature is verified. On prod the smoke self-refuses
-- (v_group_count > 50) so orphan rows are impossible there.

CREATE OR REPLACE FUNCTION public._smoke_inbox()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
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

  -- Best-effort cleanup. Requires SUPERUSER for set_config('session_replication_role')
  -- to bypass the append-only guard on notifications_outbox. If we lack that
  -- privilege (e.g. Supabase branch MCP), silently skip — the substantive
  -- assertions above already passed, and the only side effect is a handful
  -- of orphan rows in an ephemeral environment. On prod the smoke self-refuses
  -- via the v_group_count guard above, so this path is dead there.
  begin
    perform set_config('session_replication_role', 'replica', true);
    delete from public.notifications_outbox where id in (v_id1, v_id2, v_id3);
    delete from auth.users where id in (v_uid, v_other);
    perform set_config('session_replication_role', 'origin', true);
  exception
    when insufficient_privilege then
      null;
  end;
  perform set_config('request.jwt.claims', null, true);

  raise notice '_smoke_inbox passed';
end $function$;
