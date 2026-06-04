-- ============================================================================
-- R.2U.1 — SMOKES
-- ============================================================================
-- 5 smokes que cubren la doctrina entera de Context Hierarchy:
--   1. _smoke_r2u_contains              — link/unlink + children/parents
--   2. _smoke_r2u_no_cycle              — self-loop + transitive cycle rechazados
--   3. _smoke_r2u_tree                  — context_tree estructura correcta
--   4. _smoke_r2u_membership_not_inherited — membership de padre NO da acceso al hijo
--   5. _smoke_r2u_rights_not_inherited  — VIEW del padre NO da rights sobre child resources
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. _smoke_r2u_contains
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2u_contains()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_a uuid;
  v_familia uuid; v_comidas uuid;
  v_result jsonb; v_children jsonb; v_parents jsonb;
  v_rel_id uuid;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, '_smoke_r2u A', '+520000000901', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);

  -- Caso 1: create_context Familia + create_child_context Comidas
  v_familia := (public.create_context('_smoke_r2u Familia', 'collective', 'family')->>'context_actor_id')::uuid;
  v_result  := public.create_child_context(v_familia, '_smoke_r2u Comidas', 'collective', 'community');
  v_comidas := (v_result->>'child_context_actor_id')::uuid;
  if v_comidas is null then raise exception 'r2u_contains C1: child not created'; end if;
  if (v_result->>'parent_context_actor_id')::uuid <> v_familia then
    raise exception 'r2u_contains C1: parent mismatch';
  end if;

  -- Caso 2: context_children del padre incluye al hijo
  v_children := public.context_children(v_familia);
  if not exists (select 1 from jsonb_array_elements(v_children) c where (c->>'id')::uuid = v_comidas) then
    raise exception 'r2u_contains C2: child no aparece en context_children';
  end if;

  -- Caso 3: context_parents del hijo incluye al padre
  v_parents := public.context_parents(v_comidas);
  if not exists (select 1 from jsonb_array_elements(v_parents) p where (p->>'id')::uuid = v_familia) then
    raise exception 'r2u_contains C3: parent no aparece en context_parents';
  end if;

  -- Caso 4: unlink_child_context soft-ends + idempotencia
  v_result := public.unlink_child_context(v_familia, v_comidas);
  if (v_result->>'unlinked')::boolean is not true then
    raise exception 'r2u_contains C4: unlink no marcó unlinked=true';
  end if;

  v_children := public.context_children(v_familia);
  if exists (select 1 from jsonb_array_elements(v_children) c where (c->>'id')::uuid = v_comidas) then
    raise exception 'r2u_contains C4b: child sigue listado tras unlink';
  end if;

  -- Idempotencia: unlink de nuevo devuelve unlinked=false sin error
  v_result := public.unlink_child_context(v_familia, v_comidas);
  if (v_result->>'unlinked')::boolean is not false then
    raise exception 'r2u_contains C4c: unlink no idempotente';
  end if;

  -- Caso 5: link_child_context re-vincula contexto existente (autoridad en ambos)
  v_result := public.link_child_context(v_familia, v_comidas);
  v_rel_id := (v_result->>'relationship_id')::uuid;
  if v_rel_id is null then raise exception 'r2u_contains C5: relink no creó relación'; end if;

  -- Caso 6: link idempotente (already_linked=true)
  v_result := public.link_child_context(v_familia, v_comidas);
  if (v_result->>'already_linked')::boolean is not true then
    raise exception 'r2u_contains C6: re-link no es idempotente';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.actor_relationships where subject_actor_id = v_familia or object_actor_id in (v_familia, v_comidas);
  delete from public.role_assignments where context_actor_id in (v_familia, v_comidas);
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id in (v_familia, v_comidas);
  delete from public.roles where context_actor_id in (v_familia, v_comidas);
  delete from public.actor_memberships where context_actor_id in (v_familia, v_comidas);
  delete from public.actors where id in (v_familia, v_comidas);
  delete from public.person_profiles where actor_id = v_a;
  delete from public.actors where id = v_a;
  delete from auth.users where id = v_auth_a;

  raise notice '_smoke_r2u_contains passed (6 casos)';
end; $$;

