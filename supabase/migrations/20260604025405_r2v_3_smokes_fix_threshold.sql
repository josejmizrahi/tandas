create or replace function public._smoke_r2v_creation_guard()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_jose uuid;
  v_proyecto uuid; v_unrelated uuid;
  v_resource_a uuid;
  v_ctx_result jsonb;
  v_res_result jsonb;
  v_top jsonb;
  v_caught boolean;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'r2vcg José', '+520000001022', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);

  v_proyecto := (public.create_context('Proyecto Nave Industrial cg', 'collective', 'project')->>'context_actor_id')::uuid;
  v_unrelated := (public.create_context('Cumpleaños Sofía cg', 'collective', 'friend_group')->>'context_actor_id')::uuid;
  v_resource_a := (public.create_resource(v_proyecto, 'house', 'Casa Valle cg')->>'resource_id')::uuid;

  v_ctx_result := public.context_creation_candidates('Proyecto Nave Industrial Toluca cg');
  if jsonb_array_length(v_ctx_result) = 0 then
    raise exception 'r2v_cg C1: context_creation_candidates vacío';
  end if;
  v_top := v_ctx_result->0;
  if (v_top->>'context_id')::uuid <> v_proyecto then
    raise exception 'r2v_cg C1: top no es Proyecto (fue %)', v_top->>'context_id';
  end if;

  v_ctx_result := public.context_creation_candidates('Reunión secreta zzz');
  if jsonb_array_length(v_ctx_result) <> 0 then
    raise exception 'r2v_cg C2: nombre distinto devolvió candidates (% items)', jsonb_array_length(v_ctx_result);
  end if;

  v_ctx_result := public.context_creation_candidates('');
  if jsonb_array_length(v_ctx_result) <> 0 then
    raise exception 'r2v_cg C3: nombre vacío devolvió candidates';
  end if;

  v_ctx_result := public.context_creation_candidates('Proyecto Nave Industrial cg');
  if jsonb_array_length(v_ctx_result) = 0 then
    raise exception 'r2v_cg C4: nombre idéntico no devolvió candidates';
  end if;
  v_top := v_ctx_result->0;
  if not (v_top->>'high_confidence')::boolean then
    raise exception 'r2v_cg C4: high_confidence no true (score %)', v_top->>'score';
  end if;

  v_res_result := public.resource_creation_candidates('Casa Valle de los Abuelos cg', v_proyecto);
  if jsonb_array_length(v_res_result) = 0 then
    raise exception 'r2v_cg C5: resource_creation_candidates vacío';
  end if;
  if (v_res_result->0->>'resource_id')::uuid <> v_resource_a then
    raise exception 'r2v_cg C5: top resource no es Casa Valle cg';
  end if;

  v_caught := false;
  declare
    v_other_context uuid;
    v_auth_other uuid := gen_random_uuid();
    v_other uuid;
  begin
    v_other := public._create_person_actor_for_auth_user(v_auth_other, 'r2vcg Other', '+520000001023', null);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_other::text)::text, true);
    v_other_context := (public.create_context('Otro contexto cg', 'collective', 'project')->>'context_actor_id')::uuid;
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);

    begin
      perform public.resource_creation_candidates('Casa Valle cg', v_other_context);
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'r2v_cg C6: permitió consultar resource_creation en contexto ajeno'; end if;

    delete from public.role_assignments where context_actor_id = v_other_context;
    delete from public.role_permissions rp using public.roles r
      where r.id = rp.role_id and r.context_actor_id = v_other_context;
    delete from public.roles where context_actor_id = v_other_context;
    delete from public.actor_memberships where context_actor_id = v_other_context;
    delete from public.actors where id = v_other_context;
    delete from public.person_profiles where actor_id = v_other;
    delete from public.actors where id = v_other;
    delete from auth.users where id = v_auth_other;
  end;

  perform set_config('request.jwt.claims', null, true);
  delete from public.resource_rights where resource_id = v_resource_a;
  delete from public.resources where id = v_resource_a;
  delete from public.role_assignments where context_actor_id in (v_proyecto, v_unrelated);
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id in (v_proyecto, v_unrelated);
  delete from public.roles where context_actor_id in (v_proyecto, v_unrelated);
  delete from public.actor_memberships where context_actor_id in (v_proyecto, v_unrelated);
  delete from public.actors where id in (v_proyecto, v_unrelated);
  delete from public.person_profiles where actor_id = v_jose;
  delete from public.actors where id = v_jose;
  delete from auth.users where id = v_auth_jose;

  raise notice '_smoke_r2v_creation_guard passed (6 casos)';
end; $$;
revoke all on function public._smoke_r2v_creation_guard() from public, anon, authenticated;