-- ============================================================================
-- R.2M-3 — UNIVERSAL RESOURCE CAPABILITY SYSTEM (Final Doctrine)
-- ============================================================================
-- Cierra la doctrina de recursos: el comportamiento NUNCA se deriva de
-- resource_type. Se deriva de:
--   1. capabilities del recurso        (¿qué comportamientos soporta?)
--   2. rights del actor                (¿qué puede hacer este actor?)
--   3. available_actions (backend)     (¿qué puede ejecutar ahora mismo?)
--
--   resource_type        → CLASIFICA (¿qué es?)
--   capability           → HABILITA comportamiento
--   right                → AUTORIZA actores
--   available_action     → GOBIERNA la experiencia (el frontend renderiza esto)
--
-- Una acción solo se ofrece cuando:
--   resource_can(resource, capability) = true
--   AND el actor posee uno de los rights requeridos (directo o vía contexto)
--
-- Cambios:
--   • +capability `maintainable` (habilita acciones de mantenimiento)
--   • +tipos `digital_asset`, `trust_asset`
--   • matriz tipo→capability realineada a la doctrina (property/bank_account/
--     security NO reservable, etc.) — las 14 capabilities previas se conservan
--   • catálogo de acciones + resource_available_actions(resource_id)
--   • resource_detail() ahora devuelve capabilities + available_actions + why_visible
-- No se crea una tabla por tipo. No se rompe el schema MVP.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Nueva capability conductual: maintainable
-- ────────────────────────────────────────────────────────────────────────────
insert into public.resource_capabilities_catalog (capability_key, display_name, description) values
  ('maintainable', 'Mantenible', 'Puede registrar mantenimiento / servicio')
on conflict (capability_key) do nothing;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Tipos nuevos: digital_asset, trust_asset
-- ────────────────────────────────────────────────────────────────────────────
insert into public.resource_type_catalog (type_key, display_name, description, icon, metadata) values
  ('digital_asset', 'Activo digital', 'Cripto, dominio, propiedad intelectual u otro activo digital', 'externaldrive.fill.badge.icloud',
   '{"expected_metadata": {}}'),
  ('trust_asset', 'Activo de trust', 'Activo poseído por un trust / vehículo legal', 'building.columns.fill',
   '{"expected_metadata": {}}')
on conflict (type_key) do nothing;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Matriz tipo→capability — fuente única del comportamiento, alineada a la
--    doctrina. Reconstruimos la tabla entera (las filas del catálogo de
--    capabilities se conservan; solo cambia el mapeo).
-- ────────────────────────────────────────────────────────────────────────────
delete from public.resource_type_capabilities;

