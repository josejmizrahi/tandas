-- ============================================================================
-- R.2B — MEMBERSHIP BEHAVIOR + R.2C — RESOURCES & RIGHTS: DoD smokes dedicados
-- ============================================================================
-- Todos los RPCs ya existen (M.3 + R.2-1/R.2-2). Estos smokes formalizan los
-- casos de prueba del founder punto por punto.
--
-- R.2B caso:
--   Crear Cena Semanal Amigos → founder admin → invite code → David entra →
--   Isaac entra → members_count = 3 → remove_member(David) → David ya no ve nada
--   + leave_context (Isaac se sale voluntariamente)
--
-- R.2C caso:
--   Casa Valle → Abuelo OWN 100% + José/David/Isaac USE → resource_detail
--   correcto → revoke USE → update/archive resource
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- R.2B — Membership Behavior DoD
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_r2b_membership_dod()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_founder uuid; a_founder uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  v_ctx uuid; v_code text; v_result jsonb;
  v_caught boolean;
begin
  select auth_id, actor_id into u_founder, a_founder from public._r2_make_person('Founder R2B', '+5210000030');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2B', '+5210000031');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2B', '+5210000032');

  -- ═══ 1. Crear Cena Semanal Amigos → founder queda como founder/admin ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_founder::text)::text, true);
  v_ctx := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group'))->>'context_actor_id';

  if not exists (
    select 1 from public.actor_memberships
    where context_actor_id = v_ctx::uuid and member_actor_id = a_founder
      and membership_status = 'active' and membership_type = 'founder'
  ) then
    raise exception 'R2B FAIL: founder no quedó como membership_type=founder';
  end if;
  if not public.has_actor_authority(v_ctx::uuid, a_founder, 'context.manage') then
    raise exception 'R2B FAIL: founder sin rol admin';
  end if;

  -- ═══ 2-3. Crear invite code → David entra ═══
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.join_by_invite_code(v_code);
  if (v_result->>'context_actor_id')::uuid is distinct from v_ctx::uuid then
    raise exception 'R2B FAIL: David no entró con el código';
  end if;

  -- ═══ 4. Isaac entra con el mismo código ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- ═══ 5. context_summary muestra members_count = 3 ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_founder::text)::text, true);
  v_result := public.context_summary(v_ctx::uuid);
  if (v_result->>'members_count')::integer <> 3 then
    raise exception 'R2B FAIL: members_count = % (esperaba 3)', v_result->>'members_count';
  end if;

  -- ═══ 6. remove_member(David) ═══
  perform public.remove_member(v_ctx::uuid, a_david, 'prueba R2B');
  v_result := public.context_summary(v_ctx::uuid);
  if (v_result->>'members_count')::integer <> 2 then
    raise exception 'R2B FAIL: members_count post-remove = % (esperaba 2)', v_result->>'members_count';
  end if;

  -- ═══ 7. David ya NO puede ver el contexto ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_caught := false;
  begin
    v_result := public.context_summary(v_ctx::uuid);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2B FAIL: David removido aún puede ver el contexto'; end if;
  -- ni aparece en sus candidates
  v_result := public.context_candidates();
  if exists (select 1 from jsonb_array_elements(v_result->'contexts') c
             where (c->>'context_actor_id')::uuid = v_ctx::uuid) then
    raise exception 'R2B FAIL: contexto aparece en candidates de David removido';
  end if;
  -- ni tiene autoridad
  if public.has_actor_authority(v_ctx::uuid, a_david, 'events.view') then
    raise exception 'R2B FAIL: David removido conserva autoridad';
  end if;

  -- ═══ 8. leave_context: Isaac se sale voluntariamente ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_result := public.leave_context(v_ctx::uuid);
  if not (v_result->>'left')::boolean then
    raise exception 'R2B FAIL: leave_context falló';
  end if;
  v_caught := false;
  begin
    perform public.context_summary(v_ctx::uuid);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2B FAIL: Isaac que se salió aún puede ver el contexto'; end if;

  -- members_count final = 1 (solo founder)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_founder::text)::text, true);
  if (public.context_summary(v_ctx::uuid)->>'members_count')::integer <> 1 then
    raise exception 'R2B FAIL: members_count final incorrecto';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_founder, a_david, a_isaac], array[u_founder, u_david, u_isaac]);

  raise notice 'R.2B MEMBERSHIP BEHAVIOR DoD: PASS';
end; $$;

revoke all on function public._smoke_mvp2_r2b_membership_dod() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2b_membership_dod() is
  'R.2B DoD: create_context → invite code → joins → members_count=3 → remove_member → removido no ve nada → leave_context.';

