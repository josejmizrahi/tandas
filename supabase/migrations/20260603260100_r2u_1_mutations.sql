-- ============================================================================
-- R.2U.1 — MUTATIONS: create_child_context / link_child_context / unlink_child_context
-- ============================================================================
-- Gateado por permission_catalog keys agregadas en la mig anterior:
--   create  → context.children.create  (en el padre)
--   link    → context.children.link    (en el padre) + autoridad sobre el child
--   unlink  → context.children.unlink  (en el padre)
--
-- Cycle protection en INSERT/UPDATE de actor_relationships ya lo cubre el trigger.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- create_child_context(p_parent, display_name, actor_kind, actor_subtype, visibility, metadata)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.create_child_context(
  p_parent_context_actor_id uuid,
  p_display_name text,
  p_actor_kind text default 'collective',
  p_actor_subtype text default 'friend_group',
  p_visibility text default 'private',
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_child uuid;
  v_rel_id uuid;
  v_parent_row record;
begin
  if v_caller is null then
    raise exception 'no person actor — call ensure_person_actor first' using errcode = '28000';
  end if;
  if p_display_name is null or length(btrim(p_display_name)) = 0 then
    raise exception 'display_name required' using errcode = '22023';
  end if;
  if p_actor_kind not in ('collective', 'legal_entity') then
    raise exception 'context must be collective or legal_entity' using errcode = '22023';
  end if;

  select id, actor_kind into v_parent_row from public.actors where id = p_parent_context_actor_id;
  if v_parent_row.id is null then
    raise exception 'parent context not found' using errcode = 'P0002';
  end if;
  if v_parent_row.actor_kind not in ('collective', 'legal_entity') then
    raise exception 'parent must be collective or legal_entity' using errcode = '22023';
  end if;

  if not public.has_actor_authority(p_parent_context_actor_id, v_caller, 'context.children.create') then
    raise exception 'not authorized to create child contexts under %', p_parent_context_actor_id
      using errcode = '42501';
  end if;

  -- Crear el child actor + seed roles + caller como founder del child
  insert into public.actors (actor_kind, actor_subtype, display_name, visibility, metadata, created_by_actor_id)
  values (p_actor_kind, p_actor_subtype, btrim(p_display_name), p_visibility,
          coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('parent_context_actor_id', p_parent_context_actor_id),
          v_caller)
  returning id into v_child;

  perform public._seed_context_roles(v_child);

  -- Membership founder + role admin en el child
  insert into public.actor_memberships (context_actor_id, member_actor_id, membership_status, membership_type, joined_at)
  values (v_child, v_caller, 'active', 'founder', now());

  insert into public.role_assignments (context_actor_id, member_actor_id, role_id)
  select v_child, v_caller, r.id
    from public.roles r
   where r.context_actor_id = v_child and r.role_key = 'admin';

  -- Relación contains parent → child. El trigger de ciclo no aplica porque
  -- el child es brand new (no participa en ninguna otra contains aún).
  insert into public.actor_relationships
    (subject_actor_id, relationship_type, object_actor_id, created_by_actor_id, metadata)
  values
    (p_parent_context_actor_id, 'contains', v_child, v_caller,
     jsonb_build_object('via', 'create_child_context'))
  returning id into v_rel_id;

  -- Activity en ambos contextos
  perform public._emit_activity(p_parent_context_actor_id, v_caller, 'context.child.created',
    'actor', v_child,
    jsonb_build_object('child_actor_id', v_child, 'display_name', btrim(p_display_name),
                       'actor_kind', p_actor_kind, 'actor_subtype', p_actor_subtype,
                       'relationship_id', v_rel_id));

  perform public._emit_activity(v_child, v_caller, 'context.created',
    'actor', v_child,
    jsonb_build_object('display_name', btrim(p_display_name),
                       'actor_kind', p_actor_kind, 'actor_subtype', p_actor_subtype,
                       'parent_context_actor_id', p_parent_context_actor_id));

  return jsonb_build_object(
    'parent_context_actor_id', p_parent_context_actor_id,
    'child_context_actor_id', v_child,
    'relationship_id', v_rel_id,
    'context', (select to_jsonb(a) from public.actors a where a.id = v_child)
  );
end;
$$;

revoke all on function public.create_child_context(uuid, text, text, text, text, jsonb)
  from public, anon;
grant execute on function public.create_child_context(uuid, text, text, text, text, jsonb)
  to authenticated, service_role;

comment on function public.create_child_context(uuid, text, text, text, text, jsonb) is
  'R.2U.1: crea un contexto hijo bajo un padre. Caller deviene founder/admin del child.';

-- ────────────────────────────────────────────────────────────────────────────
-- link_child_context(p_parent, p_child)
-- Vincula un contexto existente como hijo. Requiere autoridad en ambos lados:
-- context.children.link en el padre + context.manage en el child (para evitar
-- "adopciones" no consentidas).
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.link_child_context(
  p_parent_context_actor_id uuid,
  p_child_context_actor_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_parent_kind text;
  v_child_kind text;
  v_existing_id uuid;
  v_rel_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if p_parent_context_actor_id is null or p_child_context_actor_id is null then
    raise exception 'parent and child required' using errcode = '22023';
  end if;
  if p_parent_context_actor_id = p_child_context_actor_id then
    raise exception 'cannot link a context to itself' using errcode = '22023';
  end if;

  select actor_kind into v_parent_kind from public.actors where id = p_parent_context_actor_id;
  select actor_kind into v_child_kind  from public.actors where id = p_child_context_actor_id;
  if v_parent_kind is null then raise exception 'parent context not found' using errcode = 'P0002'; end if;
  if v_child_kind  is null then raise exception 'child context not found'  using errcode = 'P0002'; end if;
  if v_parent_kind not in ('collective', 'legal_entity') then
    raise exception 'parent must be collective or legal_entity' using errcode = '22023';
  end if;
  if v_child_kind not in ('collective', 'legal_entity') then
    raise exception 'child must be collective or legal_entity' using errcode = '22023';
  end if;

  if not public.has_actor_authority(p_parent_context_actor_id, v_caller, 'context.children.link') then
    raise exception 'not authorized to link children to %', p_parent_context_actor_id
      using errcode = '42501';
  end if;
  -- Consentimiento del child: caller debe tener context.manage allí
  if not public.has_actor_authority(p_child_context_actor_id, v_caller, 'context.manage') then
    raise exception 'not authorized over child context % (need context.manage)', p_child_context_actor_id
      using errcode = '42501';
  end if;

  -- Idempotencia: si ya existe una relación activa contains, reutilizar
  select id into v_existing_id
    from public.actor_relationships
   where subject_actor_id = p_parent_context_actor_id
     and object_actor_id = p_child_context_actor_id
     and relationship_type = 'contains'
     and (ends_at is null or ends_at > now())
   limit 1;

  if v_existing_id is not null then
    return jsonb_build_object(
      'parent_context_actor_id', p_parent_context_actor_id,
      'child_context_actor_id', p_child_context_actor_id,
      'relationship_id', v_existing_id,
      'already_linked', true
    );
  end if;

  -- Cycle protection lo hace el trigger automáticamente
  insert into public.actor_relationships
    (subject_actor_id, relationship_type, object_actor_id, created_by_actor_id, metadata)
  values
    (p_parent_context_actor_id, 'contains', p_child_context_actor_id, v_caller,
     jsonb_build_object('via', 'link_child_context'))
  returning id into v_rel_id;

  perform public._emit_activity(p_parent_context_actor_id, v_caller, 'context.child.linked',
    'actor', p_child_context_actor_id,
    jsonb_build_object('child_actor_id', p_child_context_actor_id, 'relationship_id', v_rel_id));

  perform public._emit_activity(p_child_context_actor_id, v_caller, 'context.parent.linked',
    'actor', p_parent_context_actor_id,
    jsonb_build_object('parent_actor_id', p_parent_context_actor_id, 'relationship_id', v_rel_id));

  return jsonb_build_object(
    'parent_context_actor_id', p_parent_context_actor_id,
    'child_context_actor_id', p_child_context_actor_id,
    'relationship_id', v_rel_id,
    'already_linked', false
  );
end;
$$;

revoke all on function public.link_child_context(uuid, uuid) from public, anon;
grant execute on function public.link_child_context(uuid, uuid) to authenticated, service_role;

comment on function public.link_child_context(uuid, uuid) is
  'R.2U.1: vincula un contexto existente como hijo. Requiere autoridad en ambos.';

-- ────────────────────────────────────────────────────────────────────────────
-- unlink_child_context(p_parent, p_child) — soft-end vía ends_at, preserva historial
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.unlink_child_context(
  p_parent_context_actor_id uuid,
  p_child_context_actor_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_rel_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  if not public.has_actor_authority(p_parent_context_actor_id, v_caller, 'context.children.unlink') then
    raise exception 'not authorized to unlink children from %', p_parent_context_actor_id
      using errcode = '42501';
  end if;

  -- Buscar la relación activa
  select id into v_rel_id
    from public.actor_relationships
   where subject_actor_id = p_parent_context_actor_id
     and object_actor_id = p_child_context_actor_id
     and relationship_type = 'contains'
     and (ends_at is null or ends_at > now())
   limit 1;

  if v_rel_id is null then
    -- Idempotente: si no hay link activo, devolver no-op
    return jsonb_build_object(
      'parent_context_actor_id', p_parent_context_actor_id,
      'child_context_actor_id', p_child_context_actor_id,
      'relationship_id', null,
      'unlinked', false
    );
  end if;

  update public.actor_relationships
     set ends_at = now()
   where id = v_rel_id;

  perform public._emit_activity(p_parent_context_actor_id, v_caller, 'context.child.unlinked',
    'actor', p_child_context_actor_id,
    jsonb_build_object('child_actor_id', p_child_context_actor_id, 'relationship_id', v_rel_id));

  perform public._emit_activity(p_child_context_actor_id, v_caller, 'context.parent.unlinked',
    'actor', p_parent_context_actor_id,
    jsonb_build_object('parent_actor_id', p_parent_context_actor_id, 'relationship_id', v_rel_id));

  return jsonb_build_object(
    'parent_context_actor_id', p_parent_context_actor_id,
    'child_context_actor_id', p_child_context_actor_id,
    'relationship_id', v_rel_id,
    'unlinked', true
  );
end;
$$;

revoke all on function public.unlink_child_context(uuid, uuid) from public, anon;
grant execute on function public.unlink_child_context(uuid, uuid) to authenticated, service_role;

comment on function public.unlink_child_context(uuid, uuid) is
  'R.2U.1: desvincula un contexto hijo (soft-end via ends_at, preserva historial).';
