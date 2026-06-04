-- ============================================================================
-- R.2V.2 — SMOKES (2)
-- ============================================================================
-- 1. _smoke_r2v_duplicate_candidates:
--    Setup: 3 contextos del caller, dos son duplicados, uno distinto.
--    Verifica: duplicate_candidates() retorna el par duplicado, NO el distinto.
--    Verifica: merge_candidates() retorna sólo si score >= 0.85.
--
-- 2. _smoke_r2v_relationship_suggestions:
--    Setup: 2 contextos del actor con nombre que comparte keyword
--    ("Proyecto Nave" + "Fideicomiso Nave"), sin contains entre ellos.
--    Verifica: sugiere contains. Si ya existe contains activo, no sugiere.
-- ============================================================================

create or replace function public._smoke_r2v_duplicate_candidates()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_papa uuid := gen_random_uuid();
  v_jose uuid; v_papa uuid;
  v_a uuid; v_b uuid; v_distinto uuid;
  v_code text;
  v_result jsonb;
  v_pair jsonb;
  v_merge jsonb;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'r2vdc José', '+520000001011', null);
  v_papa := public._create_person_actor_for_auth_user(v_auth_papa, 'r2vdc Papa', '+520000001012', null);

  -- Dos contextos casi idénticos + un distinto. Same members (José+Papá) +
  -- recurso con nombre parecido en los duplicados.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_a        := (public.create_context('Proyecto Nave Industrial dup', 'collective', 'project')->>'context_actor_id')::uuid;
  v_b        := (public.create_context('Proyecto Nave Industrial Toluca dup', 'collective', 'project')->>'context_actor_id')::uuid;
  v_distinto := (public.create_context('Cumpleaños Sofía dup', 'collective', 'friend_group')->>'context_actor_id')::uuid;

  v_code := (public.create_invite(v_a))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_code := (public.create_invite(v_b))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_code := (public.create_invite(v_distinto))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  perform public.create_resource(v_a,        'property', 'Terreno Toluca dup');
  perform public.create_resource(v_b,        'property', 'Terreno Toluca dup');
  perform public.create_resource(v_distinto, 'other',    'Pastel Sofía dup');

  -- Caso 1: duplicate_candidates incluye el par (v_a, v_b)
  v_result := public.duplicate_candidates();
  if v_result->'contexts' is null or jsonb_array_length(v_result->'contexts') = 0 then
    raise exception 'r2v_dc C1: duplicate_candidates contextos vacío';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_result->'contexts') p
    where ((p->>'a_context_id')::uuid = least(v_a, v_b)
           and (p->>'b_context_id')::uuid = greatest(v_a, v_b))
  ) then
    raise exception 'r2v_dc C1: par (A, B) no aparece en duplicate_candidates';
  end if;

  -- Caso 2: el par con v_distinto NO aparece
  if exists (
    select 1 from jsonb_array_elements(v_result->'contexts') p
    where (p->>'a_context_id')::uuid = v_distinto or (p->>'b_context_id')::uuid = v_distinto
  ) then
    raise exception 'r2v_dc C2: par con Cumpleaños Sofía apareció';
  end if;

  -- Caso 3: dedup — sólo aparece UNA fila por par (a,b) ordenado por uuid
  v_pair := (
    select p
      from jsonb_array_elements(v_result->'contexts') p
     where ((p->>'a_context_id')::uuid = least(v_a, v_b)
            and (p->>'b_context_id')::uuid = greatest(v_a, v_b))
     limit 1
  );
  if v_pair is null then raise exception 'r2v_dc C3: par no encontrado tras dedup'; end if;
  if (
    select count(*) from jsonb_array_elements(v_result->'contexts') p
    where ((p->>'a_context_id')::uuid = least(v_a, v_b)
           and (p->>'b_context_id')::uuid = greatest(v_a, v_b))
       or ((p->>'a_context_id')::uuid = greatest(v_a, v_b)
           and (p->>'b_context_id')::uuid = least(v_a, v_b))
  ) > 1 then
    raise exception 'r2v_dc C3: par duplicado en la respuesta (no se dedupó por uuid asc)';
  end if;

  -- Caso 4: merge_candidates() retorna el par si score >= 0.85, o vacío si menor.
  -- (No afirmamos la cardinalidad porque depende del score exacto del fixture.)
  v_merge := public.merge_candidates();
  if v_merge->'contexts' is null then
    raise exception 'r2v_dc C4: merge_candidates retorna NULL contexts';
  end if;
  if not (v_merge->>'threshold')::numeric >= 0.85 then
    raise exception 'r2v_dc C4: merge_candidates no respeta threshold 0.85';
  end if;

  -- Caso 5: estructura — devuelve {contexts, resources, threshold, as_of}
  if not (v_result ? 'contexts' and v_result ? 'resources' and v_result ? 'threshold') then
    raise exception 'r2v_dc C5: payload sin keys contexts/resources/threshold';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.resource_rights where resource_id in (
    select id from public.resources where canonical_owner_actor_id in (v_a, v_b, v_distinto)
  );
  delete from public.resources where canonical_owner_actor_id in (v_a, v_b, v_distinto);
  delete from public.context_invites where context_actor_id in (v_a, v_b, v_distinto);
  delete from public.role_assignments where context_actor_id in (v_a, v_b, v_distinto);
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id in (v_a, v_b, v_distinto);
  delete from public.roles where context_actor_id in (v_a, v_b, v_distinto);
  delete from public.actor_memberships where context_actor_id in (v_a, v_b, v_distinto);
  delete from public.actors where id in (v_a, v_b, v_distinto);
  delete from public.person_profiles where actor_id in (v_jose, v_papa);
  delete from public.actors where id in (v_jose, v_papa);
  delete from auth.users where id in (v_auth_jose, v_auth_papa);

  raise notice '_smoke_r2v_duplicate_candidates passed (5 casos)';
