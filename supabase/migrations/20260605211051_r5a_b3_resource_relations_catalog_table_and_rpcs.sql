-- ============================================================================
-- R.5A.B.3 — RESOURCE_RELATIONS (additive, parallel a resource_links legacy)
-- ============================================================================
-- Crea catalogo de 15 relation types canonicos (founder spec sec 9) +
-- tabla resource_relations con (parent, child, relation_type) unique +
-- 3 RPCs: list_resource_relations / set_resource_relation / remove_resource_relation.
-- Cero impacto runtime: nada lee de aqui todavia; B.6 (descriptor) lo consumira.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Catalogo de relation types
-- ----------------------------------------------------------------------------
create table public.resource_relation_types (
  relation_type text primary key,
  display_name text not null,
  description text,
  icon text,
  inverse_relation_type text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);

comment on table public.resource_relation_types is
  'R.5A.B.3: catalogo de tipos de relacion entre resources. inverse_relation_type es semantic hint (no enforce auto-creacion).';

insert into public.resource_relation_types (relation_type, display_name, description, icon) values
  ('contains',           'Contiene',                'El recurso padre contiene al hijo (whole/part)',         'cube.transparent'),
  ('uses',               'Usa',                     'El padre usa al hijo en su operacion',                    'arrow.up.right'),
  ('depends_on',         'Depende de',              'El padre depende del hijo para funcionar',                'link'),
  ('documents',          'Documenta',               'El padre documenta al hijo (escritura, contrato, etc.)', 'doc.text'),
  ('secures',            'Garantiza',               'El padre actua como garantia del hijo (hipoteca, etc.)', 'lock.fill'),
  ('generates_income',   'Genera ingreso para',     'El padre genera flujo de ingreso al hijo',                'arrow.up.right.circle'),
  ('creates_obligation', 'Crea obligacion para',    'El padre crea obligacion sobre el hijo',                  'exclamationmark.circle'),
  ('scheduled_for',      'Agendado para',           'El padre esta agendado en el hijo (evento)',              'calendar.badge.clock'),
  ('replaces',           'Reemplaza a',             'El padre reemplaza al hijo (sucesion)',                   'arrow.triangle.2.circlepath'),
  ('derived_from',       'Derivado de',             'El padre se deriva del hijo',                             'arrow.down.right'),
  ('owns',               'Posee',                   'El padre posee al hijo (ownership semantica)',            'crown.fill'),
  ('leases',             'Arrienda',                'El padre arrienda al hijo a terceros',                    'key.fill'),
  ('insures',            'Asegura',                 'El padre cubre al hijo con seguro',                       'shield.fill'),
  ('guarantees',         'Avala',                   'El padre avala al hijo',                                   'checkmark.seal.fill'),
  ('references',         'Referencia',              'El padre referencia al hijo sin dependencia fuerte',      'link.circle')
on conflict (relation_type) do nothing;

alter table public.resource_relation_types enable row level security;
create policy "resource_relation_types_read_all"
  on public.resource_relation_types for select to authenticated using (true);
grant select on public.resource_relation_types to authenticated;

