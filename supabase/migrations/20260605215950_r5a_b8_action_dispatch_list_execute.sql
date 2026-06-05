-- ============================================================================
-- R.5A.B.8 — RESOURCE ACTION DISPATCHER
-- ============================================================================
-- 3 piezas:
--   1. resource_action_dispatch       (mapping action_key -> rpc_name doc)
--   2. list_resource_actions(rid)     (subset standalone del descriptor.actions)
--   3. execute_resource_action(rid, action_key, payload, client_id?)
--
-- DISPATCHER STRATEGY (conservador):
--   - Gate via resource_available_actions (single source of truth, F.2X canonical).
--   - Si execution_mode='request_decision': create_decision con template_key, return.
--   - Si execution_mode='execute': dispatch a RPC vivo via CASE explicito.
--   - Acciones sin mapping raise '0A000 not_implemented' con action_key.
--   - Siempre emite activity_event con event_type 'resource.action_executed'.
--   - Idempotency: pasa p_client_id al RPC delegado cuando aplica.
--
-- Founder plan §8: empezar con SOLO las 2 acciones marcadas request_decision
-- (request_transfer + transfer_ownership). Resto delega directo.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. resource_action_dispatch (mapping doc)
-- ----------------------------------------------------------------------------
create table public.resource_action_dispatch (
  action_key text primary key references public.resource_action_catalog(action_key) on update cascade on delete cascade,
  rpc_name text not null,
  notes text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);

comment on table public.resource_action_dispatch is
  'R.5A.B.8: mapping documental action_key -> RPC vivo. NO usado por execute_resource_action (que tiene CASE explicito por seguridad). Sirve a iOS para introspeccion.';

insert into public.resource_action_dispatch (action_key, rpc_name, notes) values
  ('record_expense',                 'record_expense',                'amount/currency/description/beneficiaries/split_method'),
  ('grant_right',                    'grant_right',                   'holder_actor_id/right_kind/percent/scope/ends_at'),
  ('revoke_right',                   'revoke_right',                  'right_id'),
  ('update_resource',                'update_resource',               'display_name/description/estimated_value/currency/location_text'),
  ('edit_resource',                  'update_resource',               'alias new -> existing RPC'),
  ('archive_resource',               'archive_resource',              'no payload'),
  ('reserve_resource',               'request_resource_reservation',  'starts_at/ends_at/purpose'),
  ('create_reservation',             'request_resource_reservation',  'alias'),
  ('approve_reservation',            'approve_reservation',           'reservation_id (from payload)'),
  ('cancel_reservation',             'cancel_reservation',            'reservation_id + reason'),
  ('rsvp_event',                     'rsvp_event',                    'resource_id IS event_id; response'),
  ('check_in_participant',           'check_in_participant',          'participant_actor_id'),
  ('close_event',                    'close_event',                   'optional summary'),
  ('request_transfer',               'create_decision',               'request_decision mode; template resource_transfer'),
  ('transfer_ownership',             'create_decision',               'request_decision mode + danger; template resource_transfer'),
  ('attach_document',                'register_document',             'file_url/name/kind')
on conflict (action_key) do nothing;

alter table public.resource_action_dispatch enable row level security;
create policy "resource_action_dispatch_read_all"
  on public.resource_action_dispatch for select to authenticated using (true);
grant select on public.resource_action_dispatch to authenticated;