revoke all on function public._smoke_r2u_contains() from public, anon, authenticated;
comment on function public._smoke_r2u_contains() is 'R.2U.1: contains/link/unlink/children/parents.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. _smoke_r2u_no_cycle
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2u_no_cycle()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_a uuid;
  v_top uuid; v_mid uuid; v_bot uuid;
  v_caught boolean;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, '_smoke_r2u_no_cycle', '+520000000902', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);

  v_top := (public.create_context('_smoke_r2u_nc TOP', 'collective', 'family')->>'context_actor_id')::uuid;
  v_mid := (public.create_child_context(v_top, '_smoke_r2u_nc MID', 'collective', 'project')->>'child_context_actor_id')::uuid;
  v_bot := (public.create_child_context(v_mid, '_smoke_r2u_nc BOT', 'collective', 'project')->>'child_context_actor_id')::uuid;

  -- Caso 1: self-loop directo en actor_relationships (test trigger, no RPC)
  v_caught := false;
  begin
    insert into public.actor_relationships
      (subject_actor_id, relationship_type, object_actor_id, created_by_actor_id)
    values (v_top, 'contains', v_top, v_a);
  exception when invalid_parameter_value then v_caught := true;
  end;
  if not v_caught then raise exception 'r2u_no_cycle C1: self-loop aceptado'; end if;

  -- Caso 2: ciclo transitivo TOP→MID→BOT, intentar BOT→TOP
  v_caught := false;
  begin
    insert into public.actor_relationships
      (subject_actor_id, relationship_type, object_actor_id, created_by_actor_id)
    values (v_bot, 'contains', v_top, v_a);
  exception when invalid_parameter_value then v_caught := true;
  end;
  if not v_caught then raise exception 'r2u_no_cycle C2: ciclo transitivo BOT→TOP aceptado'; end if;

  -- Caso 3: ciclo directo MID→TOP también rechazado
  v_caught := false;
  begin
    insert into public.actor_relationships
      (subject_actor_id, relationship_type, object_actor_id, created_by_actor_id)
    values (v_mid, 'contains', v_top, v_a);
  exception when invalid_parameter_value then v_caught := true;
  end;
  if not v_caught then raise exception 'r2u_no_cycle C3: ciclo directo MID→TOP aceptado'; end if;

  -- Caso 4: vía link_child_context también rechazado (mismo trigger)
  -- (Crear membership de Caller en BOT ya está vía founder de create_child_context)
  v_caught := false;
  begin
    perform public.link_child_context(v_bot, v_top);
  exception when invalid_parameter_value then v_caught := true;
            when others then v_caught := true; -- también si falla por authority u otro
  end;
  if not v_caught then raise exception 'r2u_no_cycle C4: link cíclico aceptado'; end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.actor_relationships
    where subject_actor_id in (v_top, v_mid, v_bot) or object_actor_id in (v_top, v_mid, v_bot);
  delete from public.role_assignments where context_actor_id in (v_top, v_mid, v_bot);
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id in (v_top, v_mid, v_bot);
  delete from public.roles where context_actor_id in (v_top, v_mid, v_bot);
  delete from public.actor_memberships where context_actor_id in (v_top, v_mid, v_bot);
  delete from public.actors where id in (v_top, v_mid, v_bot);
  delete from public.person_profiles where actor_id = v_a;
  delete from public.actors where id = v_a;
  delete from auth.users where id = v_auth_a;

  raise notice '_smoke_r2u_no_cycle passed (4 casos)';
end; $$;

