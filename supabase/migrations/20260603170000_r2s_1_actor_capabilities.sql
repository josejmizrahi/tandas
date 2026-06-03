-- ============================================================================
-- R.2S.2 — ACTOR CAPABILITIES
-- ============================================================================
-- Espejo de R.2M (resource capabilities) para la primitiva Actor. No todo
-- actor se comporta igual: una person tiene dinero y obligaciones; una company
-- tiene shareholders; un trust tiene beneficiaries y trustees; una community
-- tiene members y decisiones. Pero NO se crea una tabla por tipo de actor —
-- el comportamiento se describe con un catálogo de capabilities.
--
--   actor_capabilities_catalog → capacidades (can_hold_money, can_have_…)
--   actor_type_capabilities    → mapeo actor_subtype → capability
--
-- Doctrina (R.2S regla universal): el frontend NO decide comportamiento por
-- actor_subtype. Consume actor_can() / actor_capabilities().
--
-- Override explícito: actors.metadata.capability_overrides permite habilitar o
-- deshabilitar una capability puntual sin tocar el catálogo (ej. una person
-- que SÍ puede tener shareholders por configuración explícita del founder).
--
-- RPCs nuevos:
--   actor_capabilities_catalog()       → catálogo subtype → capabilities
--   actor_capabilities(actor_id)       → kind + subtype + capabilities[]
--   actor_can(actor_id, capability)    → boolean (respeta overrides)
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. actor_capabilities_catalog
-- ────────────────────────────────────────────────────────────────────────────
create table public.actor_capabilities_catalog (
  capability_key text primary key,
  display_name text not null,
  description text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);

comment on table public.actor_capabilities_catalog is
  'R.2S.2: capacidades que un tipo de actor puede tener (can_hold_money, can_have_members, …).';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. actor_type_capabilities (mapeo actor_subtype → capability)
-- ────────────────────────────────────────────────────────────────────────────
-- La key es actor_subtype: los subtypes válidos ya viven en el CHECK de
-- actors.actor_subtype (person, friend_group, family, company, trust, trip,
-- community, project, system, other). No se crea un actor_type_catalog nuevo:
-- el whitelist de subtypes es la fuente.
create table public.actor_type_capabilities (
  actor_subtype text not null,
  capability_key text not null references public.actor_capabilities_catalog(capability_key) on update cascade on delete cascade,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  primary key (actor_subtype, capability_key)
);

comment on table public.actor_type_capabilities is
  'R.2S.2: qué capabilities tiene cada actor_subtype. El backend responde actor_can() desde aquí, sin IFs por subtype.';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Seed: capabilities (12)
