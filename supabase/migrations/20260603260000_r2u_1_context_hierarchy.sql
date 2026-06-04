-- ============================================================================
-- R.2U.1 — CONTEXT HIERARCHY (PARENT / CHILD CONTEXTS)
-- ============================================================================
-- Doctrina: un contexto puede contener otros contextos sin nueva primitiva.
-- Se usa actor_relationships con relationship_type='contains'. NO heredan
-- memberships, rights, rules ni money — la relación es organizacional.
--
-- Esta mig agrega:
--   1. 4 permission_catalog keys (context.children.{create,link,unlink} + context.tree.view)
--   2. Backfill a roles admin (todas) y member (tree.view) para contextos existentes
--   3. _seed_context_roles ampliado: member nuevo recibe context.tree.view
--   4. Cycle protection trigger en actor_relationships para relationship_type='contains'
--   5. 5 read RPCs: context_children / context_parents / context_tree /
--      context_ancestors / context_descendants
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Permission catalog
-- ────────────────────────────────────────────────────────────────────────────
insert into public.permission_catalog (permission_key, category, description) values
  ('context.children.create', 'context', 'Crear contextos hijos bajo este contexto'),
  ('context.children.link',   'context', 'Vincular un contexto existente como hijo'),
  ('context.children.unlink', 'context', 'Desvincular un contexto hijo (soft, preserva historial)'),
  ('context.tree.view',       'context', 'Ver la jerarquía padre/hijo del contexto')
on conflict (permission_key) do nothing;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Backfill: admin recibe las 4; member recibe sólo context.tree.view
-- ────────────────────────────────────────────────────────────────────────────
insert into public.role_permissions (role_id, permission_key)
select r.id, pk
  from public.roles r
  cross join unnest(array['context.children.create',
                          'context.children.link',
                          'context.children.unlink',
                          'context.tree.view']) as pk
 where r.role_key = 'admin'
on conflict (role_id, permission_key) do nothing;

insert into public.role_permissions (role_id, permission_key)
select r.id, 'context.tree.view'
  from public.roles r
 where r.role_key = 'member'
on conflict (role_id, permission_key) do nothing;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. _seed_context_roles: member nuevo recibe context.tree.view
--    (admin ya recibe todas las permissions vía SELECT * del catálogo)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._seed_context_roles(p_context_actor_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_role uuid;
  v_member_role uuid;
begin
  insert into public.roles (context_actor_id, role_key, display_name, description)
  values (p_context_actor_id, 'admin', 'Admin', 'Autoridad total en el contexto')
  on conflict (context_actor_id, role_key) do update set display_name = excluded.display_name
  returning id into v_admin_role;

  insert into public.roles (context_actor_id, role_key, display_name, description)
  values (p_context_actor_id, 'member', 'Miembro', 'Participación estándar')
  on conflict (context_actor_id, role_key) do update set display_name = excluded.display_name
  returning id into v_member_role;

  -- admin: todas las permissions del catálogo (incluye context.children.* y tree.view)
  insert into public.role_permissions (role_id, permission_key)
  select v_admin_role, pc.permission_key from public.permission_catalog pc
  on conflict (role_id, permission_key) do nothing;

  -- member: view + participación básica + ver árbol
  insert into public.role_permissions (role_id, permission_key)
  select v_member_role, pk from unnest(array[
    'context.view', 'members.view', 'resources.view', 'events.view',
    'reservations.view', 'reservations.request', 'rules.view',
    'decisions.view', 'decisions.create', 'decisions.vote',
    'money.view', 'money.record', 'documents.view',
    'events.create',
    'context.tree.view'
  ]) as pk
  on conflict (role_id, permission_key) do nothing;
end;
$$;

revoke all on function public._seed_context_roles(uuid) from public, anon, authenticated;
grant execute on function public._seed_context_roles(uuid) to service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Cycle protection — trigger BEFORE INSERT OR UPDATE en actor_relationships
--    Protege únicamente relationship_type='contains'. Verifica:
--      a) subject_actor_id != object_actor_id (no self-loop)
--      b) No existe path 'contains' activo desde object → subject (no ciclo)
--    Sólo considera relaciones activas (ends_at IS NULL OR ends_at > now()).
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._actor_relationships_no_contains_cycle()
returns trigger
language plpgsql
as $$
declare
  v_cycle boolean;
