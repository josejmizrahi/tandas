-- ============================================================================
-- _smoke_r5_governance — verifica R.5 Governance Engine end-to-end.
-- ============================================================================
-- Casos:
--   C1  governance_policies / vote_delegations / governance_actions + RLS existen
--   C2  create/update/list_governance_policies (upsert) + reader governance_policy
--   C3  weighted voting (5.3): vote_weight_source=shares => peso del voto vía trigger
--   C4  vote delegation (5.2): el delegado vota con peso propio + delegado; revoke
--   C5  consent voting (5.4): sin objeciones => approved; con objeción => rejected
--   C6  quorum (5.3/gov): sin quórum suficiente => rejected en close_decision
--   C7  mandatory governance (5.6): remove_member bloqueado sin decisión aprobada;
--       request_governed_action + aprobación habilita la remoción + auditoría
--   C8  authority: un member sin decisions.execute NO puede fijar políticas (42501)
-- Contextos sin políticas se comportan igual (backward-compat) — cubierto por
-- los smokes mvp2_m7 / r2q que siguen pasando.
-- ============================================================================
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

  -- Setup: contexto con 3 miembros activos (A admin/creador, B y C members)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_r5 Consejo', 'collective', 'project'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- C1: tablas + RLS
  if not exists (select 1 from information_schema.tables where table_schema='public' and table_name='governance_policies') then
    raise exception 'r5 C1a: governance_policies missing'; end if;
  if not exists (select 1 from information_schema.tables where table_schema='public' and table_name='vote_delegations') then
    raise exception 'r5 C1b: vote_delegations missing'; end if;
  if not exists (select 1 from information_schema.tables where table_schema='public' and table_name='governance_actions') then
    raise exception 'r5 C1c: governance_actions missing'; end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='governance_policies' and c.relrowsecurity=true) then
    raise exception 'r5 C1d: RLS not enabled on governance_policies'; end if;

  -- C2: create/update/list/reader (A es admin)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.create_governance_policy(v_ctx, 'expense_threshold', '5000'::jsonb);
  perform public.update_governance_policy(v_ctx, 'expense_threshold', '8000'::jsonb);
  if public.governance_policy(v_ctx, 'expense_threshold') <> '8000'::jsonb then
    raise exception 'r5 C2a: upsert no actualizó expense_threshold'; end if;
  if jsonb_array_length(public.list_governance_policies(v_ctx)) < 1 then
    raise exception 'r5 C2b: list_governance_policies vacío'; end if;

  -- C8: member B no puede fijar políticas
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_caught := false;
  begin
    perform public.create_governance_policy(v_ctx, 'quorum', '0.5'::jsonb);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'r5 C8: member fijó política sin autoridad'; end if;

  -- C3: weighted voting por shares (B tiene 3 votos)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.update_governance_policy(v_ctx, 'vote_weight_source',
    jsonb_build_object('source', 'shares', 'shares', jsonb_build_object(v_b::text, 3)));
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_d := (public.create_decision(v_ctx, 'generic', '_smoke_r5 weighted'))->>'decision_id';
  v_result := public.vote_decision(v_d, 'approve');
  select weight into v_weight from public.decision_votes where decision_id = v_d and voter_actor_id = v_b;
  if v_weight <> 3 then raise exception 'r5 C3: peso esperado 3, got %', v_weight; end if;
  -- 3 > 3/2 => aprobada por mayoría ponderada (vote_decision auto-finalize)
  if v_result->>'status' <> 'approved' then
    raise exception 'r5 C3: mayoría ponderada no aprobó (status %)', v_result->>'status'; end if;

  -- C4: delegación (volver a peso igualitario)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.update_governance_policy(v_ctx, 'vote_weight_source', null); -- borra => equal
  -- C delega su voto en B
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  perform public.delegate_vote(v_ctx, v_b);
  -- B vota: peso = propio(1) + delegado de C(1) = 2
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_d := (public.create_decision(v_ctx, 'generic', '_smoke_r5 delegation'))->>'decision_id';
  v_result := public.vote_decision(v_d, 'approve');
  select weight into v_weight from public.decision_votes where decision_id = v_d and voter_actor_id = v_b;
  if v_weight <> 2 then raise exception 'r5 C4: peso delegado esperado 2, got %', v_weight; end if;
  -- C revoca
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  v_result := public.revoke_vote_delegation(v_ctx);
  if not (v_result->>'revoked')::boolean then raise exception 'r5 C4: revoke falló'; end if;

  -- C5: consent voting
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.update_governance_policy(v_ctx, 'consent_voting', 'true'::jsonb);
  -- D sin objeciones: B aprueba (1 de 3 => no auto-finaliza), A cierra => approved
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_d := (public.create_decision(v_ctx, 'generic', '_smoke_r5 consent ok'))->>'decision_id';
  perform public.vote_decision(v_d, 'approve');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.close_decision(v_d);
  if v_result->>'status' <> 'approved' then
    raise exception 'r5 C5a: consent sin objeción no aprobó (%)', v_result->>'status'; end if;
  -- D con objeción: C rechaza => rejected
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_d := (public.create_decision(v_ctx, 'generic', '_smoke_r5 consent block'))->>'decision_id';
  perform public.vote_decision(v_d, 'approve');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  perform public.vote_decision(v_d, 'reject');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.close_decision(v_d);
  if v_result->>'status' <> 'rejected' then
    raise exception 'r5 C5b: consent con objeción no rechazó (%)', v_result->>'status'; end if;

  -- C6: quorum (sin consent)
  perform public.update_governance_policy(v_ctx, 'consent_voting', null);
  perform public.update_governance_policy(v_ctx, 'quorum', '0.9'::jsonb);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_d := (public.create_decision(v_ctx, 'generic', '_smoke_r5 quorum'))->>'decision_id';
  perform public.vote_decision(v_d, 'approve'); -- 1 voto de 3, no alcanza 90%
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.close_decision(v_d);
  if v_result->>'status' <> 'rejected' then
    raise exception 'r5 C6: sin quórum debió rechazar (%)', v_result->>'status'; end if;
  if not (v_result->'tally'->'governance'->>'quorum_met')::boolean = false then
    raise exception 'r5 C6: quorum_met debió ser false'; end if;
  perform public.update_governance_policy(v_ctx, 'quorum', null);

  -- C7: mandatory governance (member_ban_requires_vote)
  perform public.update_governance_policy(v_ctx, 'member_ban_requires_vote', 'true'::jsonb);
  -- remove_member sin decisión aprobada => bloqueado
  v_caught := false;
  begin
    perform public.remove_member(v_ctx, v_c, 'sin voto');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'r5 C7a: remove_member procedió sin gobernanza'; end if;
  -- proponer la acción gobernada
  v_result := public.request_governed_action(v_ctx, 'member_ban', 'actor', v_c, '{}'::jsonb, 'Banear a C');
  if not (v_result->>'requires_decision')::boolean then
    raise exception 'r5 C7b: la acción debió requerir decisión'; end if;
  v_d := (v_result->>'decision_id')::uuid;
  v_ga := (v_result->>'governance_action_id')::uuid;
  -- aprobar la decisión (A + B => mayoría con peso igual)
  perform public.vote_decision(v_d, 'approve');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.vote_decision(v_d, 'approve');
  if v_result->>'status' <> 'approved' then
    raise exception 'r5 C7c: decisión de ban no aprobó (%)', v_result->>'status'; end if;
  -- ahora A puede remover
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.remove_member(v_ctx, v_c, 'aprobado por consejo');
  if not (v_result->>'removed')::boolean then raise exception 'r5 C7d: remove_member falló tras aprobación'; end if;
  if (v_result->>'governance_action_id') is null then raise exception 'r5 C7e: no linkeó governance_action'; end if;
  select status into v_status from public.governance_actions where id = v_ga;
  if v_status <> 'executed' then raise exception 'r5 C7f: governance_action no quedó executed (%)', v_status; end if;
  select membership_status into v_status from public.actor_memberships
   where context_actor_id = v_ctx and member_actor_id = v_c;
  if v_status <> 'removed' then raise exception 'r5 C7g: C no quedó removido (%)', v_status; end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.governance_actions where context_actor_id = v_ctx;
  delete from public.vote_delegations where context_actor_id = v_ctx;
  delete from public.governance_policies where context_actor_id = v_ctx;
  delete from public.decision_votes where decision_id in (select id from public.decisions where context_actor_id = v_ctx);
  delete from public.decision_options where decision_id in (select id from public.decisions where context_actor_id = v_ctx);
  delete from public.decisions where context_actor_id = v_ctx;
  delete from public.activity_events where context_actor_id = v_ctx;
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
  'Smoke R.5: governance_policies, delegación, weighted/consent/quorum voting, mandatory governance.';
