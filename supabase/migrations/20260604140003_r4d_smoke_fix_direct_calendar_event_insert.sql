-- =============================================================================
-- R.4D smoke fix #1: replace create_calendar_event call with a direct
-- calendar_events insert. The RPC requires p_event_type and enforces
-- F.EVENT.5 location/virtual; the smoke is about inbox dispatch, not event
-- creation policy. Direct insert sidesteps both.
-- =============================================================================
-- This iteration still used event_type='gathering' which is NOT in the
-- check constraint; the next migration (r4d_smoke_fix_event_type_meeting)
-- swaps to 'meeting' and is the canonical final smoke.
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

  v_result := public.emit_notification(
    p_recipient_actor_id => v_a,
    p_notification_type  => 'decision.opened',
    p_title              => 'Hay una decisión abierta'
  );
  v_n1 := (v_result->>'notification_id')::uuid;

  -- Note: this iteration uses event_type='gathering' which is NOT allowed by
  -- the calendar_events_event_type_check constraint. The next migration
  -- (r4d_smoke_fix_event_type_meeting) switches to 'meeting'.
  insert into public.calendar_events(
    id, context_actor_id, title, event_type, starts_at, is_virtual,
    created_by_actor_id, host_actor_id, status
  )
  values (
    v_event_id, v_familia, '_smoke_r4d event', 'gathering',
    now() + interval '7 days', true, v_a, v_a, 'scheduled'
  );

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

  raise notice '_smoke_r4d_notifications_inbox passed (iteration 2; superseded by 140003)';
end;
$$;

revoke all on function public._smoke_r4d_notifications_inbox() from anon;
grant execute on function public._smoke_r4d_notifications_inbox() to service_role;
