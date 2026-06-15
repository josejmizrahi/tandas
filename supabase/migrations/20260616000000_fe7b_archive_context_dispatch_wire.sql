-- FE.7.B — wire `archive_context` en `_governance_action_dispatch`.
-- Doctrina: la mig fe7 (20260612192000) insertó context.archive en el catalog
-- con execution_rpc='archive_context' y push_supported=true, pero NO extendió
-- el dispatch (último update: r7_x_4 forgive_obligation). Resultado: decisión
-- aprobada por voto → trigger _governance_action_post_approval →
-- execute_governance_action → dispatch raise → row queda failed → el espacio
-- nunca se archiva. Esta mig agrega el case faltante manteniendo el patrón de
-- archive_rule/forgive_obligation.

create or replace function public._governance_action_dispatch(
  p_row public.governance_actions,
  p_catalog public.governance_action_catalog
) returns jsonb
language plpgsql security definer set search_path to public, auth
as $$
declare
  v_result jsonb;
  v_role_key text;
  v_target_state text;
begin
  case p_catalog.execution_rpc
    when 'assign_role' then
      v_role_key := coalesce(p_row.payload->>'role_key', p_catalog.metadata->>'role_key');
      if v_role_key is null then
        raise exception 'assign_role dispatch: role_key missing in payload and catalog metadata';
      end if;
      perform public.assign_role(p_row.context_actor_id, p_row.target_id, v_role_key);
      v_result := jsonb_build_object('execution_rpc','assign_role','target_id', p_row.target_id, 'role_key', v_role_key);

    when 'archive_resource' then
      if p_row.target_id is null then raise exception 'archive_resource dispatch: target_id required'; end if;
      perform public.archive_resource(p_row.target_id);
      v_result := jsonb_build_object('execution_rpc','archive_resource','resource_id', p_row.target_id);

    when 'record_fine' then
      if p_row.target_id is null then raise exception 'record_fine dispatch: target_id (debtor) required'; end if;
      if p_row.payload->>'amount' is null or p_row.payload->>'currency' is null then
        raise exception 'record_fine dispatch: payload.amount + payload.currency required';
      end if;
      perform public.record_fine(p_row.context_actor_id, p_row.target_id,
        (p_row.payload->>'amount')::numeric, p_row.payload->>'currency', p_row.payload->>'reason');
      v_result := jsonb_build_object('execution_rpc','record_fine','debtor_actor_id', p_row.target_id,
        'amount', (p_row.payload->>'amount')::numeric, 'currency', p_row.payload->>'currency');

    when 'create_rule' then
      if p_row.payload->>'title' is null then raise exception 'create_rule dispatch: payload.title required'; end if;
      v_result := public.create_rule(p_row.context_actor_id, p_row.payload->>'title',
        p_row.payload->>'trigger_event_type',
        nullif(p_row.payload->'condition_tree','null')::jsonb,
        nullif(p_row.payload->'consequences','null')::jsonb,
        p_row.payload->>'body', coalesce(p_row.payload->>'rule_type','automation'),
        coalesce((p_row.payload->>'severity')::int, 1));

    when 'set_membership_state' then
      if p_row.target_id is null then raise exception 'set_membership_state dispatch: target_id (member) required'; end if;
      v_target_state := coalesce(p_row.payload->>'target_state', p_catalog.metadata->>'target_state');
      if v_target_state is null then
        raise exception 'set_membership_state dispatch: target_state missing in payload and catalog metadata';
      end if;
      perform public.set_membership_state(p_row.context_actor_id, p_row.target_id, v_target_state, p_row.payload->>'reason');
      v_result := jsonb_build_object('execution_rpc','set_membership_state',
        'target_id', p_row.target_id, 'target_state', v_target_state);

    when 'transfer_resource_ownership' then
      if p_row.target_id is null then raise exception 'transfer_resource_ownership dispatch: target_id (resource) required'; end if;
      if p_row.payload->>'to_actor_id' is null then
        raise exception 'transfer_resource_ownership dispatch: payload.to_actor_id required';
      end if;
      if not exists (select 1 from public.actors where id = (p_row.payload->>'to_actor_id')::uuid) then
        raise exception 'transfer_resource_ownership dispatch: to_actor_id % not found in actors',
          p_row.payload->>'to_actor_id' using errcode = 'P0002';
      end if;
      perform public.transfer_resource_ownership(p_row.target_id,
        (p_row.payload->>'to_actor_id')::uuid, p_row.payload->>'reason');
      v_result := jsonb_build_object('execution_rpc','transfer_resource_ownership',
        'resource_id', p_row.target_id, 'to_actor_id', p_row.payload->>'to_actor_id');

    when 'archive_rule' then
      if p_row.target_id is null then raise exception 'archive_rule dispatch: target_id (rule) required'; end if;
      perform public.archive_rule(p_row.target_id, p_row.payload->>'reason');
      v_result := jsonb_build_object('execution_rpc','archive_rule','rule_id', p_row.target_id);

    when 'forgive_obligation' then
      if p_row.target_id is null then
        raise exception 'forgive_obligation dispatch: target_id (obligation) required';
      end if;
      perform public.forgive_obligation(p_row.target_id, p_row.payload->>'reason');
      v_result := jsonb_build_object('execution_rpc','forgive_obligation','obligation_id', p_row.target_id);

    when 'archive_context' then
      if p_row.target_id is null then
        raise exception 'archive_context dispatch: target_id (context_actor_id) required';
      end if;
      perform public.archive_context(p_row.target_id);
      v_result := jsonb_build_object('execution_rpc','archive_context','context_actor_id', p_row.target_id);

    else
      raise exception 'execute_governance_action: execution_rpc % not supported in R.7 dispatch',
        p_catalog.execution_rpc using errcode = 'P0001';
  end case;

  return v_result;