insert into public.resource_type_capabilities (type_key, capability_key)
select m.type_key, m.capability_key
from (values
  -- house: reservable, ownership_trackable, maintainable, auditable
  ('house','reservable'), ('house','ownership_trackable'), ('house','maintainable'), ('house','auditable'),
  -- property: ownership_trackable, auditable (NO reservable)
  ('property','ownership_trackable'), ('property','auditable'),
  -- vehicle: reservable, ownership_trackable, maintainable
  ('vehicle','reservable'), ('vehicle','ownership_trackable'), ('vehicle','maintainable'),
  -- bank_account: monetary, auditable, ownership_trackable (NO reservable)
  ('bank_account','monetary'), ('bank_account','auditable'), ('bank_account','ownership_trackable'),
  -- cash_pool: monetary, auditable
  ('cash_pool','monetary'), ('cash_pool','auditable'),
  -- security: ownership_trackable, beneficiary_supported, transferable, auditable (NO reservable, NO monetary)
  ('security','ownership_trackable'), ('security','beneficiary_supported'), ('security','transferable'), ('security','auditable'),
  -- contract: documentable, approval_required, auditable
  ('contract','documentable'), ('contract','approval_required'), ('contract','auditable'),
  -- document: documentable
  ('document','documentable'),
  -- equipment: reservable, maintainable, ownership_trackable
  ('equipment','reservable'), ('equipment','maintainable'), ('equipment','ownership_trackable'),
  -- trust_asset: ownership_trackable, beneficiary_supported, auditable
  ('trust_asset','ownership_trackable'), ('trust_asset','beneficiary_supported'), ('trust_asset','auditable'),
  -- digital_asset: ownership_trackable, transferable, auditable
  ('digital_asset','ownership_trackable'), ('digital_asset','transferable'), ('digital_asset','auditable'),
  -- trip_booking (fuera de la doctrina formal; sensible): reservable, documentable, transferable
  ('trip_booking','reservable'), ('trip_booking','documentable'), ('trip_booking','transferable'),
  -- game: auditable
  ('game','auditable'),
  -- other: ownership_trackable, auditable (sin affordances específicos)
  ('other','ownership_trackable'), ('other','auditable'),
  -- legacy no usados (conservados por compatibilidad del catálogo)
  ('reservation','reservable'),
  ('membership_asset','ownership_trackable'), ('membership_asset','transferable')
) as m(type_key, capability_key)
join public.resource_type_catalog t on t.type_key = m.type_key
join public.resource_capabilities_catalog c on c.capability_key = m.capability_key;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Catálogo de acciones — qué capability las habilita y qué rights las autorizan
-- ────────────────────────────────────────────────────────────────────────────
-- required_rights: any-of (basta uno). Vacío = no requiere right específico.
-- required_capability NULL = aplica a cualquier recurso (p. ej. grant_right).
create table public.resource_action_catalog (
  action_key text primary key,
  display_name text not null,
  description text,
  required_capability text references public.resource_capabilities_catalog(capability_key) on update cascade,
  required_rights text[] not null default '{}',
  ui_section text not null,
  sort_order int not null default 100,
  created_at timestamptz not null default now()
);

comment on table public.resource_action_catalog is
  'R.2M-3: acciones gobernadas por capability + rights. resource_available_actions() las resuelve por actor. El frontend renderiza desde el resultado, nunca desde resource_type.';

insert into public.resource_action_catalog
  (action_key, display_name, required_capability, required_rights, ui_section, sort_order) values
  -- Reservaciones (reservable)
  ('view_reservations',    'Ver reservaciones',     'reservable',            array['VIEW','USE','MANAGE','OWN','GOVERN'], 'reservations', 10),
  ('reserve_resource',     'Reservar',              'reservable',            array['USE','MANAGE','OWN'],                 'reservations', 11),
  ('manage_reservations',  'Administrar reservas',  'reservable',            array['MANAGE','OWN','GOVERN'],              'reservations', 12),
  -- Dinero (monetary)
  ('view_transactions',    'Ver movimientos',       'monetary',              array['VIEW','MANAGE','OWN','GOVERN'],       'money', 20),
  ('record_expense',       'Registrar gasto',       'monetary',              array['MANAGE','OWN'],                       'money', 21),
  ('record_contribution',  'Registrar aportación',  'monetary',              array['MANAGE','OWN'],                       'money', 22),
  ('generate_settlement',  'Generar liquidación',   'monetary',              array['MANAGE','OWN','GOVERN'],              'money', 23),
  -- Beneficiarios (beneficiary_supported)
  ('view_beneficiaries',   'Ver beneficiarios',     'beneficiary_supported', array['VIEW','MANAGE','OWN','GOVERN','BENEFICIARY'], 'beneficiaries', 30),
  ('grant_beneficiary',    'Designar beneficiario', 'beneficiary_supported', array['MANAGE','OWN'],                       'beneficiaries', 31),
  -- Participaciones / propiedad (ownership_trackable, transferable)
  ('view_ownership',       'Ver participaciones',   'ownership_trackable',   array['VIEW','USE','MANAGE','OWN','GOVERN','BENEFICIARY'], 'ownership', 40),
  ('transfer_interest',    'Transferir participación','transferable',        array['OWN'],                                'ownership', 41),
  -- Documentos (documentable)
  ('view_document',        'Ver documento',         'documentable',          array['VIEW','USE','MANAGE','OWN','GOVERN'], 'documents', 50),
  ('review_document',      'Revisar documento',     'documentable',          array['MANAGE','OWN'],                       'documents', 51),
  -- Aprobaciones (approval_required)
  ('approve_document',     'Aprobar',               'approval_required',     array['MANAGE','OWN','GOVERN'],              'approvals', 60),
  -- Mantenimiento (maintainable)
  ('view_maintenance',     'Ver mantenimiento',     'maintainable',          array['VIEW','USE','MANAGE','OWN','GOVERN'], 'maintenance', 70),
  ('log_maintenance',      'Registrar mantenimiento','maintainable',         array['MANAGE','OWN'],                       'maintenance', 71),
  -- Auditoría (auditable)
  ('view_audit',           'Ver auditoría',         'auditable',             array['VIEW','MANAGE','OWN','GOVERN'],       'audit', 80),
  -- Derechos (universal: cualquier recurso, requiere autoridad)
  ('grant_right',          'Otorgar derecho',       null,                    array['MANAGE','OWN','GOVERN'],              'rights', 90);