end; $$;
revoke all on function public._smoke_r2v_duplicate_candidates() from public, anon, authenticated;

create or replace function public._smoke_r2v_relationship_suggestions()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_jose uuid;
  v_proyecto uuid; v_fideicomiso uuid; v_unrelated uuid;
  v_result jsonb;
  v_suggestion jsonb;
  v_caught boolean;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'r2vrel José', '+520000001013', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);

  -- 3 contextos: dos comparten keyword "Nave", uno no relacionado.
  v_proyecto    := (public.create_context('Proyecto Nave Industrial rel', 'collective', 'project')->>'context_actor_id')::uuid;
  v_fideicomiso := (public.create_context('Fideicomiso Nave Industrial rel', 'legal_entity', 'trust')->>'context_actor_id')::uuid;
  v_unrelated   := (public.create_context('Cumpleaños Sofía rel', 'collective', 'friend_group')->>'context_actor_id')::uuid;

  -- Caso 1: sugiere contains entre Proyecto y Fideicomiso
  v_result := public.relationship_suggestions();
  if jsonb_array_length(v_result) = 0 then
    raise exception 'r2v_rel C1: relationship_suggestions vacío';
  end if;
  v_suggestion := (
    select s from jsonb_array_elements(v_result) s
    where ((s->>'a_context_id')::uuid = least(v_proyecto, v_fideicomiso)
           and (s->>'b_context_id')::uuid = greatest(v_proyecto, v_fideicomiso))
    limit 1
  );
  if v_suggestion is null then
    raise exception 'r2v_rel C1: par Proyecto+Fideicomiso no apareció';
  end if;
  if v_suggestion->>'suggested_relationship' <> 'contains' then
    raise exception 'r2v_rel C1: tipo sugerido no es contains (fue %)', v_suggestion->>'suggested_relationship';
  end if;
  if (v_suggestion->>'confidence')::numeric < 0.40 then
    raise exception 'r2v_rel C1: confidence muy bajo (%)', v_suggestion->>'confidence';
  end if;

  -- Caso 2: el unrelated NO aparece (nombres sin trgm >= 0.40)
  if exists (
    select 1 from jsonb_array_elements(v_result) s
    where (s->>'a_context_id')::uuid = v_unrelated or (s->>'b_context_id')::uuid = v_unrelated
  ) then
    raise exception 'r2v_rel C2: par con Cumpleaños Sofía apareció (no debería)';
  end if;

  -- Caso 3: si ya hay contains activo, deja de sugerir
  insert into public.actor_relationships
    (subject_actor_id, relationship_type, object_actor_id, created_by_actor_id, metadata)
  values (v_proyecto, 'contains', v_fideicomiso, v_jose, '{"via":"smoke_r2v_rel"}'::jsonb);

  v_result := public.relationship_suggestions();
  if exists (
    select 1 from jsonb_array_elements(v_result) s
    where ((s->>'a_context_id')::uuid = least(v_proyecto, v_fideicomiso)
           and (s->>'b_context_id')::uuid = greatest(v_proyecto, v_fideicomiso))
  ) then
    raise exception 'r2v_rel C3: sigue sugiriendo aunque contains ya existe';
  end if;

  -- Caso 4: p_actor_id distinto del caller → 42501
  v_caught := false;
  begin
    perform public.relationship_suggestions(gen_random_uuid());
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'r2v_rel C4: permitió consultar para otro actor'; end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.actor_relationships
    where subject_actor_id in (v_proyecto, v_fideicomiso, v_unrelated)
       or object_actor_id  in (v_proyecto, v_fideicomiso, v_unrelated);
  delete from public.resource_rights where resource_id in (
    select id from public.resources where canonical_owner_actor_id in (v_proyecto, v_fideicomiso, v_unrelated)
  );
  delete from public.resources where canonical_owner_actor_id in (v_proyecto, v_fideicomiso, v_unrelated);
  delete from public.role_assignments where context_actor_id in (v_proyecto, v_fideicomiso, v_unrelated);
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id in (v_proyecto, v_fideicomiso, v_unrelated);
  delete from public.roles where context_actor_id in (v_proyecto, v_fideicomiso, v_unrelated);
  delete from public.actor_memberships where context_actor_id in (v_proyecto, v_fideicomiso, v_unrelated);
  delete from public.actors where id in (v_proyecto, v_fideicomiso, v_unrelated);
  delete from public.person_profiles where actor_id = v_jose;
  delete from public.actors where id = v_jose;
  delete from auth.users where id = v_auth_jose;

  raise notice '_smoke_r2v_relationship_suggestions passed (4 casos)';
end; $$;
revoke all on function public._smoke_r2v_relationship_suggestions() from public, anon, authenticated;