-- ────────────────────────────────────────────────────────────────────────────
insert into public.actor_capabilities_catalog (capability_key, display_name, description) values
  ('can_have_members',         'Puede tener miembros',        'Otros actores participan en él vía membership'),
  ('can_hold_assets',          'Puede tener activos',         'Puede ser holder de rights OWN sobre recursos'),
  ('can_hold_money',           'Puede tener dinero',          'Participa en transacciones y settlement'),
  ('can_issue_decisions',      'Puede emitir decisiones',     'Puede abrir decisiones y votar'),
  ('can_receive_contributions','Puede recibir aportaciones',  'Recibe contribuciones de sus miembros'),
  ('can_have_beneficiaries',   'Puede tener beneficiarios',   'Puede designar actores como beneficiarios'),
  ('can_have_shareholders',    'Puede tener accionistas',     'Su propiedad se reparte en acciones (shares)'),
  ('can_have_trustees',        'Puede tener fideicomisarios', 'Administrado por trustees en nombre de beneficiarios'),
  ('can_receive_obligations',  'Puede recibir obligaciones',  'Puede ser deudor de una obligación'),
  ('can_issue_obligations',    'Puede emitir obligaciones',   'Puede ser acreedor / originar obligaciones'),
  ('can_govern_resources',     'Puede gobernar recursos',     'Ejerce GOVERN/MANAGE sobre recursos del contexto'),
  ('can_own_resources',        'Puede poseer recursos',       'Puede ser dueño (OWN) de recursos');

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Seed: mapeo actor_subtype → capabilities
-- ────────────────────────────────────────────────────────────────────────────
insert into public.actor_type_capabilities (actor_subtype, capability_key)
select m.actor_subtype, m.capability_key
from (values
  -- person: tiene activos, dinero y obligaciones; NO shareholders/beneficiaries
  ('person',       'can_hold_assets'),
  ('person',       'can_hold_money'),
  ('person',       'can_receive_obligations'),
  ('person',       'can_issue_obligations'),
  ('person',       'can_own_resources'),

  -- friend_group: miembros, decisiones, aportaciones, dinero compartido
  ('friend_group', 'can_have_members'),
  ('friend_group', 'can_issue_decisions'),
  ('friend_group', 'can_receive_contributions'),
  ('friend_group', 'can_hold_money'),
  ('friend_group', 'can_govern_resources'),
  ('friend_group', 'can_issue_obligations'),
  ('friend_group', 'can_receive_obligations'),

  -- family: miembros, activos, dinero, beneficiarios, gobierna recursos
  ('family',       'can_have_members'),
  ('family',       'can_issue_decisions'),
  ('family',       'can_hold_assets'),
  ('family',       'can_hold_money'),
  ('family',       'can_own_resources'),
  ('family',       'can_govern_resources'),
  ('family',       'can_have_beneficiaries'),
  ('family',       'can_receive_contributions'),
  ('family',       'can_issue_obligations'),
  ('family',       'can_receive_obligations'),

  -- company: shareholders, activos, dinero, decisiones
  ('company',      'can_have_members'),
  ('company',      'can_hold_assets'),
  ('company',      'can_hold_money'),
  ('company',      'can_issue_decisions'),
  ('company',      'can_have_shareholders'),
  ('company',      'can_own_resources'),
  ('company',      'can_govern_resources'),
  ('company',      'can_receive_contributions'),
  ('company',      'can_issue_obligations'),
  ('company',      'can_receive_obligations'),

  -- trust: beneficiarios + trustees + activos
  ('trust',        'can_hold_assets'),
  ('trust',        'can_have_beneficiaries'),
  ('trust',        'can_have_trustees'),
  ('trust',        'can_own_resources'),
  ('trust',        'can_govern_resources'),
  ('trust',        'can_issue_decisions'),

  -- trip: miembros, dinero, obligaciones, aportaciones
  ('trip',         'can_have_members'),
  ('trip',         'can_hold_money'),
  ('trip',         'can_issue_obligations'),
  ('trip',         'can_receive_obligations'),
  ('trip',         'can_receive_contributions'),
  ('trip',         'can_govern_resources'),

  -- community: miembros, decisiones, aportaciones
  ('community',    'can_have_members'),
  ('community',    'can_issue_decisions'),
  ('community',    'can_receive_contributions'),
  ('community',    'can_govern_resources'),
  ('community',    'can_hold_money'),
  ('community',    'can_issue_obligations'),
  ('community',    'can_receive_obligations'),

  -- project: miembros, decisiones, dinero, obligaciones
  ('project',      'can_have_members'),
  ('project',      'can_issue_decisions'),
  ('project',      'can_govern_resources'),
  ('project',      'can_hold_money'),
  ('project',      'can_receive_contributions'),
  ('project',      'can_issue_obligations'),
  ('project',      'can_receive_obligations'),

  -- system: el actor del rule engine — origina obligaciones y decisiones
  ('system',       'can_issue_obligations'),
  ('system',       'can_issue_decisions'),

  -- other: mínimo razonable
  ('other',        'can_hold_assets'),
  ('other',        'can_own_resources')
) as m(actor_subtype, capability_key)
join public.actor_capabilities_catalog c on c.capability_key = m.capability_key;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. RLS: catálogos globales, lectura para authenticated
-- ────────────────────────────────────────────────────────────────────────────
alter table public.actor_capabilities_catalog enable row level security;
alter table public.actor_type_capabilities enable row level security;

create policy actor_capabilities_catalog_select on public.actor_capabilities_catalog
  for select to authenticated using (true);

create policy actor_type_capabilities_select on public.actor_type_capabilities
  for select to authenticated using (true);

revoke all on public.actor_capabilities_catalog, public.actor_type_capabilities from anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. actor_can(actor_id, capability)
-- ────────────────────────────────────────────────────────────────────────────
-- Respeta overrides explícitos en actors.metadata.capability_overrides:
--   {"capability_overrides": {"can_have_shareholders": true}}  → habilita
--   {"capability_overrides": {"can_hold_money": false}}        → deshabilita
-- Si no hay override, decide el catálogo por actor_subtype.
create or replace function public.actor_can(p_actor_id uuid, p_capability text)
returns boolean
language plpgsql stable security definer set search_path = public
as $$
declare
  v_override text;
  v_subtype text;
begin
  select a.actor_subtype, a.metadata->'capability_overrides'->>p_capability
    into v_subtype, v_override
    from public.actors a where a.id = p_actor_id;

  if v_subtype is null then
    return false; -- actor inexistente
  end if;
  if v_override = 'true' then return true; end if;
  if v_override = 'false' then return false; end if;

  return exists (
    select 1 from public.actor_type_capabilities tc
     where tc.actor_subtype = v_subtype
       and tc.capability_key = p_capability
  );
end; $$;