alter table public.resource_action_catalog enable row level security;
create policy resource_action_catalog_select on public.resource_action_catalog
  for select to authenticated using (true);
revoke all on public.resource_action_catalog from anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Helper: right kinds efectivos de un actor sobre un recurso
-- ────────────────────────────────────────────────────────────────────────────
-- Unión de: (a) rights directos del actor, (b) rights de un contexto donde el
-- actor administra recursos (resources.manage), y (c) 'VIEW' si el actor es
-- miembro de un contexto que tiene cualquier right sobre el recurso.
-- NB: (c) usa is_context_member (caller actual) → invocar solo para el caller.
create or replace function public._actor_effective_rights(p_actor uuid, p_resource uuid)
returns text[]
language sql stable security definer set search_path = public, auth
as $$
  select coalesce(array_agg(distinct k), array[]::text[])
  from (
    select rr.right_kind as k
      from public.resource_rights rr
     where rr.resource_id = p_resource and rr.holder_actor_id = p_actor
       and rr.revoked_at is null and rr.expired_at is null
       and (rr.starts_at is null or rr.starts_at <= now())
       and (rr.ends_at is null or rr.ends_at > now())
    union all
    select rr.right_kind
      from public.resource_rights rr
     where rr.resource_id = p_resource
       and rr.revoked_at is null and rr.expired_at is null
       and (rr.starts_at is null or rr.starts_at <= now())
       and (rr.ends_at is null or rr.ends_at > now())
       and public.has_actor_authority(rr.holder_actor_id, p_actor, 'resources.manage')
    union all
    select 'VIEW'
      from public.resource_rights rr
     where rr.resource_id = p_resource
       and rr.revoked_at is null and rr.expired_at is null
       and (rr.starts_at is null or rr.starts_at <= now())
       and (rr.ends_at is null or rr.ends_at > now())
       and public.is_context_member(rr.holder_actor_id)
  ) s;
$$;

revoke all on function public._actor_effective_rights(uuid, uuid) from public, anon;
grant execute on function public._actor_effective_rights(uuid, uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. resource_available_actions(resource_id) — para el actor actual
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.resource_available_actions(p_resource_id uuid)
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
  if not public._actor_can_view_resource(v_caller, p_resource_id) then
    raise exception 'not authorized to view resource %', p_resource_id using errcode = '42501';
  end if;

  v_rights := public._actor_effective_rights(v_caller, p_resource_id);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'action', a.action_key,
      'label', a.display_name,
      'section', a.ui_section
    ) order by a.sort_order, a.action_key)
    from public.resource_action_catalog a
    where (a.required_capability is null
           or public.resource_can(p_resource_id, a.required_capability))
      and (cardinality(a.required_rights) = 0
           or a.required_rights && v_rights)
  ), '[]'::jsonb);
end; $$;

revoke all on function public.resource_available_actions(uuid) from public, anon;
grant execute on function public.resource_available_actions(uuid) to authenticated, service_role;

comment on function public.resource_available_actions(uuid) is
  'R.2M-3: acciones que el actor actual puede ejecutar sobre el recurso (capability ∩ rights). El frontend renderiza la UX desde aquí.';

