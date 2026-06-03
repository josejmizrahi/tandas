-- ============================================================================
-- R.2S-FIX — CANONICAL AVAILABLE ACTIONS CONTRACT (recursos)
-- ============================================================================
-- Reconcilia R.2M-3 (resource_available_actions(resource_id) → {action,label,
-- section}) con R.2S.9 (actor-aware + shape rico) en UN solo contrato canónico.
--
-- Decisión doctrinal (founder): available actions son ACTOR-AWARE.
--
-- Contrato canónico:
--   resource_available_actions(p_resource_id, p_actor_id)   ← fuente canónica
--   resource_available_actions(p_resource_id)               ← delega al de arriba
--                                                             con current_actor_id()
--
-- Shape canónico (uniforme con obligation/decision/reservation):
--   { action_key, label, section, enabled, reason,
--     required_rights, required_capabilities }
--
-- resource_detail devuelve: resource, resource_type, metadata, capabilities,
--   available_actions (actor-aware), why_visible, rights.
--
-- La matriz tipo→capability y el resource_action_catalog de R.2M-3 se conservan
-- como fuente única; aquí solo se enriquece la forma y se vuelve actor-aware.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Canónica actor-aware: resource_available_actions(resource_id, actor_id)
-- ────────────────────────────────────────────────────────────────────────────
-- Una acción aparece SOLO si: capability satisfecha AND el actor tiene uno de
-- los rights requeridos (rule 6). enabled = true (afford solo si autorizado);
-- el campo enabled/reason mantiene la forma uniforme para gating futuro.
create or replace function public.resource_available_actions(p_resource_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_type text;
  v_rights text[];
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select resource_type into v_type from public.resources where id = p_resource_id;
  if v_type is null then raise exception 'resource not found' using errcode = 'P0002'; end if;
  -- el CALLER debe poder ver el recurso para preguntar por él
  if not public._actor_can_view_resource(v_caller, p_resource_id) then
    raise exception 'not authorized to view resource %', p_resource_id using errcode = '42501';
  end if;

  v_rights := public._actor_effective_rights(p_actor_id, p_resource_id);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'action_key', a.action_key,
      'label', a.display_name,
      'section', a.ui_section,
      'enabled', true,
      'reason', case
        when a.required_capability is not null and cardinality(a.required_rights) > 0
          then 'El recurso soporta ' || a.required_capability || ' y el actor tiene el derecho requerido'
        when a.required_capability is not null
          then 'El recurso soporta ' || a.required_capability
        else 'El actor tiene autoridad sobre el recurso' end,
      'required_rights', to_jsonb(a.required_rights),
      'required_capabilities', to_jsonb(
        case when a.required_capability is null then array[]::text[]
             else array[a.required_capability] end)
    ) order by a.sort_order, a.action_key)
    from public.resource_action_catalog a
    where (a.required_capability is null
           or public.resource_can(p_resource_id, a.required_capability))
      and (cardinality(a.required_rights) = 0
           or a.required_rights && v_rights)
  ), '[]'::jsonb);
end; $$;

revoke all on function public.resource_available_actions(uuid, uuid) from public, anon;
grant execute on function public.resource_available_actions(uuid, uuid) to authenticated, service_role;

comment on function public.resource_available_actions(uuid, uuid) is
  'R.2S-FIX: acciones disponibles para p_actor_id sobre el recurso (capability ∩ rights). Forma canónica de 7 campos. Fuente canónica actor-aware.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Compat: resource_available_actions(resource_id) → delega al actor-aware
-- ────────────────────────────────────────────────────────────────────────────
-- Firma legacy de R.2M-3. Se mantiene mientras frontend/smokes la usen.
create or replace function public.resource_available_actions(p_resource_id uuid)
returns jsonb
language sql stable security definer set search_path = public, auth
as $$
  select public.resource_available_actions(p_resource_id, public.current_actor_id());
$$;

revoke all on function public.resource_available_actions(uuid) from public, anon;
grant execute on function public.resource_available_actions(uuid) to authenticated, service_role;