-- ----------------------------------------------------------------------------
-- 2. Tabla resource_relations
-- ----------------------------------------------------------------------------
create table public.resource_relations (
  id uuid primary key default gen_random_uuid(),
  parent_resource_id uuid not null references public.resources(id) on delete cascade,
  child_resource_id uuid not null references public.resources(id) on delete cascade,
  relation_type text not null references public.resource_relation_types(relation_type) on update cascade on delete restrict,
  metadata jsonb not null default '{}',
  created_by_actor_id uuid references public.actors(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint resource_relations_no_self check (parent_resource_id <> child_resource_id),
  unique (parent_resource_id, child_resource_id, relation_type)
);

comment on table public.resource_relations is
  'R.5A.B.3: relaciones dirigidas entre resources (parent->child con relation_type). Self rejected, idempotente.';

create index idx_resource_relations_parent on public.resource_relations(parent_resource_id);
create index idx_resource_relations_child  on public.resource_relations(child_resource_id);
create index idx_resource_relations_type   on public.resource_relations(relation_type);

create trigger trg_resource_relations_touch
  before update on public.resource_relations
  for each row execute function public.touch_updated_at();

alter table public.resource_relations enable row level security;
create policy "resource_relations_read"
  on public.resource_relations for select to authenticated
  using (
    exists (select 1 from public.resources r where r.id = parent_resource_id
              and public.is_context_member(r.canonical_owner_actor_id))
    and
    exists (select 1 from public.resources r where r.id = child_resource_id
              and public.is_context_member(r.canonical_owner_actor_id))
  );
grant select on public.resource_relations to authenticated;
-- writes solo via RPC

-- ----------------------------------------------------------------------------
-- 3. RPC list_resource_relations(p_resource_id) -> {outbound:[], inbound:[]}
-- ----------------------------------------------------------------------------
create or replace function public.list_resource_relations(p_resource_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_actor uuid;
  v_owner uuid;
  v_outbound jsonb;
  v_inbound jsonb;
begin
  if auth.uid() is null then raise exception 'unauthenticated' using errcode='42501'; end if;
  v_actor := public.current_actor_id();
  if v_actor is null then raise exception 'missing person actor' using errcode='42501'; end if;

  select canonical_owner_actor_id into v_owner from public.resources where id = p_resource_id;
  if v_owner is null then raise exception 'resource not found' using errcode='P0002'; end if;
  if not (v_actor = v_owner or public.is_context_member(v_owner)) then
    raise exception 'not a member of resource context' using errcode='42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'relation_id',       rr.id,
           'direction',         'outbound',
           'relation_type',     rr.relation_type,
           'other_resource_id', rr.child_resource_id,
           'other', jsonb_build_object(
             'id',           other.id,
             'display_name', other.display_name,
             'class_key',    other.resource_class_key,
             'subtype_key',  other.resource_subtype_key,
             'status',       other.status
           ),
           'metadata',   rr.metadata,
           'created_at', rr.created_at,
           'updated_at', rr.updated_at
         ) order by rr.created_at desc), '[]'::jsonb)
    into v_outbound
    from public.resource_relations rr
    join public.resources other on other.id = rr.child_resource_id
   where rr.parent_resource_id = p_resource_id
     and (v_actor = other.canonical_owner_actor_id or public.is_context_member(other.canonical_owner_actor_id));

  select coalesce(jsonb_agg(jsonb_build_object(
           'relation_id',       rr.id,
           'direction',         'inbound',
           'relation_type',     rr.relation_type,
           'other_resource_id', rr.parent_resource_id,
           'other', jsonb_build_object(
             'id',           other.id,
             'display_name', other.display_name,
             'class_key',    other.resource_class_key,
             'subtype_key',  other.resource_subtype_key,
             'status',       other.status
           ),
           'metadata',   rr.metadata,
           'created_at', rr.created_at,
           'updated_at', rr.updated_at
         ) order by rr.created_at desc), '[]'::jsonb)
    into v_inbound
    from public.resource_relations rr
    join public.resources other on other.id = rr.parent_resource_id
   where rr.child_resource_id = p_resource_id
     and (v_actor = other.canonical_owner_actor_id or public.is_context_member(other.canonical_owner_actor_id));

  return jsonb_build_object(
    'resource_id', p_resource_id,
    'outbound',    v_outbound,
    'inbound',     v_inbound
  );
end;
$$;

comment on function public.list_resource_relations(uuid) is
  'R.5A.B.3: lista relaciones outbound/inbound de un resource. Visibilidad: ambos endpoints deben ser visibles al caller.';