-- ────────────────────────────────────────────────────────────────────────────
-- 7. resource_detail v4: + capabilities + available_actions + why_visible
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
    -- R.2M: el frontend pregunta "¿qué capabilities / available_actions tengo?",
    -- no "¿es una casa?"
    'resource_type', v_resource.resource_type,
    'metadata', v_resource.metadata,
    'capabilities', coalesce((
      select jsonb_agg(tc.capability_key order by tc.capability_key)
        from public.resource_type_capabilities tc
       where tc.type_key = v_resource.resource_type), '[]'::jsonb),
    -- R.2M-3: acciones gobernadas por backend; la UX se renderiza desde esto
    'available_actions', public.resource_available_actions(p_resource_id),
    -- R.2M-3: por qué este actor ve el recurso (rights directos + vía contexto)
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
  'R.2M-3: detalle de recurso con rights + resource_type + capabilities + available_actions + why_visible + metadata.';

-- ────────────────────────────────────────────────────────────────────────────
-- 8. Smoke — _smoke_r2m3_available_actions (los 6 casos de la doctrina)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2m3_available_actions()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  v_ctx uuid;
  v_casa uuid; v_cuenta uuid; v_acciones uuid; v_contrato uuid; v_vehiculo uuid; v_trust uuid;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2M3', '+5210000061');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Patrimonio R2M3', 'collective', 'family'))->>'context_actor_id';

  -- Un recurso de cada tipo, propiedad del contexto (José es founder/admin → OWN efectivo)
  v_casa     := (public.create_resource(v_ctx::uuid, 'house', 'Casa Valle'))->>'resource_id';
  v_cuenta   := (public.create_resource(v_ctx::uuid, 'bank_account', 'Cuenta del Viaje'))->>'resource_id';
  v_acciones := (public.create_resource(v_ctx::uuid, 'security', 'Acciones Quimibond'))->>'resource_id';
  v_contrato := (public.create_resource(v_ctx::uuid, 'contract', 'Contrato Arrendamiento'))->>'resource_id';
  v_vehiculo := (public.create_resource(v_ctx::uuid, 'vehicle', 'Vehículo Familiar'))->>'resource_id';
  v_trust    := (public.create_resource(v_ctx::uuid, 'trust_asset', 'Activo del Trust'))->>'resource_id';

  -- ════════════ Casa Valle: reservable, NO monetary ════════════
  if not public.resource_can(v_casa::uuid, 'reservable') then raise exception 'R2M3 FAIL casa: reservable debe ser true'; end if;
  if public.resource_can(v_casa::uuid, 'monetary') then raise exception 'R2M3 FAIL casa: monetary debe ser false'; end if;
  if not public._r2m3_has_action(v_casa::uuid, 'reserve_resource') then raise exception 'R2M3 FAIL casa: falta reserve_resource'; end if;
  if not public._r2m3_has_action(v_casa::uuid, 'view_reservations') then raise exception 'R2M3 FAIL casa: falta view_reservations'; end if;
  if public._r2m3_has_action(v_casa::uuid, 'record_expense') then raise exception 'R2M3 FAIL casa: NO debe ofrecer record_expense'; end if;

  -- ════════════ Cuenta del Viaje: monetary, NO reservable ════════════
  if not public.resource_can(v_cuenta::uuid, 'monetary') then raise exception 'R2M3 FAIL cuenta: monetary debe ser true'; end if;
  if public.resource_can(v_cuenta::uuid, 'reservable') then raise exception 'R2M3 FAIL cuenta: reservable debe ser false'; end if;
  if not public._r2m3_has_action(v_cuenta::uuid, 'record_expense') then raise exception 'R2M3 FAIL cuenta: falta record_expense'; end if;
  if not public._r2m3_has_action(v_cuenta::uuid, 'record_contribution') then raise exception 'R2M3 FAIL cuenta: falta record_contribution'; end if;
  if not public._r2m3_has_action(v_cuenta::uuid, 'generate_settlement') then raise exception 'R2M3 FAIL cuenta: falta generate_settlement'; end if;
  if public._r2m3_has_action(v_cuenta::uuid, 'reserve_resource') then raise exception 'R2M3 FAIL cuenta: NO debe ofrecer reserve_resource'; end if;

  -- ════════════ Acciones Quimibond (security): beneficiary + ownership, NO reservable/monetary ════════════
  if not public.resource_can(v_acciones::uuid, 'beneficiary_supported') then raise exception 'R2M3 FAIL acciones: beneficiary_supported true'; end if;
  if not public.resource_can(v_acciones::uuid, 'ownership_trackable') then raise exception 'R2M3 FAIL acciones: ownership_trackable true'; end if;
  if public.resource_can(v_acciones::uuid, 'reservable') then raise exception 'R2M3 FAIL acciones: reservable false'; end if;
  if public.resource_can(v_acciones::uuid, 'monetary') then raise exception 'R2M3 FAIL acciones: monetary false'; end if;
  if not public._r2m3_has_action(v_acciones::uuid, 'view_beneficiaries') then raise exception 'R2M3 FAIL acciones: falta view_beneficiaries'; end if;
  if not public._r2m3_has_action(v_acciones::uuid, 'transfer_interest') then raise exception 'R2M3 FAIL acciones: falta transfer_interest'; end if;
  if public._r2m3_has_action(v_acciones::uuid, 'reserve_resource') then raise exception 'R2M3 FAIL acciones: NO reserve_resource'; end if;
  if public._r2m3_has_action(v_acciones::uuid, 'record_expense') then raise exception 'R2M3 FAIL acciones: NO record_expense'; end if;

  -- ════════════ Contrato: documentable + approval_required ════════════
  if not public.resource_can(v_contrato::uuid, 'documentable') then raise exception 'R2M3 FAIL contrato: documentable true'; end if;
  if not public.resource_can(v_contrato::uuid, 'approval_required') then raise exception 'R2M3 FAIL contrato: approval_required true'; end if;
  if not public._r2m3_has_action(v_contrato::uuid, 'view_document') then raise exception 'R2M3 FAIL contrato: falta view_document'; end if;
  if not public._r2m3_has_action(v_contrato::uuid, 'approve_document') then raise exception 'R2M3 FAIL contrato: falta approve_document'; end if;
  if public._r2m3_has_action(v_contrato::uuid, 'reserve_resource') then raise exception 'R2M3 FAIL contrato: NO reserve_resource'; end if;

  -- ════════════ Vehículo: reservable + maintainable ════════════
  if not public.resource_can(v_vehiculo::uuid, 'reservable') then raise exception 'R2M3 FAIL vehiculo: reservable true'; end if;
  if not public.resource_can(v_vehiculo::uuid, 'maintainable') then raise exception 'R2M3 FAIL vehiculo: maintainable true'; end if;
  if not public._r2m3_has_action(v_vehiculo::uuid, 'reserve_resource') then raise exception 'R2M3 FAIL vehiculo: falta reserve_resource'; end if;
  if not public._r2m3_has_action(v_vehiculo::uuid, 'view_maintenance') then raise exception 'R2M3 FAIL vehiculo: falta view_maintenance'; end if;

  -- ════════════ Trust Asset: beneficiary + auditable ════════════
  if not public.resource_can(v_trust::uuid, 'beneficiary_supported') then raise exception 'R2M3 FAIL trust: beneficiary_supported true'; end if;
  if not public.resource_can(v_trust::uuid, 'auditable') then raise exception 'R2M3 FAIL trust: auditable true'; end if;
  if not public._r2m3_has_action(v_trust::uuid, 'view_beneficiaries') then raise exception 'R2M3 FAIL trust: falta view_beneficiaries'; end if;
  if not public._r2m3_has_action(v_trust::uuid, 'view_audit') then raise exception 'R2M3 FAIL trust: falta view_audit'; end if;

  -- grant_right disponible en todos (José administra el contexto dueño)
  if not public._r2m3_has_action(v_casa::uuid, 'grant_right') then raise exception 'R2M3 FAIL: falta grant_right'; end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose], array[u_jose]);

  raise notice 'R.2M-3 AVAILABLE ACTIONS: PASS (casa/cuenta/acciones/contrato/vehículo/trust con affordances correctos)';