comment on function public.resource_available_actions(uuid) is
  'R.2S-FIX: compat de 1 arg — delega a resource_available_actions(resource_id, current_actor_id()).';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. resource_detail v5: shape canónico (action_key + section + …) + why_visible
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

  if not public._actor_can_view_resource(v_caller, p_resource_id) then
    raise exception 'not authorized to view resource %', p_resource_id using errcode = '42501';
  end if;

  return jsonb_build_object(
    'resource', to_jsonb(v_resource),
    'resource_type', v_resource.resource_type,
    'metadata', v_resource.metadata,
    'capabilities', coalesce((
      select jsonb_agg(tc.capability_key order by tc.capability_key)
        from public.resource_type_capabilities tc
       where tc.type_key = v_resource.resource_type), '[]'::jsonb),
    -- R.2S-FIX: acciones canónicas actor-aware para el caller
    'available_actions', public.resource_available_actions(p_resource_id, v_caller),
    -- R.2M-3: por qué este actor ve el recurso
    'why_visible', coalesce((
      select jsonb_agg(distinct reason)
      from (
        select rr.right_kind as reason
          from public.resource_rights rr
         where rr.resource_id = p_resource_id and rr.holder_actor_id = v_caller
           and rr.revoked_at is null and rr.expired_at is null
        union all
        select rr.right_kind || ' via ' || a.display_name
          from public.resource_rights rr
          join public.actors a on a.id = rr.holder_actor_id
         where rr.resource_id = p_resource_id and rr.holder_actor_id <> v_caller
           and rr.revoked_at is null and rr.expired_at is null
           and (public.has_actor_authority(rr.holder_actor_id, v_caller, 'resources.manage')
                or public.is_context_member(rr.holder_actor_id))
      ) s), '[]'::jsonb),
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

comment on function public.resource_detail(uuid) is
  'R.2S-FIX: detalle de recurso con rights + capabilities + available_actions (canónico actor-aware) + why_visible.';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Smokes de R.2M-3 alineados al shape canónico (action_key)
-- ────────────────────────────────────────────────────────────────────────────
-- _r2m3_has_action ahora lee action_key (antes 'action').
create or replace function public._r2m3_has_action(p_resource_id uuid, p_action text)
returns boolean
language sql stable security definer set search_path = public, auth
as $$
  select exists (
    select 1 from jsonb_array_elements(public.resource_available_actions(p_resource_id)) e
    where e->>'action_key' = p_action
  );
$$;
revoke all on function public._r2m3_has_action(uuid, text) from public, anon, authenticated;

create or replace function public._smoke_r2m3_detail_contract()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  v_ctx uuid; v_casa uuid;
  v_detail jsonb;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2M3d', '+5210000062');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Detalle R2M3', 'collective', 'family'))->>'context_actor_id';
  v_casa := (public.create_resource(v_ctx::uuid, 'house', 'Casa Detalle'))->>'resource_id';

  v_detail := public.resource_detail(v_casa::uuid);

  if v_detail->>'resource_type' <> 'house' then raise exception 'R2M3 detail: falta resource_type'; end if;
  if jsonb_typeof(v_detail->'capabilities') <> 'array' then raise exception 'R2M3 detail: falta capabilities[]'; end if;
  if jsonb_typeof(v_detail->'available_actions') <> 'array' then raise exception 'R2M3 detail: falta available_actions[]'; end if;
  if jsonb_typeof(v_detail->'why_visible') <> 'array' then raise exception 'R2M3 detail: falta why_visible[]'; end if;
  if jsonb_typeof(v_detail->'rights') <> 'array' then raise exception 'R2M3 detail: falta rights[]'; end if;
  if not (v_detail->'capabilities') ? 'reservable' then raise exception 'R2M3 detail: capabilities sin reservable'; end if;
  -- shape canónico: {action_key,label,section,...} con sección reservations
  if not exists (
    select 1 from jsonb_array_elements(v_detail->'available_actions') e
    where e ? 'action_key' and e ? 'label' and e ? 'section' and e->>'section' = 'reservations'
  ) then raise exception 'R2M3 detail: available_actions sin la sección reservations (shape canónico)'; end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose], array[u_jose]);

  raise notice 'R.2M-3 DETAIL CONTRACT: PASS (shape canónico action_key + section + why_visible)';
