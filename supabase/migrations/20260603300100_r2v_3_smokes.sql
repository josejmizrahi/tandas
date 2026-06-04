-- ============================================================================
-- R.2V.3 — SMOKES (2)
-- ============================================================================
-- 1. _smoke_r2v_merge_soft: merge_contexts marca metadata, NO mueve datos,
--    es idempotente, unmerge revierte. Activity emitida.
-- 2. _smoke_r2v_creation_guard: context_creation_candidates +
--    resource_creation_candidates devuelven matches con score >= 0.60.
-- ============================================================================

create or replace function public._smoke_r2v_merge_soft()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_jose uuid;
  v_source uuid; v_target uuid;
  v_result jsonb;
  v_meta jsonb;
  v_initial_members int;
  v_after_members int;
  v_caught boolean;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'r2vms José', '+520000001021', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);

  v_source := (public.create_context('Proyecto Toluca ms', 'collective', 'project')->>'context_actor_id')::uuid;
  v_target := (public.create_context('Proyecto Nave Industrial ms', 'collective', 'project')->>'context_actor_id')::uuid;

  -- Caso 1: merge marca metadata.r2v.merged_into
  v_result := public.merge_contexts(v_source, v_target);
  if v_result->>'status' <> 'soft_merged' then
    raise exception 'r2v_ms C1: status no soft_merged (fue %)', v_result->>'status';
  end if;
  if (v_result->>'already_merged')::boolean then
    raise exception 'r2v_ms C1: already_merged=true en primer merge';
  end if;
  select metadata into v_meta from public.actors where id = v_source;
  if (v_meta->'r2v'->>'merged_into')::uuid <> v_target then
    raise exception 'r2v_ms C1: metadata.r2v.merged_into incorrecto';
  end if;
  if v_meta->'r2v'->>'merge_status' <> 'soft_merged' then
    raise exception 'r2v_ms C1: merge_status no soft_merged';
  end if;

  -- Caso 2: source SIGUE visible (archived_at = NULL)
  if exists (select 1 from public.actors where id = v_source and archived_at is not null) then
    raise exception 'r2v_ms C2: source archivado (no debería en soft merge)';
  end if;

  -- Caso 3: NO mueve memberships (count members source = 1, target = 1, sin cambios)
  select count(*) into v_initial_members
    from public.actor_memberships
   where context_actor_id = v_source and membership_status = 'active';
  if v_initial_members <> 1 then
    raise exception 'r2v_ms C3: source memberships count != 1 (fue %)', v_initial_members;
  end if;
  select count(*) into v_after_members
    from public.actor_memberships
   where context_actor_id = v_target and membership_status = 'active';
  if v_after_members <> 1 then
    raise exception 'r2v_ms C3: target memberships count != 1 (fue %)', v_after_members;
  end if;

  -- Caso 4: idempotente — merge mismo par devuelve already_merged=true
  v_result := public.merge_contexts(v_source, v_target);
  if not (v_result->>'already_merged')::boolean then
    raise exception 'r2v_ms C4: segundo merge no marcó already_merged=true';
  end if;

  -- Caso 5: merge a OTRO target falla (requiere unmerge primero)
  declare
    v_other uuid;
  begin
    v_other := (public.create_context('Otro target ms', 'collective', 'project')->>'context_actor_id')::uuid;
    v_caught := false;
    begin
      perform public.merge_contexts(v_source, v_other);
    exception when invalid_parameter_value then v_caught := true;
    end;
    if not v_caught then raise exception 'r2v_ms C5: permitió re-merge a otro target sin unmerge'; end if;
    delete from public.role_assignments where context_actor_id = v_other;
    delete from public.role_permissions rp using public.roles r
      where r.id = rp.role_id and r.context_actor_id = v_other;
    delete from public.roles where context_actor_id = v_other;
    delete from public.actor_memberships where context_actor_id = v_other;
    delete from public.actors where id = v_other;
  end;

  -- Caso 6: activity context.merged emitida en el source
  if not exists (
    select 1 from public.activity_events
    where context_actor_id = v_source and event_type = 'context.merged'
  ) then
    raise exception 'r2v_ms C6: activity context.merged no emitida en source';
  end if;

  -- Caso 7: unmerge revierte metadata
  v_result := public.unmerge_context(v_source);
  if not (v_result->>'unmerged')::boolean then
    raise exception 'r2v_ms C7: unmerge no marcó unmerged=true';
  end if;
  select metadata into v_meta from public.actors where id = v_source;
  if v_meta ? 'r2v' then
    raise exception 'r2v_ms C7: metadata.r2v sigue presente tras unmerge';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.role_assignments where context_actor_id in (v_source, v_target);
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id in (v_source, v_target);
  delete from public.roles where context_actor_id in (v_source, v_target);
  delete from public.actor_memberships where context_actor_id in (v_source, v_target);
  delete from public.actors where id in (v_source, v_target);
  delete from public.person_profiles where actor_id = v_jose;
  delete from public.actors where id = v_jose;
  delete from auth.users where id = v_auth_jose;

  raise notice '_smoke_r2v_merge_soft passed (7 casos)';