end; $$;

revoke all on function public._smoke_r2m3_available_actions() from public, anon, authenticated;

-- helper de aserción: ¿available_actions del recurso incluye la acción?
create or replace function public._r2m3_has_action(p_resource_id uuid, p_action text)
returns boolean
language sql stable security definer set search_path = public, auth
as $$
  select exists (
    select 1 from jsonb_array_elements(public.resource_available_actions(p_resource_id)) e
    where e->>'action' = p_action
  );
$$;
revoke all on function public._r2m3_has_action(uuid, text) from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 9. Smoke — _smoke_r2m3_detail_contract (resource_detail trae el contrato completo)
-- ────────────────────────────────────────────────────────────────────────────
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
  -- contenido: capabilities incluye reservable; available_actions trae objetos {action,label,section}
  if not (v_detail->'capabilities') ? 'reservable' then raise exception 'R2M3 detail: capabilities sin reservable'; end if;
  if not exists (
    select 1 from jsonb_array_elements(v_detail->'available_actions') e
    where e ? 'action' and e ? 'label' and e ? 'section' and e->>'section' = 'reservations'
  ) then raise exception 'R2M3 detail: available_actions sin la sección reservations'; end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose], array[u_jose]);

  raise notice 'R.2M-3 DETAIL CONTRACT: PASS (resource + capabilities + available_actions + why_visible + rights)';
