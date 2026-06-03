-- ============================================================================
-- R.2M — RESOURCE TYPE SYSTEM + CAPABILITIES
-- ============================================================================
-- Doctrina del founder: resources es una primitiva extensible. No todos los
-- recursos son iguales (una casa se reserva, una cuenta mueve dinero, un
-- documento expira) pero NO se crea una tabla por tipo — el comportamiento
-- se describe con un catálogo de tipos y capabilities.
--
--   resource_type_catalog         → tipos oficiales (house, vehicle, …)
--   resource_capabilities_catalog → capacidades (reservable, monetary, …)
--   resource_type_capabilities    → mapeo tipo → capability
--
-- El CHECK hardcodeado de resources.resource_type se reemplaza por un FK al
-- catálogo: agregar un tipo nuevo es INSERT de configuración, no migración
-- de schema. resources NO se modifica estructuralmente, no se mueven datos
-- y no se rompe compatibilidad (todos los tipos legacy viven en el catálogo).
--
-- RPCs nuevos:
--   resource_type_catalog()            → catálogo completo con capabilities
--   resource_capabilities(resource_id) → tipo + capabilities de un recurso
--   resource_can(resource_id, cap)     → boolean
--
-- Hardcode reemplazado: request_resource_reservation ya no asume que
-- cualquier recurso se puede reservar — exige la capability 'reservable'.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. resource_type_catalog
-- ────────────────────────────────────────────────────────────────────────────
create table public.resource_type_catalog (
  id uuid primary key default gen_random_uuid(),
  type_key text not null unique,
  display_name text not null,
  description text,
  icon text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_resource_type_catalog_touch before update on public.resource_type_catalog
  for each row execute function public.touch_updated_at();

comment on table public.resource_type_catalog is
  'R.2M: tipos oficiales de recurso. metadata.expected_metadata documenta el esquema esperado (no se valida rígidamente todavía).';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. resource_capabilities_catalog
-- ────────────────────────────────────────────────────────────────────────────
create table public.resource_capabilities_catalog (
  capability_key text primary key,
  display_name text not null,
  description text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);

comment on table public.resource_capabilities_catalog is
  'R.2M: capacidades que un tipo de recurso puede tener (reservable, monetary, expirable, …).';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. resource_type_capabilities (mapeo tipo → capability)
-- ────────────────────────────────────────────────────────────────────────────
create table public.resource_type_capabilities (
  type_key text not null references public.resource_type_catalog(type_key) on update cascade on delete cascade,
  capability_key text not null references public.resource_capabilities_catalog(capability_key) on update cascade on delete cascade,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  primary key (type_key, capability_key)
);

comment on table public.resource_type_capabilities is
  'R.2M: qué capabilities tiene cada tipo. El backend responde resource_can() desde aquí, sin lógica hardcodeada por tipo.';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Seed: capabilities
-- ────────────────────────────────────────────────────────────────────────────
insert into public.resource_capabilities_catalog (capability_key, display_name, description) values
  ('reservable',            'Reservable',               'Puede reservarse en bloques de tiempo'),
  ('monetary',              'Monetario',                'Puede registrar y mover dinero'),
  ('transferable',          'Transferible',             'Puede transferirse a otro actor'),
  ('shareable',             'Compartible',              'Puede compartirse con varios actores vía rights'),
  ('governable',            'Gobernable',               'Puede someterse a decisiones del contexto'),
  ('beneficiary_supported', 'Con beneficiarios',        'Puede tener beneficiarios designados'),
  ('approval_required',     'Requiere aprobación',      'Sus cambios requieren aprobación'),
  ('expirable',             'Expirable',                'Tiene fecha de expiración'),
  ('depreciable',           'Depreciable',              'Pierde valor en el tiempo'),
  ('documentable',          'Documentable',             'Puede tener documentos asociados'),
  ('sellable',              'Vendible',                 'Puede venderse'),
  ('rentable',              'Rentable',                 'Puede rentarse a terceros'),
  ('auditable',             'Auditable',                'Sus movimientos quedan auditados'),
  ('ownership_trackable',   'Propiedad rastreable',     'Su propiedad (OWN %) se rastrea por porcentajes');

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Seed: tipos (12 legacy + membership_asset + security)
-- ────────────────────────────────────────────────────────────────────────────
-- metadata.expected_metadata documenta el Resource Metadata Contract por tipo.
insert into public.resource_type_catalog (type_key, display_name, description, icon, metadata) values
  ('house', 'Casa', 'Casa o vivienda compartida', 'house.fill',
   '{"expected_metadata": {"capacity": "integer", "address": "string", "bedrooms": "integer"}}'),
  ('property', 'Propiedad', 'Terreno o propiedad inmobiliaria', 'map.fill',
   '{"expected_metadata": {"address": "string"}}'),
  ('vehicle', 'Vehículo', 'Automóvil, moto u otro vehículo', 'car.fill',
   '{"expected_metadata": {"vin": "string", "plate": "string", "seats": "integer"}}'),
  ('bank_account', 'Cuenta bancaria', 'Cuenta en una institución financiera', 'banknote.fill',
   '{"expected_metadata": {"institution": "string", "currency": "string", "account_last4": "string"}}'),
  ('cash_pool', 'Fondo común', 'Bolsa de dinero compartida del contexto', 'dollarsign.circle.fill',
   '{"expected_metadata": {"currency": "string"}}'),
  ('contract', 'Contrato', 'Contrato o acuerdo legal', 'signature',
   '{"expected_metadata": {"effective_date": "date", "expiration_date": "date"}}'),
  ('document', 'Documento', 'Documento o archivo registrado', 'doc.fill',
   '{"expected_metadata": {"document_type": "string", "expiration_date": "date"}}'),
  ('reservation', 'Reservación', 'Tipo legacy pre-R.2M (usar trip_booking o el recurso reservable)', 'calendar',
   '{"legacy": true, "expected_metadata": {}}'),
  ('trip_booking', 'Reserva de viaje', 'Vuelo, hotel u otra reservación de viaje', 'airplane',
   '{"expected_metadata": {}}'),
  ('equipment', 'Equipo', 'Herramienta o equipo compartido', 'wrench.and.screwdriver.fill',
   '{"expected_metadata": {}}'),
  ('game', 'Juego', 'Juego o actividad con resultados', 'gamecontroller.fill',
   '{"expected_metadata": {}}'),
  ('membership_asset', 'Membresía', 'Membresía de club, gimnasio o comunidad', 'person.crop.circle.badge.checkmark',
   '{"expected_metadata": {}}'),
  ('security', 'Título financiero', 'Acciones, bonos u otros valores', 'chart.line.uptrend.xyaxis',
   '{"expected_metadata": {}}'),
  ('other', 'Otro', 'Recurso sin tipo específico', 'shippingbox.fill',
   '{"expected_metadata": {}}');

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Seed: mapeo tipo → capabilities
-- ────────────────────────────────────────────────────────────────────────────
insert into public.resource_type_capabilities (type_key, capability_key)
select t.type_key, c.capability_key
from (values
  ('house',            'reservable'),
  ('house',            'shareable'),
  ('house',            'governable'),
  ('house',            'ownership_trackable'),
  ('house',            'rentable'),

  ('property',         'reservable'),
  ('property',         'shareable'),
  ('property',         'governable'),
  ('property',         'ownership_trackable'),
  ('property',         'rentable'),
  ('property',         'sellable'),

  ('vehicle',          'reservable'),
  ('vehicle',          'ownership_trackable'),
  ('vehicle',          'depreciable'),
  ('vehicle',          'sellable'),

  ('bank_account',     'monetary'),
  ('bank_account',     'auditable'),
  ('bank_account',     'ownership_trackable'),

  ('cash_pool',        'monetary'),
  ('cash_pool',        'auditable'),
  ('cash_pool',        'shareable'),

  ('contract',         'documentable'),
  ('contract',         'approval_required'),
  ('contract',         'expirable'),

  ('document',         'documentable'),
  ('document',         'expirable'),

  ('reservation',      'reservable'),
  ('reservation',      'expirable'),

  ('trip_booking',     'reservable'),
  ('trip_booking',     'expirable'),
  ('trip_booking',     'documentable'),
  ('trip_booking',     'transferable'),

  ('equipment',        'reservable'),
  ('equipment',        'shareable'),
  ('equipment',        'ownership_trackable'),
  ('equipment',        'depreciable'),

  ('game',             'shareable'),
  ('game',             'auditable'),

  ('membership_asset', 'ownership_trackable'),
  ('membership_asset', 'transferable'),
  ('membership_asset', 'expirable'),

  ('security',         'ownership_trackable'),
  ('security',         'beneficiary_supported'),
  ('security',         'auditable'),

  ('other',            'shareable'),
  ('other',            'ownership_trackable')
) as m(type_key, capability_key)
join public.resource_type_catalog t on t.type_key = m.type_key
join public.resource_capabilities_catalog c on c.capability_key = m.capability_key;

-- ────────────────────────────────────────────────────────────────────────────
-- 7. resources.resource_type: CHECK hardcodeado → FK al catálogo
-- ────────────────────────────────────────────────────────────────────────────
-- "Nuevos tipos pueden agregarse mediante configuración" — el whitelist deja
-- de vivir en un CHECK y pasa a ser una fila del catálogo.
do $$
declare
  v_con text;
begin
  select conname into v_con
    from pg_constraint
   where conrelid = 'public.resources'::regclass
     and contype = 'c'
     and pg_get_constraintdef(oid) like '%resource_type%';
  if v_con is not null then
    execute format('alter table public.resources drop constraint %I', v_con);
  end if;
end $$;

alter table public.resources
  add constraint resources_resource_type_fk
  foreign key (resource_type) references public.resource_type_catalog(type_key)
  on update cascade;

-- ────────────────────────────────────────────────────────────────────────────
-- 8. RLS: catálogos globales, lectura para authenticated
-- ────────────────────────────────────────────────────────────────────────────
alter table public.resource_type_catalog enable row level security;
alter table public.resource_capabilities_catalog enable row level security;
alter table public.resource_type_capabilities enable row level security;

create policy resource_type_catalog_select on public.resource_type_catalog
  for select to authenticated using (true);

create policy resource_capabilities_catalog_select on public.resource_capabilities_catalog
  for select to authenticated using (true);

create policy resource_type_capabilities_select on public.resource_type_capabilities
  for select to authenticated using (true);

revoke all on public.resource_type_catalog, public.resource_capabilities_catalog,
       public.resource_type_capabilities from anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 9. resource_can(resource_id, capability)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.resource_can(p_resource_id uuid, p_capability text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
      from public.resources r
      join public.resource_type_capabilities tc on tc.type_key = r.resource_type
     where r.id = p_resource_id
       and tc.capability_key = p_capability
  );
$$;

revoke all on function public.resource_can(uuid, text) from public, anon;
grant execute on function public.resource_can(uuid, text) to authenticated, service_role;

comment on function public.resource_can(uuid, text) is
  'R.2M: ¿el tipo de este recurso tiene esta capability? La lógica por tipo vive en el catálogo, no en IFs.';

-- ────────────────────────────────────────────────────────────────────────────
-- 10. resource_type_catalog(): catálogo completo para el frontend
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.resource_type_catalog()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'type_key', t.type_key,
    'display_name', t.display_name,
    'description', t.description,
    'icon', t.icon,
    'expected_metadata', coalesce(t.metadata->'expected_metadata', '{}'::jsonb),
    'capabilities', coalesce((
      select jsonb_agg(tc.capability_key order by tc.capability_key)
        from public.resource_type_capabilities tc
       where tc.type_key = t.type_key), '[]'::jsonb)
  ) order by t.type_key), '[]'::jsonb)
  from public.resource_type_catalog t;