revoke all on function public.actor_can(uuid, text) from public, anon;
grant execute on function public.actor_can(uuid, text) to authenticated, service_role;

comment on function public.actor_can(uuid, text) is
  'R.2S.2: ¿este actor tiene esta capability? Catálogo por subtype + overrides en metadata. La lógica por subtype no vive en IFs.';

-- ────────────────────────────────────────────────────────────────────────────
-- 7. actor_capabilities(actor_id): kind + subtype + capabilities[]
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.actor_capabilities(p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_actor public.actors%rowtype;
  v_caps jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_actor from public.actors where id = p_actor_id;
  if v_actor.id is null then raise exception 'actor not found' using errcode = 'P0002'; end if;

  -- capabilities del catálogo (por subtype) menos los deshabilitados por override,
  -- más los habilitados por override explícito.
  select coalesce(jsonb_agg(cap order by cap), '[]'::jsonb) into v_caps
  from (
    select c.capability_key as cap
      from public.actor_capabilities_catalog c
     where public.actor_can(p_actor_id, c.capability_key)
  ) s;

  return jsonb_build_object(
    'actor_id', v_actor.id,
    'actor_kind', v_actor.actor_kind,
    'actor_subtype', v_actor.actor_subtype,
    'capabilities', v_caps);
end; $$;

revoke all on function public.actor_capabilities(uuid) from public, anon;
grant execute on function public.actor_capabilities(uuid) to authenticated, service_role;

comment on function public.actor_capabilities(uuid) is
  'R.2S.2: actor_id + kind + subtype + capabilities[] (catálogo por subtype + overrides). El frontend renderiza por capabilities, no por subtype.';

-- ────────────────────────────────────────────────────────────────────────────
-- 8. actor_capabilities_catalog(): matriz subtype → capabilities para el frontend
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.actor_capabilities_catalog()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'capabilities', coalesce((
      select jsonb_agg(jsonb_build_object(
        'capability_key', c.capability_key,
        'display_name', c.display_name,
        'description', c.description) order by c.capability_key)
      from public.actor_capabilities_catalog c), '[]'::jsonb),
    'subtypes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'actor_subtype', s.actor_subtype,
        'capabilities', s.caps) order by s.actor_subtype)
      from (
        select tc.actor_subtype,
               jsonb_agg(tc.capability_key order by tc.capability_key) as caps
          from public.actor_type_capabilities tc
         group by tc.actor_subtype) s), '[]'::jsonb));
$$;

revoke all on function public.actor_capabilities_catalog() from public, anon;
grant execute on function public.actor_capabilities_catalog() to authenticated, service_role;

comment on function public.actor_capabilities_catalog() is
  'R.2S.2: catálogo de capabilities + matriz subtype→capabilities. El frontend describe el comportamiento de cada actor sin hardcodear subtypes.';