begin
  if new.relationship_type is distinct from 'contains' then
    return new;
  end if;

  -- object_actor_id es obligatorio para 'contains' (no se contiene un resource)
  if new.object_actor_id is null then
    raise exception 'contains requires object_actor_id (actor target)' using errcode = '22023';
  end if;

  -- Self-loop
  if new.subject_actor_id = new.object_actor_id then
    raise exception 'contains cycle: a context cannot contain itself' using errcode = '22023';
  end if;

  -- Si la relación está soft-ended (ends_at <= now()), no enforce
  if new.ends_at is not null and new.ends_at <= now() then
    return new;
  end if;

  -- Path detection: ¿existe ya un camino contains desde object → subject?
  -- Si lo hay, agregar subject→object crearía un ciclo.
  with recursive descendants as (
    -- Empezar desde object_actor_id (lo que queremos meter como hijo)
    select new.object_actor_id::uuid as actor_id, 1 as depth
    union
    select ar.object_actor_id, d.depth + 1
      from descendants d
      join public.actor_relationships ar
        on ar.subject_actor_id = d.actor_id
       and ar.relationship_type = 'contains'
       and ar.object_actor_id is not null
       and (ar.ends_at is null or ar.ends_at > now())
       and (TG_OP <> 'UPDATE' or ar.id <> new.id)  -- ignorar la propia fila en UPDATE
     where d.depth < 64  -- depth limit defensive
  )
  select exists (select 1 from descendants where actor_id = new.subject_actor_id)
    into v_cycle;

  if v_cycle then
    raise exception 'contains cycle detected: % already (transitively) contains %',
      new.object_actor_id, new.subject_actor_id
      using errcode = '22023';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_actor_relationships_no_contains_cycle on public.actor_relationships;
create trigger trg_actor_relationships_no_contains_cycle
  before insert or update on public.actor_relationships
  for each row execute function public._actor_relationships_no_contains_cycle();

comment on function public._actor_relationships_no_contains_cycle() is
  'R.2U.1: previene ciclos en actor_relationships.contains (self-loop + transitividad).';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. context_children(p_context_actor_id) — hijos directos
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.context_children(p_context_actor_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
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
      'id', a.id,
      'name', a.display_name,
      'actor_kind', a.actor_kind,
      'actor_subtype', a.actor_subtype,
      'visibility', a.visibility,
      'linked_at', ar.created_at
    ) order by a.display_name)
      from public.actor_relationships ar
      join public.actors a on a.id = ar.object_actor_id
     where ar.subject_actor_id = p_context_actor_id
       and ar.relationship_type = 'contains'
       and (ar.ends_at is null or ar.ends_at > now())
       and a.archived_at is null
       and a.actor_kind in ('collective', 'legal_entity')
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.context_children(uuid) from public, anon;
grant execute on function public.context_children(uuid) to authenticated, service_role;

comment on function public.context_children(uuid) is
  'R.2U.1: hijos directos del contexto (actor_relationships.contains, active only).';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. context_parents(p_context_actor_id) — padres directos
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.context_parents(p_context_actor_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
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
      'id', a.id,
      'name', a.display_name,
      'actor_kind', a.actor_kind,
      'actor_subtype', a.actor_subtype,
      'linked_at', ar.created_at
    ) order by a.display_name)
      from public.actor_relationships ar
      join public.actors a on a.id = ar.subject_actor_id
     where ar.object_actor_id = p_context_actor_id
       and ar.relationship_type = 'contains'
       and (ar.ends_at is null or ar.ends_at > now())
       and a.archived_at is null
       and a.actor_kind in ('collective', 'legal_entity')
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.context_parents(uuid) from public, anon;
grant execute on function public.context_parents(uuid) to authenticated, service_role;

comment on function public.context_parents(uuid) is
  'R.2U.1: padres directos del contexto.';

