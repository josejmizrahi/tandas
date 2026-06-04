-- ============================================================================
-- R.2U.2 — SMOKE: _smoke_r2u_activity_descendants
-- ============================================================================
-- Setup:
--   Familia (root, miembros: José + Papá)
--    ├─ Comidas Miércoles (sólo José)
--    └─ Mundial 2026     (sólo José)
--
-- Eventos generados:
--   · 1 evento en Familia (al crearse)
--   · 1 evento en Comidas (al crearse como hijo, en el child)
--   · 1 evento en Mundial (al crearse como hijo, en el child)
--   · `context.child.created` se emite ADEMÁS en Familia → 2 eventos extra
--
-- Asserts:
--   C1: include_descendants=false → José sólo ve eventos del contexto raíz
--   C2: include_descendants=true  → José ve eventos de los 3 contextos
--   C3: include_descendants=true  → Papá ve sólo eventos de Familia (no es
--                                   miembro de Comidas ni de Mundial — la
--                                   doctrina membership-no-hereda se respeta)
-- ============================================================================

create or replace function public._smoke_r2u_activity_descendants()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_papa uuid := gen_random_uuid();
  v_jose uuid; v_papa uuid;
  v_familia uuid; v_comidas uuid; v_mundial uuid;
  v_code text;
  v_root_only jsonb;
  v_aggregated jsonb;
  v_papa_aggregated jsonb;
  v_jose_seen_contexts uuid[];
  v_papa_seen_contexts uuid[];
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, '_smoke_r2u_ad José', '+520000000911', null);
  v_papa := public._create_person_actor_for_auth_user(v_auth_papa, '_smoke_r2u_ad Papa', '+520000000912', null);

  -- José crea Familia + invita a Papá + crea 2 hijos
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_familia := (public.create_context('_smoke_r2u_ad Familia', 'collective', 'family')->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_familia))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_comidas := (public.create_child_context(v_familia, '_smoke_r2u_ad Comidas', 'collective', 'community')->>'child_context_actor_id')::uuid;
  v_mundial := (public.create_child_context(v_familia, '_smoke_r2u_ad Mundial', 'collective', 'friend_group')->>'child_context_actor_id')::uuid;

  -- Caso 1: José con include_descendants=false → sólo eventos de Familia
  -- (los context.child.created se emiten en Familia, así que estarán aquí)
  v_root_only := public.list_activity(v_familia, 100, null, false);
  if (v_root_only->>'include_descendants')::boolean is not false then
    raise exception 'r2u_ad C1: flag include_descendants no preserva false';
  end if;
  -- Verificar que TODOS los eventos del root_only pertenecen a Familia
  if exists (
    select 1 from jsonb_array_elements(v_root_only->'activity') e
    where (e->>'context_actor_id')::uuid <> v_familia
  ) then
    raise exception 'r2u_ad C1: root_only filtró eventos de otro contexto';
  end if;

  -- Caso 2: José con include_descendants=true → ve los 3 contextos
  v_aggregated := public.list_activity(v_familia, 100, null, true);
  if (v_aggregated->>'include_descendants')::boolean is not true then
    raise exception 'r2u_ad C2: flag include_descendants no se respeta';
  end if;
  -- Coleccionar context_actor_ids distintos
  select array_agg(distinct (e->>'context_actor_id')::uuid)
    into v_jose_seen_contexts
    from jsonb_array_elements(v_aggregated->'activity') e;

  if not (v_familia = any(v_jose_seen_contexts)) then
    raise exception 'r2u_ad C2: no apareció evento de Familia en agregado';
  end if;
  if not (v_comidas = any(v_jose_seen_contexts)) then
    raise exception 'r2u_ad C2: no apareció evento de Comidas en agregado';
  end if;
  if not (v_mundial = any(v_jose_seen_contexts)) then
    raise exception 'r2u_ad C2: no apareció evento de Mundial en agregado';
  end if;

  -- Caso 3: Papá con include_descendants=true → SÓLO ve eventos de Familia
  -- (no es miembro de Comidas ni Mundial; doctrina R.2U membership-no-hereda)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  v_papa_aggregated := public.list_activity(v_familia, 100, null, true);
  if (v_papa_aggregated->>'include_descendants')::boolean is not true then
    raise exception 'r2u_ad C3: flag no se respeta para Papá';
  end if;
  select array_agg(distinct (e->>'context_actor_id')::uuid)
    into v_papa_seen_contexts
    from jsonb_array_elements(v_papa_aggregated->'activity') e;

  if v_comidas = any(coalesce(v_papa_seen_contexts, '{}'::uuid[])) then
    raise exception 'r2u_ad C3: Papá vio eventos de Comidas (no es miembro)';
  end if;
  if v_mundial = any(coalesce(v_papa_seen_contexts, '{}'::uuid[])) then
    raise exception 'r2u_ad C3: Papá vio eventos de Mundial (no es miembro)';
  end if;
  if v_papa_seen_contexts is null or not (v_familia = any(v_papa_seen_contexts)) then
    raise exception 'r2u_ad C3: Papá no vio eventos de Familia (debería)';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.context_invites where context_actor_id in (v_familia, v_comidas, v_mundial);
  delete from public.actor_relationships
    where subject_actor_id in (v_familia, v_comidas, v_mundial)
       or object_actor_id  in (v_familia, v_comidas, v_mundial);
  delete from public.role_assignments where context_actor_id in (v_familia, v_comidas, v_mundial);
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id in (v_familia, v_comidas, v_mundial);
  delete from public.roles where context_actor_id in (v_familia, v_comidas, v_mundial);
  delete from public.actor_memberships where context_actor_id in (v_familia, v_comidas, v_mundial);
  delete from public.actors where id in (v_familia, v_comidas, v_mundial);
  delete from public.person_profiles where actor_id in (v_jose, v_papa);
  delete from public.actors where id in (v_jose, v_papa);
  delete from auth.users where id in (v_auth_jose, v_auth_papa);

  raise notice '_smoke_r2u_activity_descendants passed (3 casos)';
end; $$;

revoke all on function public._smoke_r2u_activity_descendants() from public, anon, authenticated;
comment on function public._smoke_r2u_activity_descendants() is
  'R.2U.2: include_descendants flag + membership-aware filter en activity.';