-- ────────────────────────────────────────────────────────────────────────────
-- 9. Smoke — _smoke_r2s_actor_capabilities
-- ────────────────────────────────────────────────────────────────────────────
-- Trust → beneficiaries + trustees, NO shareholders
-- Company → shareholders
-- Person → NO shareholders por default; SÍ con override explícito
create or replace function public._smoke_r2s_actor_capabilities()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  v_company uuid; v_trust uuid; v_community uuid; v_trip uuid;
  v_result jsonb;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2S-actor', '+5210000061');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_company   := (public.create_context('Quimibond R2S', 'legal_entity', 'company'))->>'context_actor_id';
  v_trust     := (public.create_context('Trust Familiar R2S', 'legal_entity', 'trust'))->>'context_actor_id';
  v_community := (public.create_context('Comunidad R2S', 'collective', 'community'))->>'context_actor_id';
  v_trip      := (public.create_context('Viaje R2S', 'collective', 'trip'))->>'context_actor_id';

  -- ═══ 1. Company tiene shareholders ═══
  if not public.actor_can(v_company::uuid, 'can_have_shareholders') then
    raise exception 'R2S.2 FAIL 1: la company debería tener can_have_shareholders';
  end if;

  -- ═══ 2. Trust tiene beneficiaries + trustees, NO shareholders ═══
  if not public.actor_can(v_trust::uuid, 'can_have_beneficiaries') then
    raise exception 'R2S.2 FAIL 2: el trust debería tener can_have_beneficiaries';
  end if;
  if not public.actor_can(v_trust::uuid, 'can_have_trustees') then
    raise exception 'R2S.2 FAIL 2: el trust debería tener can_have_trustees';
  end if;
  if public.actor_can(v_trust::uuid, 'can_have_shareholders') then
    raise exception 'R2S.2 FAIL 2: el trust NO debería tener can_have_shareholders';
  end if;

  -- ═══ 3. Person: NO shareholders por default ═══
  if public.actor_can(a_jose, 'can_have_shareholders') then
    raise exception 'R2S.2 FAIL 3: una person NO debería tener can_have_shareholders por default';
  end if;
  if not public.actor_can(a_jose, 'can_hold_money') then
    raise exception 'R2S.2 FAIL 3: una person debería poder tener dinero';
  end if;
  if not public.actor_can(a_jose, 'can_receive_obligations') then
    raise exception 'R2S.2 FAIL 3: una person debería poder recibir obligaciones';
  end if;

  -- ═══ 4. Override explícito: person CON shareholders habilitados ═══
  update public.actors
     set metadata = metadata || '{"capability_overrides": {"can_have_shareholders": true}}'::jsonb
   where id = a_jose;
  if not public.actor_can(a_jose, 'can_have_shareholders') then
    raise exception 'R2S.2 FAIL 4: el override explícito no habilitó can_have_shareholders en la person';
  end if;
  -- y el override negativo deshabilita
  update public.actors
     set metadata = '{"capability_overrides": {"can_hold_money": false}}'::jsonb
   where id = a_jose;
  if public.actor_can(a_jose, 'can_hold_money') then
    raise exception 'R2S.2 FAIL 4: el override negativo no deshabilitó can_hold_money';
  end if;
  update public.actors set metadata = '{}'::jsonb where id = a_jose;

  -- ═══ 5. Community tiene members + contributions ═══
  if not public.actor_can(v_community::uuid, 'can_have_members') then
    raise exception 'R2S.2 FAIL 5: la community debería tener can_have_members';
  end if;
  if not public.actor_can(v_community::uuid, 'can_receive_contributions') then
    raise exception 'R2S.2 FAIL 5: la community debería recibir aportaciones';
  end if;

  -- ═══ 6. Trip tiene dinero + obligaciones ═══
  if not public.actor_can(v_trip::uuid, 'can_hold_money') then
    raise exception 'R2S.2 FAIL 6: el trip debería poder tener dinero';
  end if;
  if not public.actor_can(v_trip::uuid, 'can_issue_obligations') then
    raise exception 'R2S.2 FAIL 6: el trip debería poder emitir obligaciones';
  end if;

  -- ═══ 7. actor_capabilities() shape ═══
  v_result := public.actor_capabilities(v_trust::uuid);
  if v_result->>'actor_subtype' <> 'trust'
     or not (v_result->'capabilities') ? 'can_have_beneficiaries' then
    raise exception 'R2S.2 FAIL 7: actor_capabilities(trust) shape incorrecto';
  end if;

  -- ═══ 8. actor_capabilities_catalog() trae las 12 capabilities ═══
  v_result := public.actor_capabilities_catalog();
  if jsonb_array_length(v_result->'capabilities') <> 12 then
    raise exception 'R2S.2 FAIL 8: el catálogo no trae las 12 capabilities';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_company::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(v_trust::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(v_community::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(v_trip::uuid, array[a_jose], array[u_jose]);

  raise notice 'R.2S.2 ACTOR CAPABILITIES: PASS (company→shareholders, trust→beneficiaries/trustees, person sin shareholders salvo override)';
end; $$;

revoke all on function public._smoke_r2s_actor_capabilities() from public, anon, authenticated;

-- CI wrapper
create or replace function public._smoke_mvp2_r2s_actor_capabilities()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._smoke_r2s_actor_capabilities();
end; $$;

revoke all on function public._smoke_mvp2_r2s_actor_capabilities() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2s_actor_capabilities() is
  'Wrapper CI del smoke R.2S.2 actor capabilities.';

-- ────────────────────────────────────────────────────────────────────────────
-- 10. Verificación inline del DoD R.2S.2
-- ────────────────────────────────────────────────────────────────────────────
do $$
begin
  if (select count(*) from public.actor_capabilities_catalog) <> 12 then
    raise exception 'R2S.2 DoD: catálogo de capabilities incompleto';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('actor_can', 'actor_capabilities', 'actor_capabilities_catalog')) < 3 then
    raise exception 'R2S.2 DoD: faltan RPCs de actor capabilities';
  end if;
  -- Todo subtype válido tiene al menos una capability
  if exists (
    select 1 from (values ('person'),('friend_group'),('family'),('company'),
                          ('trust'),('trip'),('community'),('project'),('system'),('other')) v(st)
    where not exists (select 1 from public.actor_type_capabilities tc where tc.actor_subtype = v.st)
  ) then
    raise exception 'R2S.2 DoD: hay subtypes sin capabilities';
  end if;
  raise notice 'R.2S.2 DoD: catálogo + mapeo + RPCs en su lugar — actors es una primitiva extensible por capabilities';
end $$;
