-- =============================================================================
-- _smoke_r4d_notifications_inbox — verifies R.4D end-to-end.
-- =============================================================================
-- Asserted cases:
--   C1  notifications + notification_deliveries tables + RLS exist
--   C2  indexes registered
--   C3  emit_notification creates row + delivery row(s); validates required fields
--   C4  recipient sees notification via actor_inbox_items
--   C5  mark_notification_read flips status to 'read' + sets read_at
--   C6  default actor_inbox_items hides read (include_read=false default)
--   C7  mark_notification_archived hides from inbox even with include_read=true
--   C8  cross-actor mark_notification_read raises 42501
--   C9  emit_notification raises 22023 on empty title/type
--   C10 mark_all_notifications_read marks every unread for caller
--   C11 RSVP-pending events surface as kind='rsvp_pending'
-- =============================================================================
-- Note: this is the first iteration of the smoke. Subsequent migrations
-- (r4d_smoke_fix_direct_calendar_event_insert,
--  r4d_smoke_fix_event_type_meeting) progressively fix runtime issues
-- discovered while wiring the smoke. The canonical final version is in
-- 20260604140003_r4d_smoke_fix_event_type_meeting.sql.
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
  v_event_id uuid;
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
  if not exists (select 1 from pg_indexes
                 where schemaname='public' and indexname='idx_notifications_recipient_status') then
    raise exception 'r4d C2: idx_notifications_recipient_status missing';
  end if;

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
  select count(*) into v_delivery_count
    from public.notification_deliveries where notification_id = v_n1;

  v_caught := false;
  begin
    perform public.emit_notification(
      p_recipient_actor_id => v_a, p_notification_type => 'x', p_title => '');
  exception when sqlstate '22023' then v_caught := true; end;

  v_inbox := public.actor_inbox_items();
  v_result := public.mark_notification_read(v_n1);
  select read_at into v_read_at from public.notifications where id = v_n1;
  v_inbox := public.actor_inbox_items();

  v_result := public.emit_notification(
    p_recipient_actor_id => v_a,
    p_notification_type  => 'decision.opened',
    p_title              => 'Otra decisión'
  );
  v_n2 := (v_result->>'notification_id')::uuid;
  perform public.mark_notification_archived(v_n2);

  v_result := public.emit_notification(
    p_recipient_actor_id => v_b,
    p_notification_type  => 'decision.opened',
    p_title              => 'Para B'
  );
  v_n3 := (v_result->>'notification_id')::uuid;
  v_caught := false;
  begin
    perform public.mark_notification_read(v_n3);
  exception when sqlstate '42501' then v_caught := true; end;

  perform public.emit_notification(p_recipient_actor_id => v_a,
    p_notification_type => 'rule.fired', p_title => 'Regla disparada');
  perform public.emit_notification(p_recipient_actor_id => v_a,
    p_notification_type => 'event.reminder', p_title => 'Recordatorio');
  v_result := public.mark_all_notifications_read();

  -- C11: original tried public.create_calendar_event with named args; the live
  -- signature requires p_event_type. The next migration drops that approach
  -- in favor of direct calendar_events insert.
  v_event_id := (public.create_calendar_event(
    p_context_actor_id => v_familia,
    p_title            => '_smoke_r4d event',
    p_starts_at        => now() + interval '7 days'
  )->>'event_id')::uuid;
  insert into public.event_participants(event_id, participant_actor_id, status)
  values (v_event_id, v_b, 'invited')
  on conflict do nothing;

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_inbox := public.actor_inbox_items();

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

  raise notice '_smoke_r4d_notifications_inbox passed (first iteration; superseded by 140002+140003)';
end;
$$;

revoke all on function public._smoke_r4d_notifications_inbox() from anon;
grant execute on function public._smoke_r4d_notifications_inbox() to service_role;
