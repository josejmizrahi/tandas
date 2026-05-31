create or replace function public.test_hostAssigned_atom_emission(
  p_group_id   uuid,
  p_host_id    uuid,
  p_creator_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource_id        uuid := gen_random_uuid();
  v_report             jsonb;
  v_assertion_error    text;
begin
  if not exists (
    select 1 from public.group_members
     where group_id = p_group_id and user_id = p_host_id and active = true
  ) then
    raise exception 'test_hostAssigned_atom_emission: p_host_id % is not an active member of group %', p_host_id, p_group_id;
  end if;
  if p_host_id = p_creator_id then
    raise exception 'test_hostAssigned_atom_emission: p_host_id and p_creator_id must differ (trigger skip rule)';
  end if;

  begin
    insert into public.resources (
      id, group_id, resource_type, status, metadata, created_by
    ) values (
      v_resource_id,
      p_group_id,
      'event',
      'scheduled',
      jsonb_build_object(
        'title',        'Test - hostAssigned regression guard',
        'starts_at',    to_char((now() + interval '1 day') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'host_id',      p_host_id,
        'cycle_number', 1
      ),
      p_creator_id
    );

    declare
      v_user_action_count  int;
      v_system_event_count int;
      v_member_id_in_atom  uuid;
      v_payload_in_atom    jsonb;
    begin
      select count(*) into v_user_action_count
        from public.user_actions
       where reference_id = v_resource_id
         and action_type = 'hostAssigned'
         and user_id = p_host_id;
      if v_user_action_count <> 1 then
        raise exception 'test_hostAssigned_atom_emission: expected 1 user_action(hostAssigned), got %', v_user_action_count;
      end if;

      select count(*), max(member_id), max(payload)
        into v_system_event_count, v_member_id_in_atom, v_payload_in_atom
        from public.system_events
       where resource_id = v_resource_id
         and event_type = 'hostAssigned';
      if v_system_event_count <> 1 then
        raise exception 'test_hostAssigned_atom_emission: expected 1 system_event(hostAssigned), got %', v_system_event_count;
      end if;

      if v_member_id_in_atom is null then
        raise exception 'test_hostAssigned_atom_emission: system_event.member_id is NULL - trigger failed to resolve user_id -> group_members.id';
      end if;
      if not exists (
        select 1 from public.group_members
         where id = v_member_id_in_atom
           and group_id = p_group_id
           and user_id  = p_host_id
      ) then
        raise exception 'test_hostAssigned_atom_emission: system_event.member_id % does not match an active group_members row', v_member_id_in_atom;
      end if;

      if v_payload_in_atom->>'title' is null then
        raise exception 'test_hostAssigned_atom_emission: payload missing required key title';
      end if;
      if v_payload_in_atom->>'starts_at' is null then
        raise exception 'test_hostAssigned_atom_emission: payload missing required key starts_at';
      end if;

      v_report := jsonb_build_object(
        'status', 'pass',
        'resource_id', v_resource_id,
        'host_user_id', p_host_id,
        'host_member_id', v_member_id_in_atom,
        'user_action_emitted', v_user_action_count = 1,
        'system_event_emitted', v_system_event_count = 1,
        'payload_keys', (select jsonb_agg(k) from jsonb_object_keys(v_payload_in_atom) k)
      );
    end;

    raise exception 'TEST_HOSTASSIGNED_ROLLBACK_SENTINEL';
  exception
    when others then
      get stacked diagnostics v_assertion_error = MESSAGE_TEXT;
      if v_assertion_error = 'TEST_HOSTASSIGNED_ROLLBACK_SENTINEL' then
        return v_report;
      end if;
      raise;
  end;
end;
$$;;