$$;

revoke all on function public.resource_type_catalog() from public, anon;
grant execute on function public.resource_type_catalog() to authenticated, service_role;

comment on function public.resource_type_catalog() is
  'R.2M: catálogo de tipos con sus capabilities y metadata contract. El frontend renderiza recursos por capabilities, no por tipo.';

-- ────────────────────────────────────────────────────────────────────────────
-- 11. resource_capabilities(resource_id): tipo + capabilities de un recurso
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.resource_capabilities(p_resource_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_resource public.resources%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_resource from public.resources where id = p_resource_id;
  if v_resource.id is null then raise exception 'resource not found' using errcode = 'P0002'; end if;

  -- misma visibilidad rights-based que resource_detail (R.2C)
  if not public._actor_can_view_resource(v_caller, p_resource_id) then
    raise exception 'not authorized to view resource %', p_resource_id using errcode = '42501';
  end if;

  return jsonb_build_object(
    'resource_id', v_resource.id,
    'resource_type', v_resource.resource_type,
    'capabilities', coalesce((
      select jsonb_agg(tc.capability_key order by tc.capability_key)
        from public.resource_type_capabilities tc
       where tc.type_key = v_resource.resource_type), '[]'::jsonb));
end; $$;

revoke all on function public.resource_capabilities(uuid) from public, anon;
grant execute on function public.resource_capabilities(uuid) to authenticated, service_role;

comment on function public.resource_capabilities(uuid) is
  'R.2M: resource_id + resource_type + capabilities[] de un recurso. Visibilidad rights-based (R.2C).';

-- ────────────────────────────────────────────────────────────────────────────
-- 12. resource_detail v3: ahora devuelve resource_type + capabilities + metadata
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
    -- R.2M: el frontend pregunta "¿qué capabilities tiene?", no "¿es una casa?"
    'resource_type', v_resource.resource_type,
    'metadata', v_resource.metadata,
    'capabilities', coalesce((
      select jsonb_agg(tc.capability_key order by tc.capability_key)
        from public.resource_type_capabilities tc
       where tc.type_key = v_resource.resource_type), '[]'::jsonb),
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
  'R.2M: detalle de recurso con rights activos + resource_type + capabilities + metadata.';

-- ────────────────────────────────────────────────────────────────────────────
-- 13. request_resource_reservation v3: exige capability reservable
-- ────────────────────────────────────────────────────────────────────────────
-- Reemplaza el hardcode implícito "cualquier recurso se puede reservar" por
-- resource_can(resource_id, 'reservable'). El resto del comportamiento R.2F
-- (rights-based + least_recent_use_wins) se preserva intacto.
create or replace function public.request_resource_reservation(
  p_resource_id uuid,
  p_context_actor_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_reserved_for_actor_id uuid default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_target uuid;
  v_id uuid;
  v_existing uuid;
  v_conflicts integer;
  v_recent_use integer;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  v_target := coalesce(p_reserved_for_actor_id, v_caller);

  if not exists (select 1 from public.resources where id = p_resource_id and archived_at is null) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;

  -- R.2M: solo los tipos con capability 'reservable' pueden reservarse
  if not public.resource_can(p_resource_id, 'reservable') then
    raise exception 'resource type does not support reservations' using errcode = '22023';
  end if;

  -- R.2F: los rights explican quién puede reservar — USE/MANAGE/OWN (VIEW no).
  -- También puede reservar quien ejerce los rights de un holder colectivo
  -- (ej. admin del contexto dueño, vía resources.manage).
  if not (
    public.actor_has_right(v_caller, p_resource_id, 'USE')
    or public.actor_has_right(v_caller, p_resource_id, 'MANAGE')
    or public.actor_has_right(v_caller, p_resource_id, 'OWN')
    or exists (
      select 1 from public.resource_rights rr
      where rr.resource_id = p_resource_id
        and rr.right_kind in ('USE', 'MANAGE', 'OWN', 'GOVERN')
        and rr.revoked_at is null and rr.expired_at is null
        and (rr.starts_at is null or rr.starts_at <= now())
        and (rr.ends_at is null or rr.ends_at > now())
        and public.has_actor_authority(rr.holder_actor_id, v_caller, 'resources.manage'))
  ) then
    raise exception 'reserving requires USE, MANAGE or OWN right on resource %', p_resource_id using errcode = '42501';
  end if;

  -- idempotencia por client_id
  if p_client_id is not null then
    select id into v_existing from public.resource_reservations
     where requested_by_actor_id = v_caller and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('reservation_id', v_existing,
        'reservation', (select to_jsonb(r) from public.resource_reservations r where r.id = v_existing));
    end if;
  end if;

  -- R.2F priority (least_recent_use_wins): uso confirmado/completado del recurso
  -- en los últimos 90 días — menos uso = mejor prioridad
  select count(*) into v_recent_use from public.resource_reservations rr
   where rr.resource_id = p_resource_id
     and rr.reserved_for_actor_id = v_target
     and rr.status in ('confirmed', 'completed')
     and rr.starts_at > now() - interval '90 days';

  insert into public.resource_reservations
    (resource_id, context_actor_id, requested_by_actor_id, reserved_for_actor_id,
     starts_at, ends_at, metadata, client_id, priority_score)
  values
    (p_resource_id, p_context_actor_id, v_caller, v_target,
     p_starts_at, p_ends_at,
     coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
       'priority_rule', 'least_recent_use_wins', 'recent_use_count', v_recent_use),
     p_client_id, v_recent_use)
  returning id into v_id;

  -- detección inmediata de conflictos
  select count(*) into v_conflicts from public.detect_reservation_conflicts(p_resource_id);

  perform public._emit_activity(p_context_actor_id, v_caller, 'reservation.requested', 'reservation', v_id,
    jsonb_build_object('resource_id', p_resource_id, 'starts_at', p_starts_at, 'ends_at', p_ends_at,
                       'conflicts_detected', v_conflicts, 'priority_score', v_recent_use),
    p_resource_id := p_resource_id);

  return jsonb_build_object('reservation_id', v_id, 'conflicts_detected', v_conflicts,
    'reservation', (select to_jsonb(r) from public.resource_reservations r where r.id = v_id));
end; $$;

revoke all on function public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text) from public, anon;
grant execute on function public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 14. Smoke 1 — _smoke_r2m_resource_capabilities
-- ────────────────────────────────────────────────────────────────────────────
-- Casa Valle (house) → reservable sí, monetary no
-- Cuenta BBVA (bank_account) → monetary sí, reservable no (y no se puede reservar)
-- Contrato Arrendamiento (contract) → approval_required + documentable
create or replace function public._smoke_r2m_resource_capabilities()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  v_ctx uuid; v_casa uuid; v_cuenta uuid; v_contrato uuid;
  v_result jsonb;
  v_caught boolean;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2M', '+5210000041');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Familia Mizrahi R2M', 'collective', 'family'))->>'context_actor_id';

  v_casa := (public.create_resource(v_ctx::uuid, 'house', 'Casa Valle R2M'))->>'resource_id';
  v_cuenta := (public.create_resource(v_ctx::uuid, 'bank_account', 'Cuenta BBVA R2M'))->>'resource_id';
  v_contrato := (public.create_resource(v_ctx::uuid, 'contract', 'Contrato Arrendamiento R2M'))->>'resource_id';

  -- ═══ 1. Casa Valle: reservable=true, monetary=false ═══
  if not public.resource_can(v_casa::uuid, 'reservable') then
    raise exception 'R2M FAIL 1: Casa Valle debería ser reservable';
  end if;
  if public.resource_can(v_casa::uuid, 'monetary') then
    raise exception 'R2M FAIL 1: Casa Valle no debería ser monetary';
  end if;

  -- ═══ 2. Cuenta BBVA: monetary=true, reservable=false ═══
  if not public.resource_can(v_cuenta::uuid, 'monetary') then
    raise exception 'R2M FAIL 2: Cuenta BBVA debería ser monetary';
  end if;
  if public.resource_can(v_cuenta::uuid, 'reservable') then
    raise exception 'R2M FAIL 2: Cuenta BBVA no debería ser reservable';
  end if;

  -- ═══ 3. Contrato: approval_required=true, documentable=true ═══
  if not public.resource_can(v_contrato::uuid, 'approval_required') then
    raise exception 'R2M FAIL 3: el Contrato debería requerir aprobación';
  end if;
  if not public.resource_can(v_contrato::uuid, 'documentable') then
    raise exception 'R2M FAIL 3: el Contrato debería ser documentable';
  end if;

  -- ═══ 4. resource_capabilities(): shape {resource_id, resource_type, capabilities[]} ═══
  v_result := public.resource_capabilities(v_casa::uuid);
  if (v_result->>'resource_id')::uuid is distinct from v_casa::uuid
     or v_result->>'resource_type' <> 'house' then
    raise exception 'R2M FAIL 4: resource_capabilities devuelve resource_id/resource_type incorrectos';
  end if;
  if not (v_result->'capabilities') ? 'reservable' then
    raise exception 'R2M FAIL 4: capabilities de Casa Valle no incluyen reservable';
  end if;
  if (v_result->'capabilities') ? 'monetary' then
    raise exception 'R2M FAIL 4: capabilities de Casa Valle incluyen monetary';
  end if;

  -- ═══ 5. resource_type_catalog(): catálogo completo con capabilities ═══
  v_result := public.resource_type_catalog();
  if jsonb_array_length(v_result) < 14 then
    raise exception 'R2M FAIL 5: el catálogo de tipos tiene menos de 14 entradas';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_result) t
    where t->>'type_key' = 'house' and (t->'capabilities') ? 'reservable'
  ) then
    raise exception 'R2M FAIL 5: el catálogo no reporta house como reservable';
  end if;

  -- ═══ 6. La capability gobierna el comportamiento: reservar la cuenta falla ═══
  v_caught := false;
  begin
    perform public.request_resource_reservation(v_cuenta::uuid, v_ctx::uuid,
      now() + interval '1 day', now() + interval '2 days');
  exception when sqlstate '22023' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'R2M FAIL 6: se pudo reservar una cuenta bancaria (no reservable)';
  end if;

  -- … y reservar la casa funciona
  if (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
        now() + interval '1 day', now() + interval '2 days'))->>'reservation_id' is null then
    raise exception 'R2M FAIL 6: no se pudo reservar Casa Valle (reservable)';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose], array[u_jose]);

  raise notice 'R.2M RESOURCE CAPABILITIES: PASS (casa reservable, cuenta monetary, contrato approval_required)';
