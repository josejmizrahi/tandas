-- ============================================================================
-- R.2C-2 — RIGHTS-BASED VISIBILITY: los rights explican quién puede ver
-- ============================================================================
-- Doctrina del founder (R.2C): "los recursos existen una sola vez y los rights
-- explican quién puede ver/usar/administrar".
--
-- Gap de comportamiento encontrado con el caso Casa Valle:
--   - list_context_resources mostraba TODOS los recursos del contexto a
--     CUALQUIER miembro (visibilidad por membership, no por rights).
--   - resource_detail permitía ver a cualquier miembro del contexto owner.
--   → Isaac (miembro sin rights) veía Casa Valle. Eso contradice la doctrina.
--
-- Fix (solo RPCs + RLS, cero cambios de schema — doctrina R.2):
--   1. _actor_can_view_resource(): un actor VE un recurso si
--      a) es el canonical owner, o
--      b) tiene un right activo sobre él, o
--      c) puede ejercer los rights de un holder colectivo (ej. el contexto
--         tiene GOVERN/MANAGE y el actor tiene autoridad resources.manage
--         en ese contexto — típicamente el admin).
--   2. list_context_resources: filtra por visibilidad del caller.
--   3. resource_detail: misma regla.
--   4. RLS resources/rights: misma regla (consistencia defense-in-depth).
--   5. Smoke R.2C reescrito al caso exacto del founder.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Helper de visibilidad rights-based
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._actor_can_view_resource(p_actor_id uuid, p_resource_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select
    -- a) canonical owner (cache del OWN dominante)
    exists (
      select 1 from public.resources r
      where r.id = p_resource_id and r.canonical_owner_actor_id = p_actor_id)
    -- b) holder directo de cualquier right activo
    or exists (
      select 1 from public.resource_rights rr
      where rr.resource_id = p_resource_id
        and rr.holder_actor_id = p_actor_id
        and rr.revoked_at is null and rr.expired_at is null
        and (rr.starts_at is null or rr.starts_at <= now())
        and (rr.ends_at is null or rr.ends_at > now()))
    -- c) puede ejercer los rights de un holder colectivo (contexto con
    --    GOVERN/MANAGE/OWN…) — requiere autoridad resources.manage sobre él
    or exists (
      select 1 from public.resource_rights rr
      where rr.resource_id = p_resource_id
        and rr.holder_actor_id <> p_actor_id
        and rr.revoked_at is null and rr.expired_at is null
        and (rr.starts_at is null or rr.starts_at <= now())
        and (rr.ends_at is null or rr.ends_at > now())
        and public.has_actor_authority(rr.holder_actor_id, p_actor_id, 'resources.manage'));
$$;

revoke all on function public._actor_can_view_resource(uuid, uuid) from public, anon;
grant execute on function public._actor_can_view_resource(uuid, uuid) to authenticated, service_role;

comment on function public._actor_can_view_resource(uuid, uuid) is
  'R.2C: los rights explican quién puede ver. Canonical owner, holder activo, o autoridad resources.manage sobre un holder colectivo.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. list_context_resources: filtrado por visibilidad del caller
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.list_context_resources(p_context_actor_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'resource_id', r.id,
      'resource_type', r.resource_type,
      'display_name', r.display_name,
      'status', r.status,
      'estimated_value', r.estimated_value,
      'currency', r.currency,
      'canonical_owner_actor_id', r.canonical_owner_actor_id,
      'rights', coalesce((
        select jsonb_agg(jsonb_build_object(
          'right_id', rr.id, 'holder_actor_id', rr.holder_actor_id,
          'right_kind', rr.right_kind, 'percent', rr.percent))
        from public.resource_rights rr
        where rr.resource_id = r.id and rr.revoked_at is null and rr.expired_at is null), '[]'::jsonb)
    ) order by r.created_at desc)
    from public.resources r
    where r.archived_at is null
      -- candidatos: recursos del contexto (canonical owner) o donde el contexto tiene rights
      and (r.canonical_owner_actor_id = p_context_actor_id
           or exists (
             select 1 from public.resource_rights rr
             where rr.resource_id = r.id and rr.holder_actor_id = p_context_actor_id
               and rr.revoked_at is null and rr.expired_at is null))
      -- R.2C: el caller solo ve los que sus rights le permiten ver
      and public._actor_can_view_resource(v_caller, r.id)
  ), '[]'::jsonb);
end; $$;