-- ----------------------------------------------------------------------------
-- 2. list_resource_actions
-- ----------------------------------------------------------------------------
create or replace function public.list_resource_actions(p_resource_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_actor uuid;
  v_owner uuid;
  v_available jsonb;
  v_actions jsonb;
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

  select coalesce(jsonb_agg(jsonb_build_object(
           'action_key', a->>'action_key',
           'label', a->>'label',
           'section', a->>'section',
           'enabled', (a->>'enabled')::boolean,
           'reason', a->>'reason',
           'required_rights', a->'required_rights',
           'required_capability', rac.required_capability,
           'mode', rac.execution_mode,
           'decision_template_key', rac.decision_template_key,
           'form_schema_present', exists(
             select 1 from public.resource_action_forms raf
              where raf.action_key = a->>'action_key'
                and raf.form_schema <> '{}'::jsonb
                and (raf.form_schema->'fields' is null or raf.form_schema->'fields' <> '[]'::jsonb)
           ),
           'dangerous', coalesce(raf.dangerous, rac.dangerous, false),
           'confirmation_required', coalesce(raf.confirmation_required, rac.confirmation_required, false)
         ) order by (a->>'section'), (a->>'action_key')), '[]'::jsonb)
    into v_actions
    from jsonb_array_elements(v_available) a
    left join public.resource_action_catalog rac on rac.action_key = a->>'action_key'
    left join public.resource_action_forms raf on raf.action_key = a->>'action_key';

  return v_actions;
end;
$$;

comment on function public.list_resource_actions(uuid) is
  'R.5A.B.8: subset standalone del descriptor.actions[]. Refresh barato post-execute.';

revoke all on function public.list_resource_actions(uuid) from public, anon;
grant execute on function public.list_resource_actions(uuid) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. execute_resource_action (DISPATCHER)
-- ----------------------------------------------------------------------------
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

  if v_mode = 'request_decision' then
    if v_template_key is null then
      raise exception 'action % marked request_decision but missing decision_template_key', p_action_key
        using errcode='0A000';
    end if;
    v_decision_id := (public.create_decision(
      v_owner,
      coalesce(p_payload->>'title', 'Solicitud: ' || p_action_key),
      coalesce(p_payload->>'description', ''),
      coalesce(p_payload->>'decision_type', 'resources'),
      coalesce(p_payload->'voting_options', 'null'::jsonb),
      coalesce(p_payload->>'voting_model', 'single_choice'),
      jsonb_build_object('resource_id', p_resource_id, 'action_key', p_action_key, 'requested_payload', p_payload),
      p_client_id,
      v_template_key
    ))->>'decision_id';
    v_result := jsonb_build_object('decision_id', v_decision_id);
    v_delegated_rpc := 'create_decision';
  else
    case p_action_key
      when 'record_expense' then
        v_result := public.record_expense(
          v_owner,
          (p_payload->>'amount')::numeric,
          coalesce(p_payload->>'currency', 'MXN'),
          coalesce(p_payload->>'description', ''),
          coalesce(p_payload->'beneficiaries', '[]'::jsonb),
          coalesce(p_payload->>'split_method', 'equal'),
          (p_payload->>'event_id')::uuid,
          p_client_id
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
          (p_payload->>'starts_at')::timestamptz,
          (p_payload->>'ends_at')::timestamptz,
          p_payload->>'purpose',
          coalesce(p_payload->'metadata', '{}'::jsonb),
          p_client_id
        );

      when 'cancel_reservation' then
        perform public.cancel_reservation(
          (p_payload->>'reservation_id')::uuid,
          p_payload->>'reason'
        );
        v_result := jsonb_build_object('cancelled', true);

      when 'rsvp_event' then
        v_result := public.rsvp_event(p_resource_id, p_payload->>'response');

      when 'check_in_participant' then
        v_result := public.check_in_participant(p_resource_id, (p_payload->>'participant_actor_id')::uuid);

      when 'close_event' then
        v_result := public.close_event(p_resource_id, p_payload->>'summary');

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

comment on function public.execute_resource_action(uuid, text, jsonb, uuid) is
  'R.5A.B.8: dispatcher canonico. Gate via resource_available_actions; branch execute vs request_decision; delegate a RPCs vivos via CASE; emit activity_event. Acciones sin mapping raise 0A000.';

revoke all on function public.execute_resource_action(uuid, text, jsonb, uuid) from public, anon;
grant execute on function public.execute_resource_action(uuid, text, jsonb, uuid) to authenticated, service_role;