-- ────────────────────────────────────────────────────────────────────────────
-- R.2C — Resources + Rights DoD (Casa Valle)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_r2c_resources_rights_dod()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_abuelo uuid; a_abuelo uuid;
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  v_ctx uuid; v_casa uuid; v_result jsonb; v_use_right uuid;
  v_caught boolean;
begin
  select auth_id, actor_id into u_abuelo, a_abuelo from public._r2_make_person('Abuelo R2C', '+5210000033');
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2C', '+5210000034');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2C', '+5210000035');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2C', '+5210000036');

  -- Setup: contexto familia con los 4
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_ctx := (public.create_context('Familia R2C', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_jose);
  perform public.invite_member(v_ctx::uuid, a_david);
  perform public.invite_member(v_ctx::uuid, a_isaac);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);

  -- ═══ 1. create_resource: Casa Valle ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_casa := (public.create_resource(v_ctx::uuid, 'house', 'Casa Valle',
    p_estimated_value := 8000000, p_currency := 'MXN'))->>'resource_id';
  if v_casa is null then raise exception 'R2C FAIL: create_resource falló'; end if;

  -- ═══ 2. grant_right: Abuelo OWN 100%, José USE, David USE, Isaac USE ═══
  perform public.grant_right(v_casa::uuid, a_abuelo, 'OWN', 100);
  perform public.grant_right(v_casa::uuid, a_jose, 'USE');
  perform public.grant_right(v_casa::uuid, a_david, 'USE');
  perform public.grant_right(v_casa::uuid, a_isaac, 'USE');

  -- ═══ 3. resource_detail retorna rights activos correctos ═══
  v_result := public.resource_detail(v_casa::uuid);
  if not exists (
    select 1 from jsonb_array_elements(v_result->'rights') rt
    where (rt->>'holder_actor_id')::uuid = a_abuelo
      and rt->>'right_kind' = 'OWN' and (rt->>'percent')::numeric = 100
  ) then
    raise exception 'R2C FAIL: Abuelo no tiene OWN 100%% en resource_detail';
  end if;
  if (select count(*) from jsonb_array_elements(v_result->'rights') rt
      where rt->>'right_kind' = 'USE') <> 3 then
    raise exception 'R2C FAIL: no hay exactamente 3 USE rights';
  end if;
  -- actor_has_right confirma
  if not public.actor_has_right(a_jose, v_casa::uuid, 'USE')
     or not public.actor_has_right(a_abuelo, v_casa::uuid, 'OWN') then
    raise exception 'R2C FAIL: actor_has_right inconsistente con resource_detail';
  end if;

  -- ═══ 4. revoke_right: quitar el USE de Isaac ═══
  select (rt->>'right_id')::uuid into v_use_right
    from jsonb_array_elements(v_result->'rights') rt
   where (rt->>'holder_actor_id')::uuid = a_isaac and rt->>'right_kind' = 'USE';
  perform public.revoke_right(v_use_right);

  if public.actor_has_right(a_isaac, v_casa::uuid, 'USE') then
    raise exception 'R2C FAIL: USE de Isaac sigue activo post-revoke';
  end if;
  -- resource_detail ya no lo muestra
  v_result := public.resource_detail(v_casa::uuid);
  if (select count(*) from jsonb_array_elements(v_result->'rights') rt
      where rt->>'right_kind' = 'USE') <> 2 then
    raise exception 'R2C FAIL: resource_detail muestra USE revocado';
  end if;

  -- ═══ 5. Miembro SIN rights ejecutivos NO puede grant/revoke ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_caught := false;
  begin
    perform public.grant_right(v_casa::uuid, a_david, 'OWN', 100);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2C FAIL: David (USE) pudo auto-otorgarse OWN'; end if;

  -- ═══ 6. update_resource + archive_resource (solo con autoridad) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_result := public.update_resource(v_casa::uuid, p_description := 'Casa del lago, 4 recámaras');
  if v_result->'resource'->>'description' <> 'Casa del lago, 4 recámaras' then
    raise exception 'R2C FAIL: update_resource no aplicó';
  end if;

  v_result := public.archive_resource(v_casa::uuid);
  if not (v_result->>'archived')::boolean then
    raise exception 'R2C FAIL: archive_resource falló';
  end if;
  -- idempotente
  if not (public.archive_resource(v_casa::uuid)->>'already_archived')::boolean then
    raise exception 'R2C FAIL: archive no es idempotente';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_abuelo, a_jose, a_david, a_isaac],
    array[u_abuelo, u_jose, u_david, u_isaac]);

  raise notice 'R.2C RESOURCES + RIGHTS DoD: PASS';
end; $$;

revoke all on function public._smoke_mvp2_r2c_resources_rights_dod() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2c_resources_rights_dod() is
  'R.2C DoD: Casa Valle → Abuelo OWN 100% + 3 USE → resource_detail correcto → revoke → autorización → update/archive.';