revoke all on function public.list_resource_relations(uuid) from public, anon;
grant execute on function public.list_resource_relations(uuid) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. RPC set_resource_relation(parent, child, type, metadata?) -> upsert
-- ----------------------------------------------------------------------------
create or replace function public.set_resource_relation(
  p_parent_resource_id uuid,
  p_child_resource_id uuid,
  p_relation_type text,
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_actor uuid;
  v_parent_owner uuid;
  v_child_owner uuid;
  v_relation_id uuid;
  v_created boolean := false;
begin
  if auth.uid() is null then raise exception 'unauthenticated' using errcode='42501'; end if;
  v_actor := public.current_actor_id();
  if v_actor is null then raise exception 'missing person actor' using errcode='42501'; end if;

  if p_parent_resource_id = p_child_resource_id then
    raise exception 'self-relation not allowed' using errcode='22023';
  end if;

  if not exists (select 1 from public.resource_relation_types where relation_type = p_relation_type) then
    raise exception 'unknown relation type %', p_relation_type using errcode='22023';
  end if;

  select canonical_owner_actor_id into v_parent_owner from public.resources where id = p_parent_resource_id;
  if v_parent_owner is null then raise exception 'parent resource not found' using errcode='P0002'; end if;

  select canonical_owner_actor_id into v_child_owner from public.resources where id = p_child_resource_id;
  if v_child_owner is null then raise exception 'child resource not found' using errcode='P0002'; end if;

  -- CONVENCION: has_actor_authority(context, actor, permission)
  if not public.has_actor_authority(v_parent_owner, v_actor, 'resources.manage') then
    raise exception 'missing permission resources.manage on parent context' using errcode='42501';
  end if;

  if not (v_actor = v_child_owner or public.is_context_member(v_child_owner)) then
    raise exception 'not a member of child resource context' using errcode='42501';
  end if;

  insert into public.resource_relations (parent_resource_id, child_resource_id, relation_type, metadata, created_by_actor_id)
    values (p_parent_resource_id, p_child_resource_id, p_relation_type, coalesce(p_metadata, '{}'::jsonb), v_actor)
    on conflict (parent_resource_id, child_resource_id, relation_type) do update
      set metadata   = excluded.metadata,
          updated_at = now()
    returning id, (xmax = 0) into v_relation_id, v_created;

  return jsonb_build_object(
    'relation_id',         v_relation_id,
    'parent_resource_id',  p_parent_resource_id,
    'child_resource_id',   p_child_resource_id,
    'relation_type',       p_relation_type,
    'created',             v_created
  );
end;
$$;

comment on function public.set_resource_relation(uuid, uuid, text, jsonb) is
  'R.5A.B.3: upsert relation. Requiere resources.manage en parent context y membership en child context.';

revoke all on function public.set_resource_relation(uuid, uuid, text, jsonb) from public, anon;
grant execute on function public.set_resource_relation(uuid, uuid, text, jsonb) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 5. RPC remove_resource_relation(relation_id)
-- ----------------------------------------------------------------------------
create or replace function public.remove_resource_relation(p_relation_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_actor uuid;
  v_parent_owner uuid;
begin
  if auth.uid() is null then raise exception 'unauthenticated' using errcode='42501'; end if;
  v_actor := public.current_actor_id();
  if v_actor is null then raise exception 'missing person actor' using errcode='42501'; end if;

  select r.canonical_owner_actor_id into v_parent_owner
    from public.resource_relations rr
    join public.resources r on r.id = rr.parent_resource_id
   where rr.id = p_relation_id;

  if v_parent_owner is null then
    return jsonb_build_object('removed', false, 'reason', 'not_found');
  end if;

  if not public.has_actor_authority(v_parent_owner, v_actor, 'resources.manage') then
    raise exception 'missing permission resources.manage on parent context' using errcode='42501';
  end if;

  delete from public.resource_relations where id = p_relation_id;

  return jsonb_build_object('removed', true, 'relation_id', p_relation_id);
end;
$$;

comment on function public.remove_resource_relation(uuid) is
  'R.5A.B.3: borra relation. Requiere resources.manage en parent context. Idempotente (not_found si ya no existe).';

revoke all on function public.remove_resource_relation(uuid) from public, anon;
grant execute on function public.remove_resource_relation(uuid) to authenticated, service_role;