end; $$;
revoke all on function public._smoke_r2v_merge_soft() from public, anon, authenticated;

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

  -- Caso 1: context_creation_candidates con nombre similar (trgm ≈ 0.80, supera 0.60 pero no 0.85)
  v_ctx_result := public.context_creation_candidates('Proyecto Nave Industrial Toluca cg');
  if jsonb_array_length(v_ctx_result) = 0 then
    raise exception 'r2v_cg C1: context_creation_candidates vacío para nombre similar';
  end if;
  v_top := v_ctx_result->0;
  if (v_top->>'context_id')::uuid <> v_proyecto then
    raise exception 'r2v_cg C1: top no es Proyecto (fue %)', v_top->>'context_id';
  end if;

  -- Caso 2: nombre totalmente distinto → no candidates
  v_ctx_result := public.context_creation_candidates('Reunión secreta zzz');
  if jsonb_array_length(v_ctx_result) <> 0 then
    raise exception 'r2v_cg C2: nombre distinto devolvió candidates (% items)', jsonb_array_length(v_ctx_result);
  end if;

  -- Caso 3: nombre vacío → array vacío sin error
  v_ctx_result := public.context_creation_candidates('');
  if jsonb_array_length(v_ctx_result) <> 0 then
    raise exception 'r2v_cg C3: nombre vacío devolvió candidates';
  end if;

  -- Caso 4: high_confidence marcado cuando score >= 0.85
  v_ctx_result := public.context_creation_candidates('Proyecto Nave Industrial cg');
  if jsonb_array_length(v_ctx_result) = 0 then
    raise exception 'r2v_cg C4: nombre idéntico no devolvió candidates';
  end if;
  v_top := v_ctx_result->0;
  if not (v_top->>'high_confidence')::boolean then
    raise exception 'r2v_cg C4: high_confidence no es true para nombre idéntico (score %)', v_top->>'score';
  end if;

  -- Caso 5: resource_creation_candidates encuentra match
  -- "Casa Valle Norte cg" vs "Casa Valle cg" → trgm ≈ 0.68 (supera 0.60)
  v_res_result := public.resource_creation_candidates('Casa Valle Norte cg', v_proyecto);
  if jsonb_array_length(v_res_result) = 0 then
    raise exception 'r2v_cg C5: resource_creation_candidates vacío para nombre similar';
  end if;
  if (v_res_result->0->>'resource_id')::uuid <> v_resource_a then
    raise exception 'r2v_cg C5: top resource no es Casa Valle cg';
  end if;

  -- Caso 6: resource_creation_candidates en contexto sin acceso → 42501
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

    -- Cleanup del contexto ajeno
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

  -- Cleanup
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
