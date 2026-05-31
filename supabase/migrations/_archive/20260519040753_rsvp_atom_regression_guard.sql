-- Diagnostic that exercises on_rsvp_action_inserted_emit_atom by inserting
-- two synthetic rsvp_actions rows for the same (resource, member) inside a
-- sub-transaction, asserts both atoms emitted with valid FKs, then rolls
-- back via sentinel. Non-destructive.
create or replace function public.test_rsvp_atom_emission(
  p_group_id    uuid,
  p_resource_id uuid,
  p_member_id   uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_report           jsonb;
  v_assertion_error  text;
  v_submitted_count  int;
  v_changed_count    int;
  v_starts_at        timestamptz;
begin
  if not exists (
    select 1 from public.group_members
     where id = p_member_id and group_id = p_group_id and active = true
  ) then
    raise exception 'test_rsvp_atom_emission: p_member_id % is not an active member of group %', p_member_id, p_group_id;
  end if;
  if not exists (
    select 1 from public.resources
     where id = p_resource_id and group_id = p_group_id and resource_type = 'event'
  ) then
    raise exception 'test_rsvp_atom_emission: p_resource_id % is not an event in group %', p_resource_id, p_group_id;
  end if;

  -- For the test we temporarily put starts_at within 24h so the
  -- rsvpChangedSameDay branch can fire deterministically. We pull
  -- the existing starts_at first so we can restore (also rolled
  -- back by the sentinel).
  begin
    -- Force starts_at = now() + 1 hour for the duration of this test.
    update public.resources
       set metadata = jsonb_set(
         metadata,
         '{starts_at}',
         to_jsonb(to_char((now() + interval '1 hour') at time zone 'UTC',
                          'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
       )
     where id = p_resource_id;

    -- First atom: pending (should emit rsvpSubmitted, NOT rsvpChangedSameDay).
    insert into public.rsvp_actions (resource_id, member_id, status, recorded_at, metadata)
    values (p_resource_id, p_member_id, 'pending', now(),
            jsonb_build_object('via', 'test_rsvp_atom_emission'));

    -- Second atom: going (should emit BOTH).
    insert into public.rsvp_actions (resource_id, member_id, status, recorded_at, metadata)
    values (p_resource_id, p_member_id, 'going', now(),
            jsonb_build_object('via', 'test_rsvp_atom_emission'));

    -- Assert counts.
    select count(*) into v_submitted_count
      from public.system_events
     where resource_id = p_resource_id
       and member_id   = p_member_id
       and event_type  = 'rsvpSubmitted'
       and payload->>'via' = 'test_rsvp_atom_emission';
    if v_submitted_count <> 2 then
      raise exception 'test_rsvp_atom_emission: expected 2 rsvpSubmitted atoms, got %', v_submitted_count;
    end if;

    select count(*) into v_changed_count
      from public.system_events
     where resource_id = p_resource_id
       and member_id   = p_member_id
       and event_type  = 'rsvpChangedSameDay'
       and payload->>'via' = 'test_rsvp_atom_emission';
    if v_changed_count <> 1 then
      raise exception 'test_rsvp_atom_emission: expected 1 rsvpChangedSameDay atom (second insert), got %', v_changed_count;
    end if;

    -- Assert member_id is FK-valid (no NULL).
    if exists (
      select 1 from public.system_events
       where resource_id = p_resource_id
         and event_type in ('rsvpSubmitted','rsvpChangedSameDay')
         and payload->>'via' = 'test_rsvp_atom_emission'
         and member_id is null
    ) then
      raise exception 'test_rsvp_atom_emission: a system_event has NULL member_id';
    end if;

    -- Assert previous_status is in the change payload.
    if not exists (
      select 1 from public.system_events
       where resource_id = p_resource_id
         and member_id   = p_member_id
         and event_type  = 'rsvpChangedSameDay'
         and payload->>'previous_status' = 'pending'
         and payload->>'via' = 'test_rsvp_atom_emission'
    ) then
      raise exception 'test_rsvp_atom_emission: rsvpChangedSameDay payload missing previous_status=pending';
    end if;

    v_report := jsonb_build_object(
      'status', 'pass',
      'rsvpSubmitted_count', v_submitted_count,
      'rsvpChangedSameDay_count', v_changed_count,
      'resource_id', p_resource_id,
      'member_id', p_member_id
    );

    raise exception 'TEST_RSVP_ATOM_ROLLBACK_SENTINEL';
  exception
    when others then
      get stacked diagnostics v_assertion_error = MESSAGE_TEXT;
      if v_assertion_error = 'TEST_RSVP_ATOM_ROLLBACK_SENTINEL' then
        return v_report;
      end if;
      raise;
  end;
end;
$$;

revoke execute on function public.test_rsvp_atom_emission(uuid, uuid, uuid) from public, anon, authenticated;

comment on function public.test_rsvp_atom_emission(uuid, uuid, uuid) is
  'Mig 00337 guard: sub-transaction diagnostic that exercises trg_on_rsvp_action_emit_system_event end-to-end. Always rolls back. Throws on regression.';;