revoke all on function public._smoke_r2u_no_cycle() from public, anon, authenticated;
comment on function public._smoke_r2u_no_cycle() is 'R.2U.1: cycle protection (self + transitive + direct).';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. _smoke_r2u_tree
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2u_tree()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_a uuid;
  v_familia uuid; v_comidas uuid; v_mundial uuid; v_proyecto uuid; v_fideo uuid;
  v_tree jsonb; v_descendants jsonb; v_ancestors jsonb;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, '_smoke_r2u_tree', '+520000000903', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);

  -- Construir: Familia → { Comidas, Mundial, Proyecto → { Fideicomiso } }
  v_familia  := (public.create_context('_smoke_r2u_tree Familia', 'collective', 'family')->>'context_actor_id')::uuid;
  v_comidas  := (public.create_child_context(v_familia, '_smoke_r2u_tree Comidas',  'collective', 'community')->>'child_context_actor_id')::uuid;
  v_mundial  := (public.create_child_context(v_familia, '_smoke_r2u_tree Mundial',  'collective', 'friend_group')->>'child_context_actor_id')::uuid;
  v_proyecto := (public.create_child_context(v_familia, '_smoke_r2u_tree Proyecto', 'collective', 'project')->>'child_context_actor_id')::uuid;
  v_fideo    := (public.create_child_context(v_proyecto, '_smoke_r2u_tree Fideo',  'legal_entity', 'trust')->>'child_context_actor_id')::uuid;

  -- Caso 1: context_tree(Familia) tiene 3 children
  v_tree := public.context_tree(v_familia);
  if jsonb_array_length(v_tree->'children') <> 3 then
    raise exception 'r2u_tree C1: Familia debería tener 3 children, tuvo %', jsonb_array_length(v_tree->'children');
  end if;

  -- Caso 2: Proyecto child trae a Fideicomiso (recursión)
  if not exists (
    select 1
      from jsonb_array_elements(v_tree->'children') c
     where (c->>'id')::uuid = v_proyecto
       and jsonb_array_length(c->'children') = 1
       and (c->'children'->0->>'id')::uuid = v_fideo
  ) then
    raise exception 'r2u_tree C2: Proyecto no contiene Fideicomiso en context_tree';
  end if;

  -- Caso 3: context_descendants(Familia) trae los 4
  v_descendants := public.context_descendants(v_familia);
  if jsonb_array_length(v_descendants) <> 4 then
    raise exception 'r2u_tree C3: descendants debería ser 4, fue %', jsonb_array_length(v_descendants);
  end if;

  -- Caso 4: context_ancestors(Fideicomiso) trae [Proyecto, Familia]
  v_ancestors := public.context_ancestors(v_fideo);
  if jsonb_array_length(v_ancestors) <> 2 then
    raise exception 'r2u_tree C4: ancestors de Fideo debería ser 2, fue %', jsonb_array_length(v_ancestors);
  end if;
  if (v_ancestors->0->>'id')::uuid <> v_proyecto then
    raise exception 'r2u_tree C4b: primer ancestor debería ser Proyecto';
  end if;
  if (v_ancestors->1->>'id')::uuid <> v_familia then
    raise exception 'r2u_tree C4c: segundo ancestor debería ser Familia';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.actor_relationships
    where subject_actor_id in (v_familia, v_comidas, v_mundial, v_proyecto, v_fideo)
       or object_actor_id  in (v_familia, v_comidas, v_mundial, v_proyecto, v_fideo);
  delete from public.role_assignments where context_actor_id in (v_familia, v_comidas, v_mundial, v_proyecto, v_fideo);
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id in (v_familia, v_comidas, v_mundial, v_proyecto, v_fideo);
  delete from public.roles where context_actor_id in (v_familia, v_comidas, v_mundial, v_proyecto, v_fideo);
  delete from public.actor_memberships where context_actor_id in (v_familia, v_comidas, v_mundial, v_proyecto, v_fideo);
  delete from public.actors where id in (v_familia, v_comidas, v_mundial, v_proyecto, v_fideo);
  delete from public.person_profiles where actor_id = v_a;
  delete from public.actors where id = v_a;
  delete from auth.users where id = v_auth_a;

  raise notice '_smoke_r2u_tree passed (4 casos)';
end; $$;

revoke all on function public._smoke_r2u_tree() from public, anon, authenticated;
comment on function public._smoke_r2u_tree() is 'R.2U.1: tree/descendants/ancestors estructura.';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. _smoke_r2u_membership_not_inherited
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2u_membership_not_inherited()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_papa uuid := gen_random_uuid();
  v_jose uuid; v_papa uuid;
  v_familia uuid; v_mundial uuid;
  v_code text;
  v_caught boolean;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, '_smoke_r2u José', '+520000000904', null);
  v_papa := public._create_person_actor_for_auth_user(v_auth_papa, '_smoke_r2u Papa', '+520000000905', null);

  -- José crea Familia, invita a Papá. José también crea Mundial como hijo de Familia.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_familia := (public.create_context('_smoke_r2u_mni Familia', 'collective', 'family')->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_familia))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_mundial := (public.create_child_context(v_familia, '_smoke_r2u_mni Mundial', 'collective', 'friend_group')->>'child_context_actor_id')::uuid;

  -- Caso 1: Papá NO es miembro de Mundial (membership no hereda)
  if exists (
    select 1 from public.actor_memberships
     where context_actor_id = v_mundial
       and member_actor_id = v_papa
       and membership_status = 'active'
  ) then
    raise exception 'r2u_mni C1: Papá heredó membership de Mundial';
  end if;

  -- Caso 2: Papá no puede llamar context_summary de Mundial
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  v_caught := false;
  begin
    perform public.context_summary(v_mundial);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'r2u_mni C2: Papá vio context_summary de Mundial'; end if;

  -- Caso 3: Papá sí ve a Familia
  v_caught := false;
  begin
    perform public.context_summary(v_familia);
  exception when others then v_caught := true;
  end;
  if v_caught then raise exception 'r2u_mni C3: Papá NO vio context_summary de Familia (debería ver)'; end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.context_invites where context_actor_id in (v_familia, v_mundial);
  delete from public.actor_relationships
    where subject_actor_id in (v_familia, v_mundial) or object_actor_id in (v_familia, v_mundial);
  delete from public.role_assignments where context_actor_id in (v_familia, v_mundial);
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id in (v_familia, v_mundial);
  delete from public.roles where context_actor_id in (v_familia, v_mundial);
  delete from public.actor_memberships where context_actor_id in (v_familia, v_mundial);
  delete from public.actors where id in (v_familia, v_mundial);
  delete from public.person_profiles where actor_id in (v_jose, v_papa);
  delete from public.actors where id in (v_jose, v_papa);
  delete from auth.users where id in (v_auth_jose, v_auth_papa);

  raise notice '_smoke_r2u_membership_not_inherited passed (3 casos)';
