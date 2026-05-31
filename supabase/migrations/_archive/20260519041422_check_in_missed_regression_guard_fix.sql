create or replace function public.test_checkInMissed_emission(
  p_group_id            uuid,
  p_resource_id         uuid,
  p_no_show_member_id   uuid,
  p_arrived_member_id   uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_report           jsonb;
  v_assertion_error  text;
  v_missed_count_for_no_show int;
  v_missed_count_for_arrived int;
begin
  if p_no_show_member_id = p_arrived_member_id then
    raise exception 'test_checkInMissed_emission: no_show + arrived members must differ';
  end if;
  if not exists (select 1 from public.group_members where id = p_no_show_member_id and group_id = p_group_id and active = true) then
    raise exception 'test_checkInMissed_emission: no_show member % invalid for group', p_no_show_member_id;
  end if;
  if not exists (select 1 from public.group_members where id = p_arrived_member_id and group_id = p_group_id and active = true) then
    raise exception 'test_checkInMissed_emission: arrived member % invalid for group', p_arrived_member_id;
  end if;

  begin
    insert into public.rsvp_actions (resource_id, member_id, status, recorded_at, metadata)
    values (p_resource_id, p_no_show_member_id, 'going', now(),
            jsonb_build_object('via', 'test_checkInMissed_emission'));
    insert into public.rsvp_actions (resource_id, member_id, status, recorded_at, metadata)
    values (p_resource_id, p_arrived_member_id, 'going', now(),
            jsonb_build_object('via', 'test_checkInMissed_emission'));
    insert into public.check_in_actions (resource_id, member_id, arrived_at, recorded_at, metadata)
    values (p_resource_id, p_arrived_member_id, now(), now(),
            jsonb_build_object('via', 'test_checkInMissed_emission', 'check_in_method', 'self'));

    perform public.record_system_event(
      p_group_id    => p_group_id,
      p_event_type  => 'eventClosed',
      p_resource_id => p_resource_id,
      p_member_id   => null,
      p_payload     => jsonb_build_object('via', 'test_checkInMissed_emission')
    );

    select count(*) into v_missed_count_for_no_show
      from public.system_events
     where resource_id = p_resource_id
       and member_id   = p_no_show_member_id
       and event_type  = 'checkInMissed';
    if v_missed_count_for_no_show <> 1 then
      raise exception 'test_checkInMissed_emission: expected 1 checkInMissed for no-show member, got %', v_missed_count_for_no_show;
    end if;

    select count(*) into v_missed_count_for_arrived
      from public.system_events
     where resource_id = p_resource_id
       and member_id   = p_arrived_member_id
       and event_type  = 'checkInMissed';
    if v_missed_count_for_arrived <> 0 then
      raise exception 'test_checkInMissed_emission: arrived member should NOT have checkInMissed, got %', v_missed_count_for_arrived;
    end if;

    perform public.record_system_event(
      p_group_id    => p_group_id,
      p_event_type  => 'eventClosed',
      p_resource_id => p_resource_id,
      p_member_id   => null,
      p_payload     => jsonb_build_object('via', 'test_checkInMissed_emission_retry')
    );
    select count(*) into v_missed_count_for_no_show
      from public.system_events
     where resource_id = p_resource_id
       and member_id   = p_no_show_member_id
       and event_type  = 'checkInMissed';
    if v_missed_count_for_no_show <> 1 then
      raise exception 'test_checkInMissed_emission: re-emit produced duplicate (idempotency broken), count=%', v_missed_count_for_no_show;
    end if;

    v_report := jsonb_build_object(
      'status', 'pass',
      'no_show_member', p_no_show_member_id,
      'arrived_member', p_arrived_member_id,
      'checkInMissed_for_no_show', 1,
      'checkInMissed_for_arrived', 0,
      'idempotent_on_reclose', true
    );

    raise exception 'TEST_CHECKINMISSED_ROLLBACK_SENTINEL';
  exception
    when others then
      get stacked diagnostics v_assertion_error = MESSAGE_TEXT;
      if v_assertion_error = 'TEST_CHECKINMISSED_ROLLBACK_SENTINEL' then
        return v_report;
      end if;
      raise;
  end;
end;
$$;;