revoke all on function public.list_context_resources(uuid) from public, anon;
grant execute on function public.list_context_resources(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. resource_detail: misma regla rights-based
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.resource_detail(p_resource_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_resource public.resources%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_resource from public.resources where id = p_resource_id;
  if v_resource.id is null then raise exception 'resource not found' using errcode = 'P0002'; end if;

  -- R.2C: los rights explican quién puede ver
  if not public._actor_can_view_resource(v_caller, p_resource_id) then
    raise exception 'not authorized to view resource %', p_resource_id using errcode = '42501';
  end if;

  return jsonb_build_object(
    'resource', to_jsonb(v_resource),
    'rights', coalesce((
      select jsonb_agg(jsonb_build_object(
        'right_id', rr.id, 'holder_actor_id', rr.holder_actor_id,
        'holder_display_name', (select a.display_name from public.actors a where a.id = rr.holder_actor_id),
        'right_kind', rr.right_kind, 'percent', rr.percent, 'scope', rr.scope,
        'starts_at', rr.starts_at, 'ends_at', rr.ends_at) order by rr.created_at)
      from public.resource_rights rr
      where rr.resource_id = p_resource_id and rr.revoked_at is null and rr.expired_at is null), '[]'::jsonb)
  );
end; $$;

revoke all on function public.resource_detail(uuid) from public, anon;
grant execute on function public.resource_detail(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. RLS: lecturas directas alineadas a la misma doctrina
-- ────────────────────────────────────────────────────────────────────────────
drop policy if exists resources_select on public.resources;
create policy resources_select on public.resources
  for select to authenticated
  using (
    created_by_actor_id = public.current_actor_id()
    or public._actor_can_view_resource(public.current_actor_id(), id)
  );

drop policy if exists rights_select on public.resource_rights;
create policy rights_select on public.resource_rights
  for select to authenticated
  using (
    holder_actor_id = public.current_actor_id()
    or public._actor_can_view_resource(public.current_actor_id(), resource_id)
  );

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Smoke R.2C reescrito: caso exacto del founder (Casa Valle)
-- ────────────────────────────────────────────────────────────────────────────
-- Abuelo crea Casa Valle → Abuelo OWN 100% (auto-OWN al canonical owner)
-- → Familia Mizrahi recibe GOVERN/MANAGE → José USE → David USE → Isaac nada
-- → José ve Casa Valle → Isaac no la ve → se revoca USE a David → David ya no la ve
create or replace function public._smoke_mvp2_r2c_resources_rights_dod()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_abuelo uuid; a_abuelo uuid;
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  v_ctx uuid; v_casa uuid; v_result jsonb;
  v_use_david uuid;
  v_caught boolean;
begin
  select auth_id, actor_id into u_abuelo, a_abuelo from public._r2_make_person('Abuelo R2C', '+5210000033');
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2C', '+5210000034');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2C', '+5210000035');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2C', '+5210000036');

  -- Setup: Familia Mizrahi (Abuelo founder/admin) + José/David/Isaac miembros
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_ctx := (public.create_context('Familia Mizrahi', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_jose);
  perform public.invite_member(v_ctx::uuid, a_david);
  perform public.invite_member(v_ctx::uuid, a_isaac);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);

  -- ═══ 1. Abuelo crea Casa Valle (recurso personal) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_casa := (public.create_resource(a_abuelo, 'house', 'Casa Valle',
    p_estimated_value := 8000000, p_currency := 'MXN'))->>'resource_id';
  if v_casa is null then raise exception 'R2C FAIL 1: create_resource falló'; end if;

  -- ═══ 2. Auto-OWN al canonical_owner_actor_id → Abuelo OWN 100% ═══
  if not public.actor_has_right(a_abuelo, v_casa::uuid, 'OWN') then
    raise exception 'R2C FAIL 2: auto-OWN no se creó para el Abuelo';
  end if;
  if (select canonical_owner_actor_id from public.resources where id = v_casa::uuid)
     is distinct from a_abuelo then
    raise exception 'R2C FAIL 2: canonical owner no es el Abuelo';
  end if;
  if not exists (
    select 1 from public.resource_rights
    where resource_id = v_casa::uuid and holder_actor_id = a_abuelo
      and right_kind = 'OWN' and percent = 100 and revoked_at is null
  ) then
    raise exception 'R2C FAIL 2: el OWN del Abuelo no es 100%%';
  end if;

  -- ═══ 3. Familia Mizrahi recibe GOVERN + MANAGE ═══
  perform public.grant_right(v_casa::uuid, v_ctx::uuid, 'GOVERN');
  perform public.grant_right(v_casa::uuid, v_ctx::uuid, 'MANAGE');
  if not public.actor_has_right(v_ctx::uuid, v_casa::uuid, 'GOVERN')
     or not public.actor_has_right(v_ctx::uuid, v_casa::uuid, 'MANAGE') then
    raise exception 'R2C FAIL 3: la Familia no recibió GOVERN/MANAGE';
  end if;

  -- ═══ 4. José recibe USE, David recibe USE; Isaac no tiene derecho ═══
  perform public.grant_right(v_casa::uuid, a_jose, 'USE');
  v_use_david := (public.grant_right(v_casa::uuid, a_david, 'USE'))->>'right_id';
  if public.actor_has_right(a_isaac, v_casa::uuid, 'USE') then
    raise exception 'R2C FAIL 4: Isaac tiene USE que nunca se le otorgó';
  end if;

  -- ═══ 5. José VE Casa Valle (list + detail) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.list_context_resources(v_ctx::uuid);
  if not exists (
    select 1 from jsonb_array_elements(v_result) e where (e->>'resource_id')::uuid = v_casa::uuid
  ) then
    raise exception 'R2C FAIL 5: José (USE) no ve Casa Valle en list_context_resources';
  end if;
  v_result := public.resource_detail(v_casa::uuid);
  if (v_result->'resource'->>'id')::uuid is distinct from v_casa::uuid then
    raise exception 'R2C FAIL 5: José (USE) no puede abrir resource_detail';
  end if;
  -- resource_detail muestra los rights correctos: 1 OWN 100%, 2 USE, GOVERN+MANAGE del contexto
  if not exists (
    select 1 from jsonb_array_elements(v_result->'rights') rt
    where (rt->>'holder_actor_id')::uuid = a_abuelo
      and rt->>'right_kind' = 'OWN' and (rt->>'percent')::numeric = 100
  ) then
    raise exception 'R2C FAIL 5: resource_detail no muestra OWN 100%% del Abuelo';
  end if;
  if (select count(*) from jsonb_array_elements(v_result->'rights') rt
      where rt->>'right_kind' = 'USE') <> 2 then
    raise exception 'R2C FAIL 5: resource_detail no muestra exactamente 2 USE';
  end if;
  if (select count(*) from jsonb_array_elements(v_result->'rights') rt
      where (rt->>'holder_actor_id')::uuid = v_ctx::uuid
        and rt->>'right_kind' in ('GOVERN', 'MANAGE')) <> 2 then
    raise exception 'R2C FAIL 5: resource_detail no muestra GOVERN/MANAGE de la Familia';
  end if;

  -- ═══ 6. Isaac NO la ve (miembro del contexto pero sin rights) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_result := public.list_context_resources(v_ctx::uuid);
  if exists (
    select 1 from jsonb_array_elements(v_result) e where (e->>'resource_id')::uuid = v_casa::uuid
  ) then
    raise exception 'R2C FAIL 6: Isaac (sin rights) VE Casa Valle en list_context_resources';
  end if;
  v_caught := false;
  begin
    perform public.resource_detail(v_casa::uuid);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'R2C FAIL 6: Isaac (sin rights) pudo abrir resource_detail';
  end if;

  -- ═══ 7. El admin del contexto (Abuelo) sí la ve también vía autoridad ═══
  -- (la Familia tiene GOVERN/MANAGE; el admin ejerce esos rights)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_result := public.list_context_resources(v_ctx::uuid);
  if not exists (
    select 1 from jsonb_array_elements(v_result) e where (e->>'resource_id')::uuid = v_casa::uuid
  ) then
    raise exception 'R2C FAIL 7: el admin del contexto no ve Casa Valle';
  end if;

  -- ═══ 8. Se revoca USE a David → David ya no la ve ═══
  perform public.revoke_right(v_use_david::uuid);
  if public.actor_has_right(a_david, v_casa::uuid, 'USE') then
    raise exception 'R2C FAIL 8: USE de David sigue activo post-revoke';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.list_context_resources(v_ctx::uuid);
  if exists (
    select 1 from jsonb_array_elements(v_result) e where (e->>'resource_id')::uuid = v_casa::uuid
  ) then
    raise exception 'R2C FAIL 8: David (USE revocado) sigue viendo Casa Valle';
  end if;
  v_caught := false;
  begin
    perform public.resource_detail(v_casa::uuid);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'R2C FAIL 8: David (USE revocado) pudo abrir resource_detail';
  end if;

  -- ═══ 9. Negativo: David no puede auto-otorgarse OWN ═══
  v_caught := false;
  begin
    perform public.grant_right(v_casa::uuid, a_david, 'OWN', 100);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2C FAIL 9: David pudo auto-otorgarse OWN'; end if;

  -- ═══ 10. Extra R.2-1: update_resource + archive_resource (Abuelo, OWN) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_result := public.update_resource(v_casa::uuid, p_description := 'Casa del lago, 4 recámaras');
  if v_result->'resource'->>'description' <> 'Casa del lago, 4 recámaras' then
    raise exception 'R2C FAIL 10: update_resource no aplicó';
  end if;
  v_result := public.archive_resource(v_casa::uuid);
  if not (v_result->>'archived')::boolean then
    raise exception 'R2C FAIL 10: archive_resource falló';
  end if;
  if not (public.archive_resource(v_casa::uuid)->>'already_archived')::boolean then
    raise exception 'R2C FAIL 10: archive no es idempotente';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_abuelo, a_jose, a_david, a_isaac],
    array[u_abuelo, u_jose, u_david, u_isaac]);

  raise notice 'R.2C RESOURCES + RIGHTS DoD: PASS (caso exacto Casa Valle, visibilidad rights-based)';
end; $$;

revoke all on function public._smoke_mvp2_r2c_resources_rights_dod() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2c_resources_rights_dod() is
  'R.2C DoD exacto: Abuelo crea Casa Valle → OWN 100% → Familia GOVERN/MANAGE → José/David USE → Isaac nada → José ve, Isaac no → revoke David → David ya no la ve.';