end; $$;

revoke all on function public._smoke_r2m3_detail_contract() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 10. Wrappers CI (_smoke_mvp2_*)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_r2m3_available_actions()
returns void language plpgsql security definer set search_path = public as $$
begin perform public._smoke_r2m3_available_actions(); end; $$;
revoke all on function public._smoke_mvp2_r2m3_available_actions() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2m3_detail_contract()
returns void language plpgsql security definer set search_path = public as $$
begin perform public._smoke_r2m3_detail_contract(); end; $$;
revoke all on function public._smoke_mvp2_r2m3_detail_contract() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 11. Verificación inline del DoD R.2M-3
-- ────────────────────────────────────────────────────────────────────────────
do $$
begin
  -- maintainable existe
  if not exists (select 1 from public.resource_capabilities_catalog where capability_key = 'maintainable') then
    raise exception 'R2M3 DoD: falta capability maintainable';
  end if;
  -- tipos nuevos
  if not exists (select 1 from public.resource_type_catalog where type_key = 'digital_asset')
     or not exists (select 1 from public.resource_type_catalog where type_key = 'trust_asset') then
    raise exception 'R2M3 DoD: faltan tipos digital_asset/trust_asset';
  end if;
  -- catálogo de acciones poblado
  if (select count(*) from public.resource_action_catalog) < 18 then
    raise exception 'R2M3 DoD: catálogo de acciones incompleto';
  end if;
  -- RPCs presentes
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('resource_available_actions', 'resource_can', 'resource_capabilities')) < 3 then
    raise exception 'R2M3 DoD: faltan RPCs';
  end if;
  -- matriz alineada a la doctrina (puntos críticos: NO reservable donde no aplica)
  if exists (select 1 from public.resource_type_capabilities where type_key = 'bank_account' and capability_key = 'reservable')
     or exists (select 1 from public.resource_type_capabilities where type_key = 'security' and capability_key = 'reservable')
     or exists (select 1 from public.resource_type_capabilities where type_key = 'property' and capability_key = 'reservable') then
    raise exception 'R2M3 DoD: bank_account/security/property no deben ser reservable';
  end if;
  if not exists (select 1 from public.resource_type_capabilities where type_key = 'security' and capability_key = 'transferable') then
    raise exception 'R2M3 DoD: security debe ser transferable';
  end if;

  raise notice 'R.2M-3 DoD: capabilities + tipos + catálogo de acciones + available_actions + matriz doctrinal en su lugar';
end $$;