end; $$;

revoke all on function public._smoke_r2m_resource_capabilities() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 15. Smoke 2 — _smoke_r2m_resource_metadata
-- ────────────────────────────────────────────────────────────────────────────
-- Un recurso de cada tipo del catálogo: metadata persiste y resource_detail
-- devuelve resource_type + capabilities + metadata.
create or replace function public._smoke_r2m_resource_metadata()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  v_ctx uuid; v_res uuid;
  v_type record;
  v_meta jsonb;
  v_detail jsonb;
  v_expected_caps integer;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2M-meta', '+5210000042');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Contexto R2M metadata', 'collective', 'friend_group'))->>'context_actor_id';

  for v_type in select type_key from public.resource_type_catalog order by type_key loop
    -- metadata de ejemplo siguiendo el contract del tipo (cuando lo hay)
    v_meta := case v_type.type_key
      when 'house' then '{"capacity": 8, "address": "Valle 123", "bedrooms": 4}'::jsonb
      when 'vehicle' then '{"vin": "1HGBH41JXMN109186", "plate": "ABC-123", "seats": 5}'::jsonb
      when 'bank_account' then '{"institution": "BBVA", "currency": "MXN", "account_last4": "4821"}'::jsonb
      when 'document' then '{"document_type": "escritura", "expiration_date": "2030-01-01"}'::jsonb
      when 'contract' then '{"effective_date": "2026-06-03", "expiration_date": "2027-06-03"}'::jsonb
      else jsonb_build_object('r2m_smoke', v_type.type_key)
    end;

    v_res := (public.create_resource(v_ctx::uuid, v_type.type_key,
      'R2M meta ' || v_type.type_key, p_metadata := v_meta))->>'resource_id';

    -- ═══ metadata persiste tal cual ═══
    if (select metadata from public.resources where id = v_res::uuid) <> v_meta then
      raise exception 'R2M FAIL meta: metadata de % no persistió', v_type.type_key;
    end if;

    -- ═══ resource_detail devuelve resource_type + capabilities + metadata ═══
    v_detail := public.resource_detail(v_res::uuid);
    if v_detail->>'resource_type' <> v_type.type_key then
      raise exception 'R2M FAIL meta: resource_detail no devuelve resource_type de %', v_type.type_key;
    end if;
    if v_detail->'metadata' <> v_meta then
      raise exception 'R2M FAIL meta: resource_detail no devuelve metadata de %', v_type.type_key;
    end if;
    select count(*) into v_expected_caps from public.resource_type_capabilities tc
     where tc.type_key = v_type.type_key;
    if jsonb_array_length(v_detail->'capabilities') <> v_expected_caps then
      raise exception 'R2M FAIL meta: resource_detail devuelve % capabilities para % (esperadas %)',
        jsonb_array_length(v_detail->'capabilities'), v_type.type_key, v_expected_caps;
    end if;
    -- todo tipo del catálogo tiene al menos una capability
    if v_expected_caps < 1 then
      raise exception 'R2M FAIL meta: el tipo % no tiene capabilities en el catálogo', v_type.type_key;
    end if;
  end loop;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose], array[u_jose]);

  raise notice 'R.2M RESOURCE METADATA: PASS (un recurso por tipo, metadata + capabilities en resource_detail)';