end; $$;

revoke all on function public._smoke_r2u_membership_not_inherited() from public, anon, authenticated;
comment on function public._smoke_r2u_membership_not_inherited() is 'R.2U.1: memberships no se heredan vía contains.';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. _smoke_r2u_rights_not_inherited
-- ────────────────────────────────────────────────────────────────────────────
-- Setup: Familia contains Patrimonio. Papá miembro de Familia (sin VIEW del
-- Patrimonio porque no es miembro). Verificar que no tiene VIEW sobre el
-- recurso "Casa Valle" que vive en Patrimonio.
create or replace function public._smoke_r2u_rights_not_inherited()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_papa uuid := gen_random_uuid();
  v_jose uuid; v_papa uuid;
  v_familia uuid; v_patrimonio uuid;
  v_resource uuid;
  v_code text;
  v_can_view boolean;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, '_smoke_r2u_rni José', '+520000000906', null);
  v_papa := public._create_person_actor_for_auth_user(v_auth_papa, '_smoke_r2u_rni Papa', '+520000000907', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_familia    := (public.create_context('_smoke_r2u_rni Familia', 'collective', 'family')->>'context_actor_id')::uuid;
  v_patrimonio := (public.create_child_context(v_familia, '_smoke_r2u_rni Patrimonio', 'collective', 'project')->>'child_context_actor_id')::uuid;

  -- Papá entra a Familia (sólo)
  v_code := (public.create_invite(v_familia))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- José crea un recurso en Patrimonio (es founder de Patrimonio)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_resource := (public.create_resource(v_patrimonio, 'house', '_smoke_r2u_rni Casa Valle')->>'resource_id')::uuid;

  -- Caso 1: Papá NO tiene VIEW rights sobre el recurso (no hay rights heredados)
  if exists (
    select 1 from public.resource_rights rr
     where rr.resource_id = v_resource
       and rr.holder_actor_id = v_papa
       and (rr.revoked_at is null and (rr.expired_at is null or rr.expired_at > now()))
  ) then
    raise exception 'r2u_rni C1: Papá heredó rights sobre Casa Valle';
  end if;

  -- Caso 2: list_context_resources(Familia) NO devuelve el resource del child
  -- (Patrimonio es un contexto distinto; sus recursos no se proyectan al padre)
  declare
    v_list jsonb;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
    v_list := public.list_context_resources(v_familia);
    if exists (
      select 1 from jsonb_array_elements(v_list) r where (r->>'resource_id')::uuid = v_resource
    ) then
      raise exception 'r2u_rni C2: Casa Valle apareció en list_context_resources de Familia';
    end if;
  end;

  -- Caso 3: list_context_resources(Patrimonio) por Papá falla por no-miembro
  declare
    v_caught boolean := false;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
    begin
      perform public.list_context_resources(v_patrimonio);
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'r2u_rni C3: Papá vio recursos de Patrimonio (no-miembro)'; end if;
  end;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.context_invites where context_actor_id in (v_familia, v_patrimonio);
  delete from public.resource_rights where resource_id = v_resource;
  delete from public.resources where id = v_resource;
  delete from public.actor_relationships
    where subject_actor_id in (v_familia, v_patrimonio) or object_actor_id in (v_familia, v_patrimonio);
  delete from public.role_assignments where context_actor_id in (v_familia, v_patrimonio);
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id in (v_familia, v_patrimonio);
  delete from public.roles where context_actor_id in (v_familia, v_patrimonio);
  delete from public.actor_memberships where context_actor_id in (v_familia, v_patrimonio);
  delete from public.actors where id in (v_familia, v_patrimonio);
  delete from public.person_profiles where actor_id in (v_jose, v_papa);
  delete from public.actors where id in (v_jose, v_papa);
  delete from auth.users where id in (v_auth_jose, v_auth_papa);

  raise notice '_smoke_r2u_rights_not_inherited passed (3 casos)';
end; $$;

revoke all on function public._smoke_r2u_rights_not_inherited() from public, anon, authenticated;
comment on function public._smoke_r2u_rights_not_inherited() is 'R.2U.1: rights no se heredan vía contains.';