-- ────────────────────────────────────────────────────────────────────────────
-- 7. context_tree(p_root_context_actor_id) — árbol completo descendente
--    Devuelve jsonb {id, name, actor_kind, children: [...]} recursivo.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.context_tree(p_root_context_actor_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_root_row record;
  v_children jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.is_context_member(p_root_context_actor_id) then
    raise exception 'not a member of context %', p_root_context_actor_id using errcode = '42501';
  end if;

  select id, display_name, actor_kind, actor_subtype, visibility
    into v_root_row
    from public.actors
   where id = p_root_context_actor_id;

  if v_root_row.id is null then
    raise exception 'context not found' using errcode = 'P0002';
  end if;

  -- Recursive build: para cada hijo, recursa context_tree si el caller es miembro;
  -- si no es miembro del hijo, lo emite con campos básicos y children=null.
  select coalesce(jsonb_agg(
    case
      when public.is_context_member(c.id) then
        public.context_tree(c.id)
      else
        jsonb_build_object(
          'id', c.id,
          'name', c.display_name,
          'actor_kind', c.actor_kind,
          'actor_subtype', c.actor_subtype,
          'children', null,
          'restricted', true)
    end order by c.display_name
  ), '[]'::jsonb)
    into v_children
    from public.actor_relationships ar
    join public.actors c on c.id = ar.object_actor_id
   where ar.subject_actor_id = p_root_context_actor_id
     and ar.relationship_type = 'contains'
     and (ar.ends_at is null or ar.ends_at > now())
     and c.archived_at is null
     and c.actor_kind in ('collective', 'legal_entity');

  return jsonb_build_object(
    'id', v_root_row.id,
    'name', v_root_row.display_name,
    'actor_kind', v_root_row.actor_kind,
    'actor_subtype', v_root_row.actor_subtype,
    'children', v_children
  );
end;
$$;

revoke all on function public.context_tree(uuid) from public, anon;
grant execute on function public.context_tree(uuid) to authenticated, service_role;

comment on function public.context_tree(uuid) is
  'R.2U.1: árbol completo descendente. Subárboles donde el caller no es miembro se marcan restricted:true.';

-- ────────────────────────────────────────────────────────────────────────────
-- 8. context_ancestors(p_context_actor_id) — padre → abuelo → bisabuelo …
--    Devuelve array ordenado del padre directo hacia arriba (depth 1 → ∞).
--    Si hay múltiples padres (poly-hierarchy), enumera todos los paths.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.context_ancestors(p_context_actor_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  return coalesce((
    with recursive ancestors as (
      select ar.subject_actor_id as actor_id, 1 as depth
        from public.actor_relationships ar
       where ar.object_actor_id = p_context_actor_id
         and ar.relationship_type = 'contains'
         and (ar.ends_at is null or ar.ends_at > now())
      union
      select ar.subject_actor_id, a.depth + 1
        from ancestors a
        join public.actor_relationships ar
          on ar.object_actor_id = a.actor_id
         and ar.relationship_type = 'contains'
         and (ar.ends_at is null or ar.ends_at > now())
       where a.depth < 64
    )
    select jsonb_agg(jsonb_build_object(
      'id', act.id,
      'name', act.display_name,
      'actor_kind', act.actor_kind,
      'actor_subtype', act.actor_subtype,
      'depth', a.depth
    ) order by a.depth, act.display_name)
      from ancestors a
      join public.actors act on act.id = a.actor_id
     where act.archived_at is null
       and act.actor_kind in ('collective', 'legal_entity')
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.context_ancestors(uuid) from public, anon;
grant execute on function public.context_ancestors(uuid) to authenticated, service_role;

comment on function public.context_ancestors(uuid) is
  'R.2U.1: ancestros del contexto ordenados por profundidad ascendente.';

-- ────────────────────────────────────────────────────────────────────────────
-- 9. context_descendants(p_context_actor_id) — todos los descendientes
--    Devuelve array plano. Para árbol jerárquico usar context_tree.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.context_descendants(p_context_actor_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  return coalesce((
    with recursive descendants as (
      select ar.object_actor_id as actor_id, 1 as depth
        from public.actor_relationships ar
       where ar.subject_actor_id = p_context_actor_id
         and ar.relationship_type = 'contains'
         and ar.object_actor_id is not null
         and (ar.ends_at is null or ar.ends_at > now())
      union
      select ar.object_actor_id, d.depth + 1
        from descendants d
        join public.actor_relationships ar
          on ar.subject_actor_id = d.actor_id
         and ar.relationship_type = 'contains'
         and ar.object_actor_id is not null
         and (ar.ends_at is null or ar.ends_at > now())
       where d.depth < 64
    )
    select jsonb_agg(jsonb_build_object(
      'id', act.id,
      'name', act.display_name,
      'actor_kind', act.actor_kind,
      'actor_subtype', act.actor_subtype,
      'depth', d.depth
    ) order by d.depth, act.display_name)
      from descendants d
      join public.actors act on act.id = d.actor_id
     where act.archived_at is null
       and act.actor_kind in ('collective', 'legal_entity')
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.context_descendants(uuid) from public, anon;
grant execute on function public.context_descendants(uuid) to authenticated, service_role;

comment on function public.context_descendants(uuid) is
  'R.2U.1: descendientes del contexto (plano, ordenados por profundidad).';
