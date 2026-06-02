-- ============================================================================
-- MVP 2.0 — M.2 PARTICIPACIÓN
-- ============================================================================
-- Fix de privilegios de funciones (hallazgo smoke M.1) + actor_memberships +
-- roles + role_assignments + permission_catalog + role_permissions +
-- has_actor_authority(context, member, permission) + RLS membership-aware + smoke.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 0. FIX (hallazgo _smoke_mvp2_m1_identity Caso 6): ALTER DEFAULT PRIVILEGES
--    "IN SCHEMA" no puede remover el default global de PostgreSQL que da
--    EXECUTE a PUBLIC en funciones nuevas — los per-schema solo AGREGAN.
--    Fix: revoke global (rol que aplica migrations) + revoke explícito de las
--    funciones M.0/M.1 ya creadas. Patrón R.1-SEC.4.
-- ────────────────────────────────────────────────────────────────────────────
alter default privileges revoke execute on functions from public;

revoke all on function public.touch_updated_at() from public, anon;
revoke all on function public.system_actor_id() from public, anon;
revoke all on function public.current_actor_id() from public, anon;
revoke all on function public._create_person_actor_for_auth_user(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public._handle_new_auth_user() from public, anon, authenticated;
revoke all on function public.ensure_person_actor() from public, anon;
revoke all on function public.update_my_profile(text, text, text, jsonb) from public, anon;
revoke all on function public._smoke_mvp2_m1_identity() from public, anon, authenticated;

-- Re-grants explícitos (los wrappers de cliente a authenticated; internas a nadie)
grant execute on function public.system_actor_id() to authenticated, service_role;
grant execute on function public.current_actor_id() to authenticated, service_role;
grant execute on function public.ensure_person_actor() to authenticated, service_role;
grant execute on function public.update_my_profile(text, text, text, jsonb) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. actor_memberships
-- ────────────────────────────────────────────────────────────────────────────
create table public.actor_memberships (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  member_actor_id uuid not null references public.actors(id) on delete cascade,
  membership_status text not null default 'active' check (membership_status in
    ('invited', 'requested', 'active', 'paused', 'left', 'removed', 'banned')),
  membership_type text not null default 'member' check (membership_type in
    ('founder', 'member', 'guest', 'observer')),
  invited_by_actor_id uuid references public.actors(id),
  joined_at timestamptz,
  left_at timestamptz,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (context_actor_id, member_actor_id, membership_type)
);

create index idx_memberships_member on public.actor_memberships (member_actor_id, membership_status);
create index idx_memberships_context on public.actor_memberships (context_actor_id, membership_status);

create trigger trg_memberships_touch before update on public.actor_memberships
  for each row execute function public.touch_updated_at();

comment on table public.actor_memberships is 'MVP2: quién participa en qué contexto.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. roles / permission_catalog / role_permissions / role_assignments
-- ────────────────────────────────────────────────────────────────────────────
create table public.roles (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  role_key text not null,
  display_name text not null,
  description text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (context_actor_id, role_key)
);

create trigger trg_roles_touch before update on public.roles
  for each row execute function public.touch_updated_at();

create table public.permission_catalog (
  permission_key text primary key,
  category text not null,
  description text,
  metadata jsonb not null default '{}'
);

create table public.role_permissions (
  id uuid primary key default gen_random_uuid(),
  role_id uuid not null references public.roles(id) on delete cascade,
  permission_key text not null references public.permission_catalog(permission_key),
  allowed boolean not null default true,
  created_at timestamptz not null default now(),
  unique (role_id, permission_key)
);

create table public.role_assignments (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  member_actor_id uuid not null references public.actors(id) on delete cascade,
  role_id uuid not null references public.roles(id) on delete cascade,
  starts_at timestamptz default now(),
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  unique (context_actor_id, member_actor_id, role_id)
);

create index idx_role_assignments_member on public.role_assignments (member_actor_id, context_actor_id);

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Seed del permission_catalog (MVP)
-- ────────────────────────────────────────────────────────────────────────────
insert into public.permission_catalog (permission_key, category, description) values
  ('context.view',         'context',      'Ver el contexto y su resumen'),
  ('context.manage',       'context',      'Editar/archivar el contexto'),
  ('context.invite',       'context',      'Invitar miembros'),
  ('members.view',         'members',      'Ver miembros'),
  ('members.manage',       'members',      'Agregar/remover/suspender miembros y roles'),
  ('resources.view',       'resources',    'Ver recursos del contexto'),
  ('resources.create',     'resources',    'Crear recursos'),
  ('resources.manage',     'resources',    'Editar recursos y otorgar/revocar rights'),
  ('events.view',          'events',       'Ver eventos'),
  ('events.create',        'events',       'Crear eventos'),
  ('events.manage',        'events',       'Editar/cancelar eventos y gestionar asistentes'),
  ('reservations.view',    'reservations', 'Ver reservaciones'),
  ('reservations.request', 'reservations', 'Solicitar reservaciones'),
  ('reservations.manage',  'reservations', 'Aprobar/rechazar reservaciones y resolver conflictos'),
  ('rules.view',           'rules',        'Ver reglas'),
  ('rules.manage',         'rules',        'Crear/editar/archivar reglas'),
  ('decisions.view',       'decisions',    'Ver decisiones'),
  ('decisions.create',     'decisions',    'Proponer decisiones'),
  ('decisions.vote',       'decisions',    'Votar'),
  ('decisions.execute',    'decisions',    'Ejecutar decisiones aprobadas'),
  ('money.view',           'money',        'Ver movimientos y obligaciones'),
  ('money.record',         'money',        'Registrar gastos/multas/resultados'),
  ('money.settle',         'money',        'Generar y marcar settlements'),
  ('documents.view',       'documents',    'Ver documentos'),
  ('documents.manage',     'documents',    'Subir/archivar documentos');

-- ────────────────────────────────────────────────────────────────────────────
-- 4. has_actor_authority(context, member, permission) — el RPC de autoridad MVP
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.has_actor_authority(
  p_context_actor_id uuid,
  p_member_actor_id uuid,
  p_permission_key text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    -- Self-context: un actor siempre tiene autoridad total sobre su propio contexto
    p_context_actor_id = p_member_actor_id
    or exists (
      select 1
        from public.role_assignments ra
        join public.role_permissions rp on rp.role_id = ra.role_id and rp.allowed
       where ra.context_actor_id = p_context_actor_id
         and ra.member_actor_id = p_member_actor_id
         and rp.permission_key = p_permission_key
         and (ra.starts_at is null or ra.starts_at <= now())
         and (ra.ends_at is null or ra.ends_at > now())
         -- la membresía debe seguir activa
         and exists (
           select 1 from public.actor_memberships am
           where am.context_actor_id = ra.context_actor_id
             and am.member_actor_id = ra.member_actor_id
             and am.membership_status = 'active'
         )
    );
$$;

comment on function public.has_actor_authority(uuid, uuid, text) is
  'MVP2: ¿member tiene la permission en el context? Self-context = siempre true. Requiere membership activa + role assignment vigente.';

revoke all on function public.has_actor_authority(uuid, uuid, text) from public, anon;
grant execute on function public.has_actor_authority(uuid, uuid, text) to authenticated, service_role;

-- Helper: ¿el caller es miembro activo del contexto?
create or replace function public.is_context_member(p_context_actor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    p_context_actor_id = public.current_actor_id()
    or exists (
      select 1 from public.actor_memberships am
      where am.context_actor_id = p_context_actor_id
        and am.member_actor_id = public.current_actor_id()
        and am.membership_status = 'active'
    );
$$;

revoke all on function public.is_context_member(uuid) from public, anon;
grant execute on function public.is_context_member(uuid) to authenticated, service_role;

-- Helper interno: seed de roles default (admin/member) para un contexto nuevo.
-- Lo consume create_context (M.3).
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

  -- admin: todas las permissions del catálogo
  insert into public.role_permissions (role_id, permission_key)
  select v_admin_role, pc.permission_key from public.permission_catalog pc
  on conflict (role_id, permission_key) do nothing;

  -- member: view + participación básica
  insert into public.role_permissions (role_id, permission_key)
  select v_member_role, pk from unnest(array[
    'context.view', 'members.view', 'resources.view', 'events.view',
    'reservations.view', 'reservations.request', 'rules.view',
    'decisions.view', 'decisions.create', 'decisions.vote',
    'money.view', 'money.record', 'documents.view',
    'events.create'
  ]) as pk
  on conflict (role_id, permission_key) do nothing;
end;
$$;

revoke all on function public._seed_context_roles(uuid) from public, anon, authenticated;
grant execute on function public._seed_context_roles(uuid) to service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. RLS (D4)
-- ────────────────────────────────────────────────────────────────────────────
alter table public.actor_memberships enable row level security;
alter table public.roles enable row level security;
alter table public.permission_catalog enable row level security;
alter table public.role_permissions enable row level security;
alter table public.role_assignments enable row level security;

-- actors: reemplazar la policy M.1 por la versión membership-aware
drop policy if exists actors_select_m1 on public.actors;
create policy actors_select_m2 on public.actors
  for select to authenticated
  using (
    id = public.current_actor_id()
    or visibility = 'public'
    or actor_kind = 'system'
    -- contextos donde soy miembro activo
    or exists (
      select 1 from public.actor_memberships m
      where m.context_actor_id = actors.id
        and m.member_actor_id = public.current_actor_id()
        and m.membership_status = 'active')
    -- co-members: actores con los que comparto contexto
    or exists (
      select 1
        from public.actor_memberships m1
        join public.actor_memberships m2 on m2.context_actor_id = m1.context_actor_id
       where m1.member_actor_id = actors.id
         and m2.member_actor_id = public.current_actor_id()
         and m1.membership_status = 'active'
         and m2.membership_status = 'active')
  );

-- memberships: las mías + las de contextos donde soy miembro
create policy memberships_select on public.actor_memberships
  for select to authenticated
  using (
    member_actor_id = public.current_actor_id()
    or public.is_context_member(context_actor_id)
  );

-- roles / assignments: visibles para miembros del contexto
create policy roles_select on public.roles
  for select to authenticated
  using (public.is_context_member(context_actor_id));

create policy role_assignments_select on public.role_assignments
  for select to authenticated
  using (public.is_context_member(context_actor_id));

create policy role_permissions_select on public.role_permissions
  for select to authenticated
  using (exists (
    select 1 from public.roles r
    where r.id = role_permissions.role_id and public.is_context_member(r.context_actor_id)
  ));

-- catálogo global: lectura para todos los authenticated
create policy permission_catalog_select on public.permission_catalog
  for select to authenticated
  using (true);

revoke all on public.actor_memberships, public.roles, public.permission_catalog,
       public.role_permissions, public.role_assignments from anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Smoke
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_m2_participation()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid;  -- person A (admin)
  v_b uuid;  -- person B (member)
  v_ctx uuid;  -- collective de prueba
  v_admin_role uuid;
  v_member_role uuid;
begin
  -- Setup: 2 personas + 1 collective + roles + memberships
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke A', '+520000000002', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke B', '+520000000003', null);

  insert into public.actors (actor_kind, actor_subtype, display_name, created_by_actor_id)
  values ('collective', 'friend_group', '_smoke_m2 ctx', v_a)
  returning id into v_ctx;

  perform public._seed_context_roles(v_ctx);
  select id into v_admin_role from public.roles where context_actor_id = v_ctx and role_key = 'admin';
  select id into v_member_role from public.roles where context_actor_id = v_ctx and role_key = 'member';

  insert into public.actor_memberships (context_actor_id, member_actor_id, membership_status, membership_type, joined_at)
  values (v_ctx, v_a, 'active', 'founder', now()), (v_ctx, v_b, 'active', 'member', now());

  insert into public.role_assignments (context_actor_id, member_actor_id, role_id)
  values (v_ctx, v_a, v_admin_role), (v_ctx, v_b, v_member_role);

  -- Caso 1: admin tiene members.manage
  if not public.has_actor_authority(v_ctx, v_a, 'members.manage') then
    raise exception 'mvp2_m2 Caso1: admin sin members.manage';
  end if;

  -- Caso 2: member NO tiene members.manage
  if public.has_actor_authority(v_ctx, v_b, 'members.manage') then
    raise exception 'mvp2_m2 Caso2: member tiene members.manage';
  end if;

  -- Caso 3: member SÍ tiene events.view + decisions.vote
  if not public.has_actor_authority(v_ctx, v_b, 'events.view')
     or not public.has_actor_authority(v_ctx, v_b, 'decisions.vote') then
    raise exception 'mvp2_m2 Caso3: member sin permissions básicas';
  end if;

  -- Caso 4: self-context — un actor siempre tiene autoridad sobre sí mismo
  if not public.has_actor_authority(v_a, v_a, 'money.settle') then
    raise exception 'mvp2_m2 Caso4: self-context authority falla';
  end if;

  -- Caso 5: membership suspendida mata la autoridad
  update public.actor_memberships set membership_status = 'paused'
   where context_actor_id = v_ctx and member_actor_id = v_b;
  if public.has_actor_authority(v_ctx, v_b, 'events.view') then
    raise exception 'mvp2_m2 Caso5: paused membership conserva autoridad';
  end if;
  update public.actor_memberships set membership_status = 'active'
   where context_actor_id = v_ctx and member_actor_id = v_b;

  -- Caso 6: is_context_member (simulando JWT de B)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  if not public.is_context_member(v_ctx) then
    raise exception 'mvp2_m2 Caso6: is_context_member falla para miembro activo';
  end if;
  perform set_config('request.jwt.claims', null, true);

  -- Caso 7: anon sin acceso a nada de participación
  if has_table_privilege('anon', 'public.actor_memberships', 'SELECT')
     or has_table_privilege('anon', 'public.roles', 'SELECT')
     or has_function_privilege('anon', 'public.has_actor_authority(uuid, uuid, text)', 'EXECUTE') then
    raise exception 'mvp2_m2 Caso7: anon tiene acceso a participación';
  end if;

  -- Caso 8: cero write policies directas (D4)
  if exists (
    select 1 from pg_policy pol join pg_class c on c.oid = pol.polrelid
    where c.relname in ('actor_memberships', 'roles', 'role_permissions', 'role_assignments', 'permission_catalog')
      and pol.polcmd in ('a', 'w', 'd')
  ) then
    raise exception 'mvp2_m2 Caso8: existe write policy directa';
  end if;

  -- Cleanup
  delete from public.role_assignments where context_actor_id = v_ctx;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx;
  delete from public.roles where context_actor_id = v_ctx;
  delete from public.actor_memberships where context_actor_id = v_ctx;
  delete from public.actors where id = v_ctx;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_m2_participation passed (8 casos)';
end;
$$;

revoke all on function public._smoke_mvp2_m2_participation() from public, anon, authenticated;

comment on function public._smoke_mvp2_m2_participation() is 'Smoke MVP2 M.2: memberships, roles, permissions, has_actor_authority, RLS.';
