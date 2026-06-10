-- =============================================================================
-- R.4D smoke fix #2 (canonical final): swap event_type 'gathering' → 'meeting'
-- to satisfy calendar_events_event_type_check
-- (∈ {dinner, meeting, trip, game_night, community_event, deadline, other}).
-- This is the canonical, passing version of _smoke_r4d_notifications_inbox.
-- =============================================================================
create or replace function public._smoke_r4d_notifications_inbox()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid;
  v_familia uuid;
  v_event_id uuid := gen_random_uuid();
  v_n1 uuid; v_n2 uuid; v_n3 uuid;
  v_result jsonb;
  v_count int;
  v_delivery_count int;
  v_inbox jsonb;
  v_caught boolean;
  v_read_at timestamptz;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, '_smoke_r4d A', '+520000000960', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, '_smoke_r4d B', '+520000000961', null);

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_auth_a::text)::text, true);

  v_familia := (
    public.create_context('_smoke_r4d Familia','collective','family')->>'context_actor_id'
  )::uuid;

  -- C1
  if not exists (select 1 from information_schema.tables
                 where table_schema='public' and table_name='notifications') then
    raise exception 'r4d C1a: notifications table missing';
  end if;
  if not exists (select 1 from information_schema.tables
                 where table_schema='public' and table_name='notification_deliveries') then
    raise exception 'r4d C1b: notification_deliveries table missing';
  end if;
  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='notifications' and c.relrowsecurity=true
  ) then
    raise exception 'r4d C1c: RLS not enabled on notifications';
  end if;

  -- C2
  if not exists (select 1 from pg_indexes
                 where schemaname='public' and indexname='idx_notifications_recipient_status') then
    raise exception 'r4d C2: idx_notifications_recipient_status missing';
  end if;

  -- C3
  v_result := public.emit_notification(
    p_recipient_actor_id => v_a,
    p_notification_type  => 'decision.opened',
    p_title              => 'Hay una decisión abierta',
    p_body               => 'Vota cuando puedas',
    p_context_actor_id   => v_familia,
    p_target_type        => 'decision',
    p_target_id          => v_a
  );
  v_n1 := (v_result->>'notification_id')::uuid;
  if v_n1 is null then
    raise exception 'r4d C3a: emit_notification returned no notification_id';
  end if;
  select count(*) into v_delivery_count
    from public.notification_deliveries where notification_id = v_n1;
  if v_delivery_count <> 1 then
    raise exception 'r4d C3b: expected 1 default (in_app) delivery, got %', v_delivery_count;
  end if;

  -- C9
  v_caught := false;
  begin
    perform public.emit_notification(
      p_recipient_actor_id => v_a, p_notification_type  => 'x', p_title => '');
  exception when sqlstate '22023' then v_caught := true; end;
  if not v_caught then
    raise exception 'r4d C9a: empty title did not raise 22023';
  end if;
  v_caught := false;
  begin
    perform public.emit_notification(
      p_recipient_actor_id => v_a, p_notification_type => '', p_title => 'ok');
  exception when sqlstate '22023' then v_caught := true; end;
  if not v_caught then
    raise exception 'r4d C9b: empty notification_type did not raise 22023';
  end if;

  -- C4
  v_inbox := public.actor_inbox_items();
  if not exists (
    select 1 from jsonb_array_elements(v_inbox) item
    where item->>'kind' = 'notification' and (item->>'subject_id')::uuid = v_n1
  ) then
    raise exception 'r4d C4: notification not surfaced in inbox (inbox=%)', v_inbox;
  end if;

  -- C5
  v_result := public.mark_notification_read(v_n1);
  if (v_result->>'status') <> 'read' then
    raise exception 'r4d C5a: mark_notification_read did not return read status';
  end if;
  select read_at into v_read_at from public.notifications where id = v_n1;
  if v_read_at is null then
    raise exception 'r4d C5b: read_at not set after marking read';
  end if;

  -- C6
  v_inbox := public.actor_inbox_items();
  if exists (
    select 1 from jsonb_array_elements(v_inbox) item
    where item->>'kind' = 'notification' and (item->>'subject_id')::uuid = v_n1
  ) then
    raise exception 'r4d C6: read notification still in inbox without include_read';
  end if;

  -- C7
  v_result := public.emit_notification(
    p_recipient_actor_id => v_a, p_notification_type => 'decision.opened', p_title => 'Otra decisión');
  v_n2 := (v_result->>'notification_id')::uuid;
  perform public.mark_notification_archived(v_n2);
  v_inbox := public.actor_inbox_items(null, 50, true);
  if exists (
    select 1 from jsonb_array_elements(v_inbox) item
    where item->>'kind' = 'notification' and (item->>'subject_id')::uuid = v_n2
  ) then
    raise exception 'r4d C7: archived notification still in inbox';
  end if;

  -- C8
  v_result := public.emit_notification(
    p_recipient_actor_id => v_b, p_notification_type => 'decision.opened', p_title => 'Para B');
  v_n3 := (v_result->>'notification_id')::uuid;
  v_caught := false;
  begin
    perform public.mark_notification_read(v_n3);
  exception when sqlstate '42501' then v_caught := true; end;
  if not v_caught then
    raise exception 'r4d C8: cross-actor mark_read did not raise 42501';
  end if;

  -- C10
  perform public.emit_notification(p_recipient_actor_id => v_a,
    p_notification_type => 'rule.fired', p_title => 'Regla disparada');
  perform public.emit_notification(p_recipient_actor_id => v_a,
    p_notification_type => 'event.reminder', p_title => 'Recordatorio');
  v_result := public.mark_all_notifications_read();
  if (v_result->>'marked_read')::int < 2 then
    raise exception 'r4d C10: mark_all_notifications_read did not mark all unread (got %)',
      v_result->>'marked_read';
  end if;
  select count(*) into v_count from public.notifications
   where recipient_actor_id = v_a and status = 'unread';
  if v_count > 0 then
    raise exception 'r4d C10b: % unread remaining after mark_all_read', v_count;
  end if;

  -- C11: direct insert; event_type ∈ {dinner, meeting, trip, game_night,
  --      community_event, deadline, other}. is_virtual=true skips location.
  insert into public.calendar_events(
    id, context_actor_id, title, event_type, starts_at, is_virtual,
    created_by_actor_id, host_actor_id, status
  )
  values (
    v_event_id, v_familia, '_smoke_r4d event', 'meeting',
    now() + interval '7 days', true, v_a, v_a, 'scheduled'
  );
  insert into public.event_participants(event_id, participant_actor_id, status)
  values (v_event_id, v_b, 'invited')
  on conflict do nothing;

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_inbox := public.actor_inbox_items();
  if not exists (
    select 1 from jsonb_array_elements(v_inbox) item
    where item->>'kind' = 'rsvp_pending' and (item->>'cta_scope_id')::uuid = v_event_id
  ) then
    raise exception 'r4d C11: RSVP-pending event not in B inbox (inbox=%)', v_inbox;
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.notification_deliveries
    where notification_id in (
      select id from public.notifications where recipient_actor_id in (v_a, v_b));
  delete from public.notifications where recipient_actor_id in (v_a, v_b);
  delete from public.event_participants where event_id = v_event_id;
  delete from public.calendar_events where id = v_event_id;
  delete from public.role_assignments where context_actor_id = v_familia;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = v_familia;
  delete from public.roles where context_actor_id = v_familia;
  delete from public.actor_memberships where context_actor_id = v_familia;
  delete from public.actors where id = v_familia;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_r4d_notifications_inbox passed (11 casos)';
end;
$$;

revoke all on function public._smoke_r4d_notifications_inbox() from anon;
grant execute on function public._smoke_r4d_notifications_inbox() to service_role;
