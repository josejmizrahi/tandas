create or replace function public._smoke_r5_governance()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_auth_c uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_c uuid; v_ctx uuid;
  v_code text;
  v_result jsonb;
  v_d uuid;
  v_weight numeric;
  v_ga uuid;
  v_status text;
  v_caught boolean;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, '_smoke_r5 A', '+520000000970', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, '_smoke_r5 B', '+520000000971', null);
  v_c := public._create_person_actor_for_auth_user(v_auth_c, '_smoke_r5 C', '+520000000972', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_r5 Consejo', 'collective', 'project'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  perform public.join_by_invite_code(v_code);

  if not exists (select 1 from information_schema.tables where table_schema='public' and table_name='governance_policies') then
    raise exception 'r5 C1a: governance_policies missing'; end if;
  if not exists (select 1 from information_schema.tables where table_schema='public' and table_name='vote_delegations') then
    raise exception 'r5 C1b: vote_delegations missing'; end if;
  if not exists (select 1 from information_schema.tables where table_schema='public' and table_name='governance_actions') then
    raise exception 'r5 C1c: governance_actions missing'; end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='governance_policies' and c.relrowsecurity=true) then
    raise exception 'r5 C1d: RLS not enabled on governance_policies'; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.create_governance_policy(v_ctx, 'expense_threshold', '5000'::jsonb);
  perform public.update_governance_policy(v_ctx, 'expense_threshold', '8000'::jsonb);
  if public.governance_policy(v_ctx, 'expense_threshold') <> '8000'::jsonb then
    raise exception 'r5 C2a: upsert no actualizo expense_threshold'; end if;
  if jsonb_array_length(public.list_governance_policies(v_ctx)) < 1 then
    raise exception 'r5 C2b: list_governance_policies vacio'; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_caught := false;
  begin
    perform public.create_governance_policy(v_ctx, 'quorum', '0.5'::jsonb);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'r5 C8: member fijo politica sin autoridad'; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.update_governance_policy(v_ctx, 'vote_weight_source',
    jsonb_build_object('source', 'shares', 'shares', jsonb_build_object(v_b::text, 3)));
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_d := (public.create_decision(v_ctx, 'generic', '_smoke_r5 weighted'))->>'decision_id';
  v_result := public.vote_decision(v_d, 'approve');
  select weight into v_weight from public.decision_votes where decision_id = v_d and voter_actor_id = v_b;
  if v_weight <> 3 then raise exception 'r5 C3: peso esperado 3, got %', v_weight; end if;
  if v_result->>'status' <> 'approved' then
    raise exception 'r5 C3: mayoria ponderada no aprobo (status %)', v_result->>'status'; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.update_governance_policy(v_ctx, 'vote_weight_source', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  perform public.delegate_vote(v_ctx, v_b);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_d := (public.create_decision(v_ctx, 'generic', '_smoke_r5 delegation'))->>'decision_id';
  v_result := public.vote_decision(v_d, 'approve');
  select weight into v_weight from public.decision_votes where decision_id = v_d and voter_actor_id = v_b;
  if v_weight <> 2 then raise exception 'r5 C4: peso delegado esperado 2, got %', v_weight; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  v_result := public.revoke_vote_delegation(v_ctx);
  if not (v_result->>'revoked')::boolean then raise exception 'r5 C4: revoke fallo'; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.update_governance_policy(v_ctx, 'consent_voting', 'true'::jsonb);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_d := (public.create_decision(v_ctx, 'generic', '_smoke_r5 consent ok'))->>'decision_id';
  perform public.vote_decision(v_d, 'approve');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.close_decision(v_d);
  if v_result->>'status' <> 'approved' then
    raise exception 'r5 C5a: consent sin objecion no aprobo (%)', v_result->>'status'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_d := (public.create_decision(v_ctx, 'generic', '_smoke_r5 consent block'))->>'decision_id';
  perform public.vote_decision(v_d, 'approve');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  perform public.vote_decision(v_d, 'reject');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.close_decision(v_d);
  if v_result->>'status' <> 'rejected' then
    raise exception 'r5 C5b: consent con objecion no rechazo (%)', v_result->>'status'; end if;

  perform public.update_governance_policy(v_ctx, 'consent_voting', null);
  perform public.update_governance_policy(v_ctx, 'quorum', '0.9'::jsonb);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_d := (public.create_decision(v_ctx, 'generic', '_smoke_r5 quorum'))->>'decision_id';
  perform public.vote_decision(v_d, 'approve');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.close_decision(v_d);
  if v_result->>'status' <> 'rejected' then
    raise exception 'r5 C6: sin quorum debio rechazar (%)', v_result->>'status'; end if;
  if (v_result->'tally'->'governance'->>'quorum_met')::boolean <> false then
    raise exception 'r5 C6: quorum_met debio ser false'; end if;
  perform public.update_governance_policy(v_ctx, 'quorum', null);

  perform public.update_governance_policy(v_ctx, 'member_ban_requires_vote', 'true'::jsonb);
  v_caught := false;
  begin
    perform public.remove_member(v_ctx, v_c, 'sin voto');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'r5 C7a: remove_member procedio sin gobernanza'; end if;
  v_result := public.request_governed_action(v_ctx, 'member_ban', 'actor', v_c, '{}'::jsonb, 'Banear a C');
  if not (v_result->>'requires_decision')::boolean then
    raise exception 'r5 C7b: la accion debio requerir decision'; end if;
  v_d := (v_result->>'decision_id')::uuid;
  v_ga := (v_result->>'governance_action_id')::uuid;
  perform public.vote_decision(v_d, 'approve');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.vote_decision(v_d, 'approve');
  if v_result->>'status' <> 'approved' then
    raise exception 'r5 C7c: decision de ban no aprobo (%)', v_result->>'status'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.remove_member(v_ctx, v_c, 'aprobado por consejo');
  if not (v_result->>'removed')::boolean then raise exception 'r5 C7d: remove_member fallo tras aprobacion'; end if;
  if (v_result->>'governance_action_id') is null then raise exception 'r5 C7e: no linkeo governance_action'; end if;
  select status into v_status from public.governance_actions where id = v_ga;
  if v_status <> 'executed' then raise exception 'r5 C7f: governance_action no quedo executed (%)', v_status; end if;
  select membership_status into v_status from public.actor_memberships
   where context_actor_id = v_ctx and member_actor_id = v_c;
  if v_status <> 'removed' then raise exception 'r5 C7g: C no quedo removido (%)', v_status; end if;

  perform set_config('request.jwt.claims', null, true);
  delete from public.governance_actions where context_actor_id = v_ctx;
  delete from public.vote_delegations where context_actor_id = v_ctx;
  delete from public.governance_policies where context_actor_id = v_ctx;
  delete from public.decision_votes where decision_id in (select id from public.decisions where context_actor_id = v_ctx);
  delete from public.decision_options where decision_id in (select id from public.decisions where context_actor_id = v_ctx);
  delete from public.decisions where context_actor_id = v_ctx;
  delete from public.context_invites where context_actor_id = v_ctx;
  delete from public.role_assignments where context_actor_id = v_ctx;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx;
  delete from public.roles where context_actor_id = v_ctx;
  delete from public.actor_memberships where context_actor_id = v_ctx;
  delete from public.actors where id = v_ctx;
  delete from public.person_profiles where actor_id in (v_a, v_b, v_c);
  delete from public.actors where id in (v_a, v_b, v_c);
  delete from auth.users where id in (v_auth_a, v_auth_b, v_auth_c);

  raise notice '_smoke_r5_governance passed (C1-C8)';
end;
$$;

revoke all on function public._smoke_r5_governance() from public, anon, authenticated;
grant execute on function public._smoke_r5_governance() to service_role;

comment on function public._smoke_r5_governance() is
  'Smoke R.5 (canonico): governance_policies, delegacion, weighted/consent/quorum voting, mandatory governance.';