end; $$;
revoke all on function public._smoke_r2m3_detail_contract() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Smoke — _smoke_r2s_fix_available_actions_contract (8 puntos)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2s_fix_available_actions_contract()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  v_ctx uuid; v_casa uuid; v_cuenta uuid; v_acciones uuid;
  v_legacy jsonb; v_aware jsonb; v_detail jsonb;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2Sfix', '+5210000131');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2Sfix', '+5210000132');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2Sfix', '+5210000133');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Patrimonio R2Sfix', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform public.invite_member(v_ctx::uuid, a_isaac);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_casa     := (public.create_resource(v_ctx::uuid, 'house', 'Casa Valle'))->>'resource_id';
  v_cuenta   := (public.create_resource(v_ctx::uuid, 'bank_account', 'Cuenta del Viaje'))->>'resource_id';
  v_acciones := (public.create_resource(v_ctx::uuid, 'security', 'Acciones Quimibond'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, a_david, 'USE');   -- David: USE explícito
  perform public.grant_right(v_casa::uuid, a_isaac, 'VIEW');  -- Isaac: solo VIEW

  -- ═══ 1. Firma actor-aware existe (2 args) ═══
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'resource_available_actions' and p.pronargs = 2
  ) then raise exception 'R2S-FIX FAIL 1: no existe la firma actor-aware (2 args)'; end if;

  -- ═══ 2. La firma legacy delega a la actor-aware ═══
  v_legacy := public.resource_available_actions(v_casa::uuid);
  v_aware  := public.resource_available_actions(v_casa::uuid, a_jose);
  if v_legacy is distinct from v_aware then
    raise exception 'R2S-FIX FAIL 2: la firma legacy no delega a la actor-aware';
  end if;

  -- ═══ 3. Casa Valle: actor con USE ve reserve; actor VIEW no ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_aware := public.resource_available_actions(v_casa::uuid, a_david);
  if not exists (select 1 from jsonb_array_elements(v_aware) e
                 where e->>'action_key' = 'reserve_resource' and (e->>'enabled')::boolean) then
    raise exception 'R2S-FIX FAIL 3: David (USE) no ve reserve_resource enabled';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_aware := public.resource_available_actions(v_casa::uuid, a_isaac);
  if exists (select 1 from jsonb_array_elements(v_aware) e where e->>'action_key' = 'reserve_resource') then
    raise exception 'R2S-FIX FAIL 3: Isaac (solo VIEW) NO debería ver reserve_resource';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  -- ═══ 4. Cuenta bancaria nunca muestra reserve ═══
  if exists (select 1 from jsonb_array_elements(public.resource_available_actions(v_cuenta::uuid)) e
             where e->>'action_key' = 'reserve_resource') then
    raise exception 'R2S-FIX FAIL 4: la cuenta bancaria muestra reserve_resource';
  end if;

  -- ═══ 5. Security nunca muestra reserve; sí beneficiary/ownership ═══
  v_aware := public.resource_available_actions(v_acciones::uuid);
  if exists (select 1 from jsonb_array_elements(v_aware) e where e->>'action_key' = 'reserve_resource') then
    raise exception 'R2S-FIX FAIL 5: security muestra reserve_resource';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_aware) e where e->>'action_key' = 'view_beneficiaries') then
    raise exception 'R2S-FIX FAIL 5: security no muestra view_beneficiaries';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_aware) e where e->>'action_key' = 'view_ownership') then
    raise exception 'R2S-FIX FAIL 5: security no muestra view_ownership';
  end if;

  -- ═══ 6. resource_detail usa el shape canónico (7 campos) + why_visible ═══
  v_detail := public.resource_detail(v_casa::uuid);
  if jsonb_typeof(v_detail->'available_actions') <> 'array'
     or jsonb_typeof(v_detail->'why_visible') <> 'array'
     or jsonb_typeof(v_detail->'capabilities') <> 'array' then
    raise exception 'R2S-FIX FAIL 6: resource_detail no trae el contrato completo';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_detail->'available_actions') e
    where not (e ? 'action_key' and e ? 'label' and e ? 'section' and e ? 'enabled'
               and e ? 'reason' and e ? 'required_rights' and e ? 'required_capabilities')
  ) then raise exception 'R2S-FIX FAIL 6: un action object no tiene la forma canónica de 7 campos'; end if;

  -- ═══ 7. No hay dos shapes: ningún action usa la key legacy 'action' ═══
  if exists (
    select 1 from jsonb_array_elements(v_detail->'available_actions') e
    where e ? 'action'    -- la key legacy {action,...} ya no debe existir
  ) then raise exception 'R2S-FIX FAIL 7: persiste el shape legacy {action,...}'; end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david, a_isaac], array[u_jose, u_david, u_isaac]);

  raise notice 'R.2S-FIX CANONICAL AVAILABLE ACTIONS: PASS (actor-aware + legacy delega + casa/cuenta/security + shape único action_key)';
end; $$;

revoke all on function public._smoke_r2s_fix_available_actions_contract() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2s_fix_available_actions_contract()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_r2s_fix_available_actions_contract(); end; $$;
revoke all on function public._smoke_mvp2_r2s_fix_available_actions_contract() from public, anon, authenticated;
comment on function public._smoke_mvp2_r2s_fix_available_actions_contract() is
  'Wrapper CI del smoke R.2S-FIX contrato canónico de available actions.';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Verificación inline del DoD R.2S-FIX
-- ────────────────────────────────────────────────────────────────────────────
do $$
begin
  -- firma actor-aware + legacy presentes
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'resource_available_actions') < 2 then
    raise exception 'R2S-FIX DoD: faltan las dos firmas de resource_available_actions';
  end if;
  raise notice 'R.2S-FIX DoD: contrato canónico de available actions (actor-aware + compat + shape único)';
end $$;