end; $$;

revoke all on function public._smoke_r2m_resource_metadata() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 16. Smoke 3 — _smoke_r2m_resource_reuse
-- ────────────────────────────────────────────────────────────────────────────
-- Casa Valle es UN solo resource: aparece para Familia Mizrahi, José y el
-- Trust Familiar vía rights distintos; capabilities no se duplican.
create or replace function public._smoke_r2m_resource_reuse()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_abuelo uuid; a_abuelo uuid;
  u_jose uuid; a_jose uuid;
  v_familia uuid; v_trust uuid; v_casa uuid;
  v_result jsonb;
  v_caps jsonb;
begin
  select auth_id, actor_id into u_abuelo, a_abuelo from public._r2_make_person('Abuelo R2M', '+5210000043');
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2M-reuse', '+5210000044');

  -- Setup: Familia Mizrahi (Abuelo admin, José miembro) + Trust Familiar (Abuelo admin)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_familia := (public.create_context('Familia Mizrahi R2M-reuse', 'collective', 'family'))->>'context_actor_id';
  v_trust := (public.create_context('Trust Familiar R2M', 'legal_entity', 'trust'))->>'context_actor_id';
  perform public.invite_member(v_familia::uuid, a_jose);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.accept_invitation(v_familia::uuid);

  -- ═══ 1. Abuelo crea Casa Valle (recurso personal, auto-OWN) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_casa := (public.create_resource(a_abuelo, 'house', 'Casa Valle R2M-reuse'))->>'resource_id';

  -- ═══ 2. Rights distintos sobre el MISMO resource ═══
  perform public.grant_right(v_casa::uuid, v_familia::uuid, 'GOVERN');
  perform public.grant_right(v_casa::uuid, v_familia::uuid, 'MANAGE');
  perform public.grant_right(v_casa::uuid, a_jose, 'USE');
  perform public.grant_right(v_casa::uuid, v_trust::uuid, 'BENEFICIARY');

  -- ═══ 3. Casa Valle sigue siendo UN único resource ═══
  if (select count(*) from public.resources where display_name = 'Casa Valle R2M-reuse') <> 1 then
    raise exception 'R2M FAIL reuse: Casa Valle se duplicó';
  end if;

  -- ═══ 4. Aparece en la Familia (José la ve por su USE) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.list_context_resources(v_familia::uuid);
  if not exists (
    select 1 from jsonb_array_elements(v_result) e where (e->>'resource_id')::uuid = v_casa::uuid
  ) then
    raise exception 'R2M FAIL reuse: Casa Valle no aparece en la Familia Mizrahi';
  end if;

  -- ═══ 5. Aparece en el Trust (mismo resource_id, no copia) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_result := public.list_context_resources(v_trust::uuid);
  if not exists (
    select 1 from jsonb_array_elements(v_result) e where (e->>'resource_id')::uuid = v_casa::uuid
  ) then
    raise exception 'R2M FAIL reuse: Casa Valle no aparece en el Trust Familiar';
  end if;

  -- ═══ 6. resource_detail muestra los holders distintos sobre el mismo resource ═══
  v_result := public.resource_detail(v_casa::uuid);
  if not exists (
    select 1 from jsonb_array_elements(v_result->'rights') rt
    where (rt->>'holder_actor_id')::uuid = a_abuelo and rt->>'right_kind' = 'OWN'
  ) then
    raise exception 'R2M FAIL reuse: falta el OWN del Abuelo';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_result->'rights') rt
    where (rt->>'holder_actor_id')::uuid = a_jose and rt->>'right_kind' = 'USE'
  ) then
    raise exception 'R2M FAIL reuse: falta el USE de José';
  end if;
  if (select count(*) from jsonb_array_elements(v_result->'rights') rt
      where (rt->>'holder_actor_id')::uuid = v_familia::uuid) <> 2 then
    raise exception 'R2M FAIL reuse: la Familia no tiene GOVERN+MANAGE';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_result->'rights') rt
    where (rt->>'holder_actor_id')::uuid = v_trust::uuid and rt->>'right_kind' = 'BENEFICIARY'
  ) then
    raise exception 'R2M FAIL reuse: falta el BENEFICIARY del Trust';
  end if;

  -- ═══ 7. Capabilities no se duplican (5 de house, sin repetidos) ═══
  v_caps := (public.resource_capabilities(v_casa::uuid))->'capabilities';
  if jsonb_array_length(v_caps) <>
     (select count(distinct e.value) from jsonb_array_elements_text(v_caps) e) then
    raise exception 'R2M FAIL reuse: capabilities duplicadas';
  end if;
  if jsonb_array_length(v_caps) <>
     (select count(*) from public.resource_type_capabilities where type_key = 'house') then
    raise exception 'R2M FAIL reuse: capabilities de house incompletas';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.resource_reservations where resource_id = v_casa::uuid;
  delete from public.resource_rights where resource_id = v_casa::uuid;
  delete from public.resources where id = v_casa::uuid;
  perform public._r2_cleanup_context(v_trust::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(v_familia::uuid, array[a_abuelo, a_jose], array[u_abuelo, u_jose]);

  raise notice 'R.2M RESOURCE REUSE: PASS (un solo resource, rights distintos, capabilities sin duplicar)';
end; $$;

revoke all on function public._smoke_r2m_resource_reuse() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 17. Wrappers para CI (descubre funciones _smoke_mvp2_%)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_r2m_resource_capabilities()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._smoke_r2m_resource_capabilities();
end; $$;

revoke all on function public._smoke_mvp2_r2m_resource_capabilities() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2m_resource_capabilities() is
  'Wrapper CI del smoke R.2M capabilities (_smoke_r2m_resource_capabilities).';

create or replace function public._smoke_mvp2_r2m_resource_metadata()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._smoke_r2m_resource_metadata();
end; $$;

revoke all on function public._smoke_mvp2_r2m_resource_metadata() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2m_resource_metadata() is
  'Wrapper CI del smoke R.2M metadata (_smoke_r2m_resource_metadata).';

create or replace function public._smoke_mvp2_r2m_resource_reuse()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._smoke_r2m_resource_reuse();
end; $$;

revoke all on function public._smoke_mvp2_r2m_resource_reuse() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2m_resource_reuse() is
  'Wrapper CI del smoke R.2M reuse (_smoke_r2m_resource_reuse).';

-- ────────────────────────────────────────────────────────────────────────────
-- 18. Verificación inline del DoD R.2M
-- ────────────────────────────────────────────────────────────────────────────
do $$
begin
  -- 1. Existe catálogo de tipos (12 legacy + membership_asset + security)
  if (select count(*) from public.resource_type_catalog) < 14 then
    raise exception 'R2M DoD 1: catálogo de tipos incompleto';
  end if;
  -- 2. Existe catálogo de capabilities
  if (select count(*) from public.resource_capabilities_catalog) < 14 then
    raise exception 'R2M DoD 2: catálogo de capabilities incompleto';
  end if;
  -- 3. Existe mapeo tipo→capability y ningún tipo queda sin capabilities
  if exists (
    select 1 from public.resource_type_catalog t
    where not exists (select 1 from public.resource_type_capabilities tc where tc.type_key = t.type_key)
  ) then
    raise exception 'R2M DoD 3: hay tipos sin capabilities';
  end if;
  -- 4-5. resource_can / resource_capabilities / resource_type_catalog existen como RPCs
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('resource_can', 'resource_capabilities', 'resource_type_catalog')) < 3 then
    raise exception 'R2M DoD 4/5: faltan RPCs de capabilities';
  end if;
  -- 6-7. No se crean tablas por tipo y el schema MVP no se rompe: el CHECK
  --      hardcodeado fue reemplazado por FK al catálogo
  if exists (
    select 1 from pg_constraint
    where conrelid = 'public.resources'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%resource_type%'
  ) then
    raise exception 'R2M DoD 7: el CHECK hardcodeado de resource_type sigue vivo';
  end if;
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.resources'::regclass and conname = 'resources_resource_type_fk'
  ) then
    raise exception 'R2M DoD 7: falta el FK resources.resource_type → resource_type_catalog';
  end if;

  raise notice 'R.2M DoD: catálogos + mapeo + RPCs + FK en su lugar — resources es una primitiva extensible';
end $$;
