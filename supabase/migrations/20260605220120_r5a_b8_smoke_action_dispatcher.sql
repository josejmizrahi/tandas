create or replace function public._smoke_r5a_b8_action_dispatcher()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caught boolean;
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid;
  v_ctx uuid;
  v_res uuid;
  v_actions jsonb;
  v_result jsonb;
  v_count int;
begin
  -- C1: setup
  v_a := public._create_person_actor_for_auth_user(v_auth_a, '_smoke_b8 A', '+520000000911', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, '_smoke_b8 B', '+520000000912', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_b8 ctx', 'collective', 'project'))->>'context_actor_id';
  v_res := (public.create_resource(v_ctx, 'cash_pool', '_smoke_b8 Fondo', null, null, 'MXN', '{}'::jsonb))->>'resource_id';

  -- C2: resource_action_dispatch seedeado (>=16 mappings)
  select count(*) into v_count from public.resource_action_dispatch;
  if v_count < 16 then
    raise exception 'r5a.b8 C2: expected >=16 dispatch mappings, got %', v_count; end if;

  -- C3: list_resource_actions devuelve array con shape extendido
  v_actions := public.list_resource_actions(v_res);
  if jsonb_typeof(v_actions) <> 'array' then
    raise exception 'r5a.b8 C3a: list_resource_actions no es array'; end if;
  if jsonb_array_length(v_actions) = 0 then
    raise exception 'r5a.b8 C3b: lista vacia (cash_pool deberia tener monetary actions)'; end if;
  if exists (select 1 from jsonb_array_elements(v_actions) e
             where not (e ?& array['action_key','mode','dangerous','confirmation_required','form_schema_present'])) then
    raise exception 'r5a.b8 C3c: action items sin shape extendido'; end if;

  -- C4: execute happy path -- record_expense
  v_result := public.execute_resource_action(
    v_res,
    'record_expense',
    jsonb_build_object(
      'amount', 100,
      'currency', 'MXN',
      'description', 'smoke test expense',
      'beneficiaries', jsonb_build_array(v_a::text),
      'split_method', 'equal'
    ),
    gen_random_uuid()
  );
  if jsonb_typeof(v_result) <> 'object' then
    raise exception 'r5a.b8 C4a: execute no devolvio object'; end if;
  if v_result->>'action_key' <> 'record_expense' then
    raise exception 'r5a.b8 C4b: action_key wrong'; end if;
  if v_result->>'mode' <> 'execute' then
    raise exception 'r5a.b8 C4c: mode wrong: %', v_result->>'mode'; end if;
  if v_result->>'delegated_to_rpc' <> 'record_expense' then
    raise exception 'r5a.b8 C4d: delegated_to_rpc wrong'; end if;
  if v_result->>'activity_event_id' is null then
    raise exception 'r5a.b8 C4e: no activity_event_id emitted'; end if;

  -- C5: action invalida raise 42501
  v_caught := false;
  begin
    perform public.execute_resource_action(v_res, '_does_not_exist', '{}'::jsonb, null);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b8 C5: action invalida no fue rechazada'; end if;

  -- C6: action no disponible en este resource (terminate_lease, no leasable)
  v_caught := false;
  begin
    perform public.execute_resource_action(v_res, 'terminate_lease', '{}'::jsonb, null);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b8 C6: terminate_lease no rechazada (cash_pool no es leasable)'; end if;

  -- C7: non-member B rechazado
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_caught := false;
  begin
    perform public.list_resource_actions(v_res);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b8 C7a: non-member pudo list'; end if;

  v_caught := false;
  begin
    perform public.execute_resource_action(v_res, 'record_expense', '{}'::jsonb, null);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b8 C7b: non-member pudo execute'; end if;

  -- C8: resource inexistente
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_caught := false;
  begin
    perform public.execute_resource_action(gen_random_uuid(), 'record_expense', '{}'::jsonb, null);
  exception when sqlstate 'P0002' then v_caught := true;
            when others then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b8 C8: resource inexistente no rechazado'; end if;

  -- C9: dispatcher seed cubre las 2 acciones request_decision
  if not exists (select 1 from public.resource_action_dispatch where action_key='transfer_ownership') then
    raise exception 'r5a.b8 C9a: dispatch no incluye transfer_ownership'; end if;
  if not exists (select 1 from public.resource_action_dispatch where action_key='request_transfer') then
    raise exception 'r5a.b8 C9b: dispatch no incluye request_transfer'; end if;

  -- cleanup
  begin
    delete from public.activity_events where resource_id = v_res;
    delete from public.resources where id = v_res;
    delete from public.actor_memberships where context_actor_id = v_ctx;
    delete from public.actors where id = v_ctx;
    delete from public.actors where id in (v_a, v_b);
  exception when others then null; end;

  raise notice '_smoke_r5a_b8_action_dispatcher OK (dispatch mapping + list_resource_actions + execute happy path + gate + non-member + not_found + request_decision wiring)';
end;
$$;

revoke all on function public._smoke_r5a_b8_action_dispatcher() from public, anon;
grant execute on function public._smoke_r5a_b8_action_dispatcher() to authenticated, service_role;
