-- ============================================================================
-- R.5A.B.8 fixup: alinear dispatcher con signatures reales de los RPCs vivos.
--   - record_expense: split_with uuid[], client_id text, +paid_by/splits/excluded
--   - cancel_reservation: solo p_reservation_id
--   - check_in_participant: +p_checked_in_at
--   - close_event: solo p_event_id
--   - create_decision: arg order distinto (context, type, title, desc, closes_at,
--                      payload, client_id text, voting_model, template_key)
--   - request_resource_reservation: 8 args distintos
-- ============================================================================
create or replace function public.execute_resource_action(
  p_resource_id uuid,
  p_action_key text,
  p_payload jsonb default '{}'::jsonb,
  p_client_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_actor uuid;
  v_owner uuid;
  v_available jsonb;
  v_action_entry jsonb;
  v_mode text;
  v_template_key text;
  v_result jsonb;
  v_decision_id uuid;
  v_event_id uuid;
  v_delegated_rpc text;
  v_split_with uuid[];
  v_client_id_text text;
begin
  if auth.uid() is null then raise exception 'unauthenticated' using errcode='42501'; end if;
  v_actor := public.current_actor_id();
  if v_actor is null then raise exception 'missing person actor' using errcode='42501'; end if;

  select canonical_owner_actor_id into v_owner from public.resources where id = p_resource_id;
  if v_owner is null then raise exception 'resource not found' using errcode='P0002'; end if;
  if not (v_actor = v_owner or public.is_context_member(v_owner)) then
    raise exception 'not a member of resource context' using errcode='42501';
  end if;

  v_available := public.resource_available_actions(p_resource_id, v_actor);
  select a into v_action_entry
    from jsonb_array_elements(v_available) a
   where a->>'action_key' = p_action_key
   limit 1;

  if v_action_entry is null then
    raise exception 'action % not available for resource % (capability or right missing)', p_action_key, p_resource_id
      using errcode='42501';
  end if;
  if not (v_action_entry->>'enabled')::boolean then
    raise exception 'action % not enabled: %', p_action_key, coalesce(v_action_entry->>'reason', 'unknown')
      using errcode='42501';
  end if;

  select rac.execution_mode, rac.decision_template_key, rad.rpc_name
    into v_mode, v_template_key, v_delegated_rpc
    from public.resource_action_catalog rac
    left join public.resource_action_dispatch rad on rad.action_key = rac.action_key
   where rac.action_key = p_action_key;

  v_mode := coalesce(v_mode, 'execute');
  v_client_id_text := p_client_id::text;

  if v_mode = 'request_decision' then
    if v_template_key is null then
      raise exception 'action % marked request_decision but missing decision_template_key', p_action_key
        using errcode='0A000';
    end if;
    v_decision_id := (public.create_decision(
      v_owner,
      coalesce(p_payload->>'decision_type', 'resources'),
      coalesce(p_payload->>'title', 'Solicitud: ' || p_action_key),
      coalesce(p_payload->>'description', ''),
      (p_payload->>'closes_at')::timestamptz,
      jsonb_build_object('resource_id', p_resource_id, 'action_key', p_action_key, 'requested_payload', p_payload),
      v_client_id_text,
      coalesce(p_payload->>'voting_model', 'single_choice'),
      v_template_key
    ))->>'decision_id';
    v_result := jsonb_build_object('decision_id', v_decision_id);
    v_delegated_rpc := 'create_decision';
  else
    case p_action_key
      when 'record_expense' then
        select array_agg(value::uuid) into v_split_with
          from jsonb_array_elements_text(coalesce(p_payload->'beneficiaries', '[]'::jsonb));
        v_result := public.record_expense(
          v_owner,
          (p_payload->>'amount')::numeric,
          coalesce(p_payload->>'currency', 'MXN'),
          coalesce(p_payload->>'description', ''),
          coalesce(v_split_with, array[]::uuid[]),
          (p_payload->>'event_id')::uuid,
          coalesce(p_payload->'metadata', '{}'::jsonb),
          v_client_id_text,
          v_actor,
          coalesce(p_payload->>'split_method', 'equal'),
          coalesce(p_payload->'splits', '[]'::jsonb),
          array[]::uuid[]
        );

      when 'grant_right' then
        v_result := public.grant_right(
          p_resource_id,
          (p_payload->>'holder_actor_id')::uuid,
          p_payload->>'right_kind',
          (p_payload->>'percent')::numeric,
          p_payload->>'scope',
          (p_payload->>'starts_at')::timestamptz,
          (p_payload->>'ends_at')::timestamptz,
          coalesce(p_payload->'metadata', '{}'::jsonb)
        );

      when 'revoke_right' then
        perform public.revoke_right((p_payload->>'right_id')::uuid);
        v_result := jsonb_build_object('revoked', true, 'right_id', p_payload->>'right_id');

      when 'archive_resource' then
        v_result := public.archive_resource(p_resource_id);

      when 'update_resource', 'edit_resource' then
        v_result := public.update_resource(
          p_resource_id,
          p_payload->>'display_name',
          p_payload->>'description',
          (p_payload->>'estimated_value')::numeric,
          p_payload->>'currency',
          coalesce(p_payload->'metadata', '{}'::jsonb),
          p_payload->>'location_text'
        );

      when 'reserve_resource', 'create_reservation' then
        v_result := public.request_resource_reservation(
          p_resource_id,
          v_owner,
          (p_payload->>'starts_at')::timestamptz,
          (p_payload->>'ends_at')::timestamptz,
          coalesce((p_payload->>'reserved_for_actor_id')::uuid, v_actor),
          coalesce(p_payload->'metadata', '{}'::jsonb),
          v_client_id_text,
          (p_payload->>'source_event_id')::uuid
        );

      when 'cancel_reservation' then
        perform public.cancel_reservation((p_payload->>'reservation_id')::uuid);
        v_result := jsonb_build_object('cancelled', true);

      when 'rsvp_event' then
        v_result := public.rsvp_event(p_resource_id, p_payload->>'response');

      when 'check_in_participant' then
        v_result := public.check_in_participant(
          p_resource_id,
          (p_payload->>'participant_actor_id')::uuid,
          coalesce((p_payload->>'checked_in_at')::timestamptz, now())
        );

      when 'close_event' then
        v_result := public.close_event(p_resource_id);

      else
        raise exception 'action % not_implemented in dispatcher (B.8 conservador; agrega mapping en mig posterior)', p_action_key
          using errcode='0A000';
    end case;
  end if;

  begin
    insert into public.activity_events
      (context_actor_id, actor_id, event_type, subject_type, subject_id, resource_id, payload, occurred_at)
    values
      (v_owner, v_actor, 'resource.action_executed', 'resource', p_resource_id, p_resource_id,
       jsonb_build_object('action_key', p_action_key, 'mode', v_mode, 'delegated_to_rpc', v_delegated_rpc,
                          'decision_id', v_decision_id),
       now())
    returning id into v_event_id;
  exception when others then
    v_event_id := null;
  end;

  return jsonb_build_object(
    'action_key', p_action_key,
    'mode', v_mode,
    'delegated_to_rpc', v_delegated_rpc,
    'result', v_result,
    'decision_id', v_decision_id,
    'activity_event_id', v_event_id,
    'idempotent_hit', false
  );
end;
$$;

revoke all on function public.execute_resource_action(uuid, text, jsonb, uuid) from public, anon;
grant execute on function public.execute_resource_action(uuid, text, jsonb, uuid) to authenticated, service_role;
