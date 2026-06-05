-- ============================================================================
-- R.5A.B.2 — CAPABILITIES expansion + subtype defaults + per-instance overrides
-- ============================================================================
-- Additive: expande resource_capabilities_catalog con 27 keys nuevas (deja las
-- 15 vivas intactas), crea matriz subtype->capability (defaults) y tabla de
-- overrides per-resource. Expone 2 RPCs nuevos:
--   effective_resource_capabilities(p_resource_id) -> jsonb
--   set_resource_capability_override(p_resource_id, p_capability_key, p_enabled, p_reason?)
--
-- CRITICO: resource_can() y resource_type_capabilities NO se tocan. iOS sigue
-- funcionando. La nueva superficie es paralela; B.6 (descriptor) la consumira,
-- y F.1 hara el switch.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Expand resource_capabilities_catalog (27 nuevas keys)
-- ----------------------------------------------------------------------------
insert into public.resource_capabilities_catalog (capability_key, display_name, description) values
  ('ownable',            'Apropiable',             'Puede tener owners formales (rights OWN)'),
  ('usable',             'Usable',                 'Puede usarse sin reserva formal (right USE)'),
  ('payable',            'Pagable',                'Puede recibir pagos / cargos monetarios'),
  ('chargeable',         'Cobrable',               'Puede emitir cargos / cobros'),
  ('settleable',         'Liquidable',             'Puede liquidarse en settlement batches'),
  ('splittable',         'Divisible',              'Sus montos pueden dividirse entre actores'),
  ('approvable',         'Aprobable',              'Sus cambios pueden someterse a aprobacion explicita'),
  ('assignable',         'Asignable',              'Puede asignarse a un actor (custodio, holder)'),
  ('custodiable',        'Custodiable',            'Puede tener custodio asignado'),
  ('condition_trackable','Condicion rastreable',   'Su condicion fisica/estado puede registrarse'),
  ('location_bound',     'Ligado a ubicacion',     'Tiene ubicacion fisica relevante'),
  ('schedulable',        'Calendarizable',         'Puede agendarse en el tiempo'),
  ('recurring',          'Recurrente',             'Se repite en patron temporal'),
  ('closeable',          'Cerrable',               'Puede cerrarse / finalizarse'),
  ('rule_bound',         'Sujeto a reglas',        'Su comportamiento se ve afectado por rules'),
  ('votable',            'Votable',                'Puede someterse a votacion'),
  ('signable',           'Firmable',               'Puede firmarse digitalmente'),
  ('versionable',        'Versionable',            'Tiene versiones rastreables'),
  ('disputable',         'Disputable',             'Puede disputarse / impugnarse'),
  ('notifiable',         'Notificable',            'Emite notificaciones por su lifecycle'),
  ('income_generating',  'Genera ingreso',         'Genera flujo de ingreso (renta, dividendos)'),
  ('leasable',           'Arrendable',             'Puede arrendarse a terceros (alias moderno de rentable)'),
  ('insurable',          'Asegurable',             'Puede tener seguro asociado'),
  ('taxable',            'Sujeto a impuestos',     'Genera obligaciones fiscales'),
  ('inventory_tracked',  'Inventariable',          'Forma parte de un inventario stock-tracked'),
  ('quantity_tracked',   'Cantidad rastreable',    'Tiene cantidad numerica rastreada'),
  ('access_controlled',  'Acceso controlado',      'Tiene control de acceso fisico o digital')
on conflict (capability_key) do nothing;

-- ----------------------------------------------------------------------------
-- 2. resource_subtype_capabilities (defaults por subtype)
-- ----------------------------------------------------------------------------
create table public.resource_subtype_capabilities (
  subtype_key text not null references public.resource_subtypes(subtype_key) on update cascade on delete cascade,
  capability_key text not null references public.resource_capabilities_catalog(capability_key) on update cascade on delete cascade,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  primary key (subtype_key, capability_key)
);