end;
$$;

comment on function public._governance_action_dispatch(public.governance_actions, public.governance_action_catalog) is
  'R.7 dispatch (extended FE.7.B): añade case archive_context. Trigger AFTER UPDATE governance_actions.status approved → execute_governance_action → este dispatch → archive_context(target_id).';

-- Smoke: dispatch case archive_context funciona end-to-end vía trigger.
-- NOTA: el path "decisión aprobada por close_decision → governance_actions.status='approved'"
-- es R.5/R.7 pre-existente (vote_decision auto-finaliza con 1 voto y close_decision
-- queda no-op si la decisión ya cerró; fuera del scope FE.7.B). Este smoke valida:
--   1) catalog: context.archive → execution_rpc='archive_context'.
--   2) _governance_action_dispatch tiene el case archive_context.
--   3) Trigger AFTER UPDATE on governance_actions.status='approved' ejecuta
--      execute_governance_action → dispatch → archive_context → actors.archived_at.
create or replace function public._smoke_mvp2_archive_context_dispatch()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_a uuid;
  v_ctx uuid;
  v_create jsonb;
  v_req jsonb;
  v_ga_id uuid;
  v_decision_id uuid;
  v_ga_row public.governance_actions%rowtype;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke ArchDisp A', '+520000000945', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_create := public.create_context('_smoke_archive_dispatch Club', 'collective', 'friend_group');
  v_ctx := (v_create->>'context_actor_id')::uuid;

  v_req := public.request_governance_action(
    p_context_actor_id := v_ctx,
    p_action_key := 'context.archive',
    p_target_type := 'actor',
    p_target_id := v_ctx,
    p_payload := '{}'::jsonb,
    p_title := 'Archivar smoke',
    p_client_id := 'smoke-archdisp-2'
  );
  if not coalesce((v_req->>'requires_decision')::boolean, false) then
    raise exception 'archive dispatch smoke: requires_decision esperado true con policy default';
  end if;
  v_ga_id := (v_req->>'governance_action_id')::uuid;
  v_decision_id := (v_req->>'decision_id')::uuid;

  -- Promovemos manualmente para disparar el trigger sin depender del flow close_decision.
  update public.decisions
     set status = 'approved', decided_at = now()
   where id = v_decision_id;
  update public.governance_actions
     set status = 'approved'
   where id = v_ga_id;

  select * into v_ga_row from public.governance_actions where id = v_ga_id;
  if v_ga_row.status <> 'executed' then
    raise exception 'archive dispatch smoke: governance_action status=% (esperado executed). error=%',
      v_ga_row.status, v_ga_row.error_message;
  end if;

  if not exists (select 1 from public.actors where id = v_ctx and archived_at is not null) then
    raise exception 'archive dispatch smoke: actors.archived_at no quedó seteado';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.governance_actions where context_actor_id = v_ctx;
  delete from public.decision_votes where decision_id in (select id from public.decisions where context_actor_id = v_ctx);
  delete from public.decisions where context_actor_id = v_ctx;
  delete from public.governance_policies where context_actor_id = v_ctx;
  delete from public.context_invites where context_actor_id = v_ctx;
  delete from public.role_assignments where context_actor_id = v_ctx;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = v_ctx;
  delete from public.roles where context_actor_id = v_ctx;
  delete from public.actor_memberships where context_actor_id = v_ctx;
  delete from public.actor_relationships
    where subject_actor_id in (v_a, v_ctx) or object_actor_id in (v_a, v_ctx);
  delete from public.actors where id = v_ctx;
  delete from public.person_profiles where actor_id = v_a;
  delete from public.actors where id = v_a;
  delete from auth.users where id = v_auth_a;

  raise notice '_smoke_mvp2_archive_context_dispatch passed';
end; $$;

revoke all on function public._smoke_mvp2_archive_context_dispatch() from public, anon, authenticated;

comment on function public._smoke_mvp2_archive_context_dispatch() is
  'Smoke FE.7.B: trigger AFTER UPDATE governance_actions.status=approved → execute_governance_action → _governance_action_dispatch case archive_context → public.archive_context(target_id) → actors.archived_at seteado.';
