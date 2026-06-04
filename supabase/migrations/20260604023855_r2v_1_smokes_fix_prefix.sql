create or replace function public._smoke_r2v_context_similarity()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_papa uuid := gen_random_uuid();
  v_jose uuid; v_papa uuid;
  v_proyecto_nave uuid; v_proyecto_toluca uuid; v_distinto uuid;
  v_code text;
  v_result jsonb;
  v_top jsonb;
  v_top_score numeric;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'r2vcs José', '+520000001001', null);
  v_papa := public._create_person_actor_for_auth_user(v_auth_papa, 'r2vcs Papa', '+520000001002', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  -- Nombres sin prefijo común largo (pg_trgm inflaría artificialmente el score).
  v_proyecto_nave := (public.create_context('Proyecto Nave Industrial r2v', 'collective', 'project')->>'context_actor_id')::uuid;
  v_proyecto_toluca := (public.create_context('Proyecto Toluca r2v', 'collective', 'project')->>'context_actor_id')::uuid;
  v_distinto := (public.create_context('Cumpleaños Lola r2v', 'collective', 'friend_group')->>'context_actor_id')::uuid;

  v_code := (public.create_invite(v_proyecto_nave))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_code := (public.create_invite(v_proyecto_toluca))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_code := (public.create_invite(v_distinto))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  perform public.create_resource(v_proyecto_nave,   'property', 'Terreno Toluca r2v');
  perform public.create_resource(v_proyecto_toluca, 'property', 'Terreno Toluca r2v');
  perform public.create_resource(v_distinto,        'other',    'Pastel Cumple r2v');

  v_result := public.context_similarity(v_proyecto_nave);
  if jsonb_array_length(v_result) = 0 then
    raise exception 'r2v_cs C1: similarity vacío';
  end if;
  v_top := v_result->0;
  if (v_top->>'context_id')::uuid <> v_proyecto_toluca then
    raise exception 'r2v_cs C1: top candidate no es Proyecto Toluca (fue %)', v_top->>'context_id';
  end if;
  v_top_score := (v_top->>'score')::numeric;
  if v_top_score < 0.40 then
    raise exception 'r2v_cs C1: score de Proyecto Toluca demasiado bajo (%)', v_top_score;
  end if;

  if not (v_top->'reasons' ? 'shared_members') then
    raise exception 'r2v_cs C2: top no marcó shared_members (reasons: %)', v_top->'reasons';
  end if;
  if not (v_top->'reasons' ? 'shared_resources') then
    raise exception 'r2v_cs C2: top no marcó shared_resources';
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_result) e
    where (e->>'context_id')::uuid = v_distinto
  ) then
    raise exception 'r2v_cs C3: Cumpleaños Lola apareció';
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_result) e
    where (e->>'context_id')::uuid = v_proyecto_nave
  ) then
    raise exception 'r2v_cs C4: el contexto fuente se devolvió a sí mismo';
  end if;

  perform set_config('request.jwt.claims', null, true);
  delete from public.resource_rights where resource_id in (
    select id from public.resources where canonical_owner_actor_id in (v_proyecto_nave, v_proyecto_toluca, v_distinto)
  );
  delete from public.resources where canonical_owner_actor_id in (v_proyecto_nave, v_proyecto_toluca, v_distinto);
  delete from public.context_invites where context_actor_id in (v_proyecto_nave, v_proyecto_toluca, v_distinto);
  delete from public.role_assignments where context_actor_id in (v_proyecto_nave, v_proyecto_toluca, v_distinto);
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id in (v_proyecto_nave, v_proyecto_toluca, v_distinto);
  delete from public.roles where context_actor_id in (v_proyecto_nave, v_proyecto_toluca, v_distinto);
  delete from public.actor_memberships where context_actor_id in (v_proyecto_nave, v_proyecto_toluca, v_distinto);
  delete from public.actors where id in (v_proyecto_nave, v_proyecto_toluca, v_distinto);
  delete from public.person_profiles where actor_id in (v_jose, v_papa);
  delete from public.actors where id in (v_jose, v_papa);
  delete from auth.users where id in (v_auth_jose, v_auth_papa);

  raise notice '_smoke_r2v_context_similarity passed (4 casos)';
end; $$;
revoke all on function public._smoke_r2v_context_similarity() from public, anon, authenticated;

create or replace function public._smoke_r2v_resource_similarity()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_jose uuid;
  v_familia uuid;
  v_casa_a uuid; v_casa_b uuid; v_cuenta uuid;
  v_result jsonb;
  v_top jsonb;
  v_top_score numeric;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'r2vrs José', '+520000001003', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);

  v_familia := (public.create_context('Familia r2v rs', 'collective', 'family')->>'context_actor_id')::uuid;

  v_casa_a := (public.create_resource(v_familia, 'house', 'Casa Valle r2v')->>'resource_id')::uuid;
  v_casa_b := (public.create_resource(v_familia, 'house', 'Casa Valle de los Abuelos r2v')->>'resource_id')::uuid;
  v_cuenta := (public.create_resource(v_familia, 'bank_account', 'Cuenta del Banco r2v')->>'resource_id')::uuid;

  v_result := public.resource_similarity(v_casa_a);
  if jsonb_array_length(v_result) = 0 then
    raise exception 'r2v_rs C1: similarity vacío';
  end if;
  v_top := v_result->0;
  if (v_top->>'resource_id')::uuid <> v_casa_b then
    raise exception 'r2v_rs C1: top no es Casa B (fue %)', v_top->>'resource_id';
  end if;

  v_top_score := (v_top->>'score')::numeric;
  if v_top_score < 0.6 then
    raise exception 'r2v_rs C2: score Casa B demasiado bajo (%)', v_top_score;
  end if;

  if not (v_top->'reasons' ? 'same_type') then
    raise exception 'r2v_rs C3: top no marcó same_type (reasons: %)', v_top->'reasons';
  end if;
  if not (v_top->'reasons' ? 'same_context') then
    raise exception 'r2v_rs C3: top no marcó same_context';
  end if;

  if (v_result->0->>'resource_id')::uuid = v_cuenta then
    raise exception 'r2v_rs C4: Cuenta como top';
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_result) e
    where (e->>'resource_id')::uuid = v_casa_a
  ) then
    raise exception 'r2v_rs C5: el recurso fuente se devolvió a sí mismo';
  end if;

  perform set_config('request.jwt.claims', null, true);
  delete from public.resource_rights where resource_id in (v_casa_a, v_casa_b, v_cuenta);
  delete from public.resources where id in (v_casa_a, v_casa_b, v_cuenta);
  delete from public.role_assignments where context_actor_id = v_familia;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = v_familia;
  delete from public.roles where context_actor_id = v_familia;
  delete from public.actor_memberships where context_actor_id = v_familia;
  delete from public.actors where id = v_familia;
  delete from public.person_profiles where actor_id = v_jose;
  delete from public.actors where id = v_jose;
  delete from auth.users where id = v_auth_jose;

  raise notice '_smoke_r2v_resource_similarity passed (5 casos)';
end; $$;
revoke all on function public._smoke_r2v_resource_similarity() from public, anon, authenticated;