comment on table public.resource_subtype_capabilities is
  'R.5A.B.2: defaults capability por subtype. effective = defaults UNION overrides_enabled MINUS overrides_disabled.';

create index idx_subtype_caps_capability on public.resource_subtype_capabilities(capability_key);

alter table public.resource_subtype_capabilities enable row level security;
create policy "resource_subtype_capabilities_read_all"
  on public.resource_subtype_capabilities for select
  to authenticated using (true);
grant select on public.resource_subtype_capabilities to authenticated;

-- ----------------------------------------------------------------------------
-- 3. resource_capability_overrides (per-instance enable/disable)
-- ----------------------------------------------------------------------------
create table public.resource_capability_overrides (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references public.resources(id) on delete cascade,
  capability_key text not null references public.resource_capabilities_catalog(capability_key) on update cascade on delete restrict,
  enabled boolean not null,
  reason text,
  created_by_actor_id uuid references public.actors(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (resource_id, capability_key)
);

comment on table public.resource_capability_overrides is
  'R.5A.B.2: overrides per-resource. enabled=true agrega capability sobre defaults; enabled=false la quita aunque este en defaults.';

create index idx_capability_overrides_resource on public.resource_capability_overrides(resource_id);

create trigger trg_capability_overrides_touch
  before update on public.resource_capability_overrides
  for each row execute function public.touch_updated_at();

alter table public.resource_capability_overrides enable row level security;
-- Read: miembros del context del recurso pueden ver overrides
create policy "resource_capability_overrides_read"
  on public.resource_capability_overrides for select
  to authenticated
  using (
    exists (
      select 1 from public.resources r
      where r.id = resource_id
        and public.is_context_member(r.canonical_owner_actor_id)
    )
  );
grant select on public.resource_capability_overrides to authenticated;
-- writes solo via RPC SECURITY DEFINER, no GRANT INSERT/UPDATE/DELETE a authenticated

-- ----------------------------------------------------------------------------
-- 4. Seed: defaults por subtype (founder-canon strict + class-base derived)
--    Founder canon (spec sec 6): primary_residence, vacation_home, warehouse,
--    money_pool, recurring_event, contract, iou. Resto: derivado por clase.
-- ----------------------------------------------------------------------------
insert into public.resource_subtype_capabilities (subtype_key, capability_key) values
  -- real_estate: base = ownable, maintainable, documentable, payable, auditable, location_bound, insurable, taxable
  ('primary_residence','ownable'),('primary_residence','maintainable'),('primary_residence','documentable'),
  ('primary_residence','payable'),('primary_residence','auditable'),('primary_residence','location_bound'),
  ('primary_residence','insurable'),('primary_residence','taxable'),
  ('vacation_home','ownable'),('vacation_home','maintainable'),('vacation_home','documentable'),
  ('vacation_home','payable'),('vacation_home','auditable'),('vacation_home','location_bound'),
  ('vacation_home','insurable'),('vacation_home','taxable'),('vacation_home','reservable'),
  ('vacation_home','chargeable'),('vacation_home','shareable'),
  ('apartment','ownable'),('apartment','maintainable'),('apartment','documentable'),('apartment','payable'),
  ('apartment','auditable'),('apartment','location_bound'),('apartment','insurable'),('apartment','taxable'),
  ('apartment','reservable'),
  ('office','ownable'),('office','maintainable'),('office','documentable'),('office','payable'),
  ('office','auditable'),('office','location_bound'),('office','insurable'),('office','taxable'),
  ('office','reservable'),('office','leasable'),('office','access_controlled'),
  ('warehouse','ownable'),('warehouse','maintainable'),('warehouse','documentable'),('warehouse','payable'),
  ('warehouse','auditable'),('warehouse','location_bound'),('warehouse','insurable'),('warehouse','taxable'),
  ('warehouse','leasable'),('warehouse','income_generating'),
  ('land','ownable'),('land','documentable'),('land','payable'),('land','auditable'),
  ('land','location_bound'),('land','insurable'),('land','taxable'),('land','transferable'),
  ('rental_property','ownable'),('rental_property','maintainable'),('rental_property','documentable'),
  ('rental_property','payable'),('rental_property','auditable'),('rental_property','location_bound'),
  ('rental_property','insurable'),('rental_property','taxable'),('rental_property','leasable'),
  ('rental_property','income_generating'),('rental_property','chargeable'),
  ('industrial_property','ownable'),('industrial_property','maintainable'),('industrial_property','documentable'),
  ('industrial_property','payable'),('industrial_property','auditable'),('industrial_property','location_bound'),
  ('industrial_property','insurable'),('industrial_property','taxable'),('industrial_property','leasable'),
  ('industrial_property','income_generating'),('industrial_property','access_controlled'),

  -- financial: base = payable, chargeable, settleable, auditable, documentable, ownership_trackable
  ('money_pool','payable'),('money_pool','chargeable'),('money_pool','settleable'),('money_pool','splittable'),
  ('money_pool','auditable'),('money_pool','governable'),('money_pool','documentable'),
  ('bank_account','payable'),('bank_account','chargeable'),('bank_account','settleable'),
  ('bank_account','auditable'),('bank_account','documentable'),('bank_account','ownership_trackable'),
  ('investment_account','payable'),('investment_account','chargeable'),('investment_account','settleable'),
  ('investment_account','auditable'),('investment_account','documentable'),('investment_account','ownership_trackable'),
  ('investment_account','transferable'),('investment_account','beneficiary_supported'),
  ('crypto_wallet','payable'),('crypto_wallet','chargeable'),('crypto_wallet','settleable'),
  ('crypto_wallet','auditable'),('crypto_wallet','documentable'),('crypto_wallet','ownership_trackable'),
  ('crypto_wallet','transferable'),('crypto_wallet','custodiable'),('crypto_wallet','access_controlled'),
  ('trust_fund','payable'),('trust_fund','chargeable'),('trust_fund','settleable'),('trust_fund','auditable'),
  ('trust_fund','documentable'),('trust_fund','ownership_trackable'),('trust_fund','beneficiary_supported'),
  ('trust_fund','governable'),

  -- vehicle: base = ownable, maintainable, documentable, auditable, transferable, condition_trackable, custodiable
  ('car','ownable'),('car','maintainable'),('car','documentable'),('car','auditable'),('car','transferable'),
  ('car','condition_trackable'),('car','custodiable'),('car','reservable'),('car','insurable'),
  ('truck','ownable'),('truck','maintainable'),('truck','documentable'),('truck','auditable'),('truck','transferable'),
  ('truck','condition_trackable'),('truck','custodiable'),('truck','reservable'),('truck','insurable'),('truck','leasable'),
  ('machine','ownable'),('machine','maintainable'),('machine','documentable'),('machine','auditable'),
  ('machine','transferable'),('machine','condition_trackable'),('machine','custodiable'),('machine','insurable'),
  ('tool','ownable'),('tool','maintainable'),('tool','documentable'),('tool','auditable'),('tool','transferable'),
  ('tool','condition_trackable'),('tool','custodiable'),('tool','reservable'),

  -- document: base = documentable, versionable, auditable, shareable
  ('contract','documentable'),('contract','versionable'),('contract','approvable'),('contract','signable'),
  ('contract','auditable'),('contract','shareable'),
  ('receipt','documentable'),('receipt','auditable'),('receipt','shareable'),
  ('statement','documentable'),('statement','versionable'),('statement','auditable'),('statement','shareable'),
  ('certificate','documentable'),('certificate','expirable'),('certificate','auditable'),('certificate','shareable'),
  ('policy','documentable'),('policy','versionable'),('policy','expirable'),('policy','auditable'),
  ('policy','shareable'),('policy','insurable'),

  -- event: base = schedulable, auditable, closeable
  ('recurring_event','schedulable'),('recurring_event','recurring'),('recurring_event','closeable'),
  ('recurring_event','payable'),('recurring_event','splittable'),('recurring_event','reservable'),
  ('recurring_event','rule_bound'),('recurring_event','votable'),('recurring_event','auditable'),
  ('recurring_event','notifiable'),
  ('meeting','schedulable'),('meeting','closeable'),('meeting','auditable'),('meeting','reservable'),('meeting','notifiable'),
  ('dinner','schedulable'),('dinner','closeable'),('dinner','payable'),('dinner','splittable'),('dinner','auditable'),
  ('community_event','schedulable'),('community_event','closeable'),('community_event','reservable'),
  ('community_event','payable'),('community_event','auditable'),

  -- obligation: base = payable, settleable, auditable, expirable
  ('iou','payable'),('iou','settleable'),('iou','disputable'),('iou','expirable'),('iou','auditable'),
  ('fine','payable'),('fine','settleable'),('fine','disputable'),('fine','expirable'),('fine','auditable'),('fine','notifiable'),
  ('loan','payable'),('loan','settleable'),('loan','expirable'),('loan','auditable'),('loan','documentable'),('loan','disputable'),
  ('contribution','payable'),('contribution','settleable'),('contribution','auditable'),('contribution','expirable'),
  ('dues','payable'),('dues','settleable'),('dues','recurring'),('dues','expirable'),('dues','auditable'),

  -- right
  ('generic_right','assignable'),('generic_right','transferable'),('generic_right','auditable'),('generic_right','expirable'),

  -- inventory
  ('inventory_item','inventory_tracked'),('inventory_item','quantity_tracked'),('inventory_item','auditable'),
  ('inventory_item','documentable'),('inventory_item','transferable'),

  -- project
  ('internal_project','schedulable'),('internal_project','governable'),('internal_project','auditable'),
  ('internal_project','documentable'),('internal_project','closeable'),

  -- trip
  ('group_trip','schedulable'),('group_trip','payable'),('group_trip','splittable'),('group_trip','auditable'),
  ('group_trip','documentable'),('group_trip','closeable'),('group_trip','reservable'),

  -- space
  ('generic_space','reservable'),('generic_space','location_bound'),('generic_space','schedulable'),
  ('generic_space','auditable'),('generic_space','access_controlled'),

  -- digital_asset
  ('generic_digital_asset','ownable'),('generic_digital_asset','transferable'),('generic_digital_asset','auditable'),
  ('generic_digital_asset','documentable'),('generic_digital_asset','custodiable'),

  -- service
  ('generic_service','documentable'),('generic_service','payable'),('generic_service','schedulable'),
  ('generic_service','auditable'),('generic_service','recurring'),

  -- membership
  ('generic_membership','assignable'),('generic_membership','expirable'),('generic_membership','auditable'),
  ('generic_membership','documentable'),

  -- equipment (catch-all)
  ('generic_equipment','ownable'),('generic_equipment','maintainable'),('generic_equipment','documentable'),
  ('generic_equipment','reservable'),('generic_equipment','auditable'),('generic_equipment','condition_trackable'),

  -- agreement
  ('generic_agreement','documentable'),('generic_agreement','signable'),('generic_agreement','versionable'),
  ('generic_agreement','approvable'),('generic_agreement','auditable'),('generic_agreement','shareable'),

  -- generic (fallback minimo)
  ('generic_resource','auditable')
on conflict (subtype_key, capability_key) do nothing;

-- ----------------------------------------------------------------------------
-- 5. RPC: effective_resource_capabilities
--    Computa effective = defaults UNION enabled_overrides MINUS disabled_overrides
-- ----------------------------------------------------------------------------
create or replace function public.effective_resource_capabilities(p_resource_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_actor uuid;
  v_class text;
  v_subtype text;
  v_owner uuid;
  v_defaults text[];
  v_overrides jsonb;
  v_disabled text[];
  v_effective text[];
begin
  if auth.uid() is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  v_actor := public.current_actor_id();
  if v_actor is null then
    raise exception 'missing person actor' using errcode = '42501';
  end if;

  select r.resource_class_key, r.resource_subtype_key, r.canonical_owner_actor_id
    into v_class, v_subtype, v_owner
    from public.resources r where r.id = p_resource_id;
  if v_owner is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;

  -- Visibilidad: miembro del context owner (o caller es el owner si owner=person actor)
  if not (v_actor = v_owner or public.is_context_member(v_owner)) then
    raise exception 'not a member of resource context' using errcode = '42501';
  end if;

  if v_subtype is null then v_subtype := 'generic_resource'; end if;

  select coalesce(array_agg(capability_key order by capability_key), array[]::text[])
    into v_defaults
    from public.resource_subtype_capabilities
    where subtype_key = v_subtype;

  select coalesce(array_agg(capability_key order by capability_key) filter (where not enabled), array[]::text[])
    into v_disabled
    from public.resource_capability_overrides
    where resource_id = p_resource_id;

  with merged as (
    select unnest(v_defaults) as cap
    union
    select capability_key
      from public.resource_capability_overrides
      where resource_id = p_resource_id and enabled
  )
  select coalesce(array_agg(distinct cap order by cap), array[]::text[])
    into v_effective
    from merged
    where cap <> all(v_disabled);

  select coalesce(jsonb_agg(jsonb_build_object(
           'capability_key', capability_key,
           'enabled', enabled,
           'reason', reason,
           'updated_at', updated_at
         ) order by capability_key), '[]'::jsonb)
    into v_overrides
    from public.resource_capability_overrides
    where resource_id = p_resource_id;

  return jsonb_build_object(
    'resource_id', p_resource_id,
    'class_key', v_class,
    'subtype_key', v_subtype,
    'defaults', to_jsonb(v_defaults),
    'overrides', v_overrides,
    'effective', to_jsonb(v_effective)
  );
end;
$$;

comment on function public.effective_resource_capabilities(uuid) is
  'R.5A.B.2: effective capabilities = subtype defaults UNION enabled_overrides MINUS disabled_overrides. Visibilidad por membership.';

revoke all on function public.effective_resource_capabilities(uuid) from public, anon;
grant execute on function public.effective_resource_capabilities(uuid) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 6. RPC: set_resource_capability_override
-- ----------------------------------------------------------------------------
create or replace function public.set_resource_capability_override(
  p_resource_id uuid,
  p_capability_key text,
  p_enabled boolean,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_actor uuid;
  v_owner uuid;
begin
  if auth.uid() is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  v_actor := public.current_actor_id();
  if v_actor is null then
    raise exception 'missing person actor' using errcode = '42501';
  end if;

  if not exists (select 1 from public.resource_capabilities_catalog where capability_key = p_capability_key) then
    raise exception 'unknown capability %', p_capability_key using errcode = '22023';
  end if;

  select canonical_owner_actor_id into v_owner from public.resources where id = p_resource_id;
  if v_owner is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;

  if not public.has_actor_authority(v_actor, v_owner, 'resources.manage') then
    raise exception 'missing permission resources.manage' using errcode = '42501';
  end if;

  insert into public.resource_capability_overrides (resource_id, capability_key, enabled, reason, created_by_actor_id)
    values (p_resource_id, p_capability_key, p_enabled, p_reason, v_actor)
    on conflict (resource_id, capability_key) do update
      set enabled = excluded.enabled,
          reason = excluded.reason,
          updated_at = now();

  return public.effective_resource_capabilities(p_resource_id);
end;
$$;

comment on function public.set_resource_capability_override(uuid, text, boolean, text) is
  'R.5A.B.2: upsert per-resource capability override. Requiere resources.manage. Devuelve effective capabilities post-cambio.';

revoke all on function public.set_resource_capability_override(uuid, text, boolean, text) from public, anon;
grant execute on function public.set_resource_capability_override(uuid, text, boolean, text) to authenticated, service_role;
