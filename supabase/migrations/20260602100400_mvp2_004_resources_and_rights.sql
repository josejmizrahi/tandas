-- ============================================================================
-- MVP 2.0 — M.4 RESOURCES & RIGHTS
-- ============================================================================
-- resources + resource_rights + actor_relationships + auto-OWN trigger (patrón R.1)
-- + RPCs: create_resource / grant_right / revoke_right / list_context_resources /
-- resource_detail + RLS + smoke.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. resources
-- ────────────────────────────────────────────────────────────────────────────
create table public.resources (
  id uuid primary key default gen_random_uuid(),
  resource_type text not null check (resource_type in
    ('property', 'house', 'vehicle', 'bank_account', 'cash_pool', 'contract',
     'document', 'reservation', 'trip_booking', 'game', 'equipment', 'other')),
  display_name text not null,
  description text,
  status text not null default 'active' check (status in ('active', 'inactive', 'archived')),
  estimated_value numeric,
  currency text,
  created_by_actor_id uuid not null references public.actors(id),
  canonical_owner_actor_id uuid references public.actors(id),
  metadata jsonb not null default '{}',
  client_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create index idx_resources_owner on public.resources (canonical_owner_actor_id) where archived_at is null;
create unique index idx_resources_client_id on public.resources (created_by_actor_id, client_id) where client_id is not null;

create trigger trg_resources_touch before update on public.resources
  for each row execute function public.touch_updated_at();

comment on table public.resources is 'MVP2: qué cosa existe. canonical_owner_actor_id es cache del OWN right de mayor percent, no autoridad.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. resource_rights
-- ────────────────────────────────────────────────────────────────────────────
create table public.resource_rights (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references public.resources(id) on delete cascade,
  holder_actor_id uuid not null references public.actors(id),
  right_kind text not null check (right_kind in
    ('OWN', 'USE', 'MANAGE', 'VIEW', 'SELL', 'TRANSFER', 'GOVERN',
     'BENEFICIARY', 'LIEN', 'LEASE', 'APPROVE', 'AUDIT')),
  percent numeric check (percent is null or (percent >= 0 and percent <= 100)),
  scope text,
  starts_at timestamptz,
  ends_at timestamptz,
  revoked_at timestamptz,
  expired_at timestamptz,
  granted_by_actor_id uuid references public.actors(id),
  source_decision_id uuid,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_rights_holder on public.resource_rights (holder_actor_id, right_kind) where revoked_at is null;
create index idx_rights_resource on public.resource_rights (resource_id, right_kind) where revoked_at is null;
-- un solo right activo por (resource, holder, kind)
create unique index idx_rights_unique_active on public.resource_rights (resource_id, holder_actor_id, right_kind)
  where revoked_at is null and expired_at is null;

create trigger trg_rights_touch before update on public.resource_rights
  for each row execute function public.touch_updated_at();

-- active right helper
create or replace function public.actor_has_right(p_actor_id uuid, p_resource_id uuid, p_right_kind text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.resource_rights
    where resource_id = p_resource_id
      and holder_actor_id = p_actor_id
      and right_kind = p_right_kind
      and revoked_at is null and expired_at is null
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at > now())
  );
$$;

revoke all on function public.actor_has_right(uuid, uuid, text) from public, anon;
grant execute on function public.actor_has_right(uuid, uuid, text) to authenticated, service_role;

-- Sync de canonical_owner desde OWN de mayor percent (patrón R.0/R.1)
create or replace function public._sync_canonical_owner()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_resource_id uuid := coalesce(new.resource_id, old.resource_id);
  v_owner uuid;
begin
  if coalesce(new.right_kind, old.right_kind) = 'OWN' then
    select holder_actor_id into v_owner
      from public.resource_rights
     where resource_id = v_resource_id and right_kind = 'OWN'
       and revoked_at is null and expired_at is null
       and (ends_at is null or ends_at > now())
     order by coalesce(percent, 0) desc, created_at desc
     limit 1;
    if v_owner is not null then
      update public.resources set canonical_owner_actor_id = v_owner
       where id = v_resource_id and canonical_owner_actor_id is distinct from v_owner;
    end if;
  end if;
  return coalesce(new, old);
end; $$;

create trigger trg_rights_sync_canonical
  after insert or update or delete on public.resource_rights
  for each row execute function public._sync_canonical_owner();

-- Auto-OWN al crear resource (patrón R.1-WIRE.2)
create or replace function public._auto_own_on_resource_insert()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.canonical_owner_actor_id is not null then
    insert into public.resource_rights (resource_id, holder_actor_id, right_kind, percent, granted_by_actor_id, metadata)
    select new.id, new.canonical_owner_actor_id, 'OWN', 100, new.created_by_actor_id,
           '{"source": "auto_own_on_create"}'::jsonb
    where not exists (
      select 1 from public.resource_rights
      where resource_id = new.id and right_kind = 'OWN' and revoked_at is null
    );
  end if;
  return new;
end; $$;

create trigger trg_resources_auto_own
  after insert on public.resources
  for each row execute function public._auto_own_on_resource_insert();

-- ────────────────────────────────────────────────────────────────────────────
-- 3. actor_relationships
-- ────────────────────────────────────────────────────────────────────────────
create table public.actor_relationships (
  id uuid primary key default gen_random_uuid(),
  subject_actor_id uuid not null references public.actors(id) on delete cascade,
  relationship_type text not null check (relationship_type in
    ('member_of', 'contains', 'affiliated_with', 'controls', 'shareholder_of',
     'trustee_of', 'beneficiary_of', 'partner_of', 'creditor_of', 'debtor_to', 'related_to')),
  object_actor_id uuid references public.actors(id) on delete cascade,
  object_resource_id uuid references public.resources(id) on delete cascade,
  percent numeric,
  starts_at timestamptz,
  ends_at timestamptz,
  metadata jsonb not null default '{}',
  created_by_actor_id uuid references public.actors(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (object_actor_id is not null and object_resource_id is null)
    or (object_actor_id is null and object_resource_id is not null)
  )
);

create index idx_relationships_subject on public.actor_relationships (subject_actor_id, relationship_type);
create index idx_relationships_object on public.actor_relationships (object_actor_id) where object_actor_id is not null;

create trigger trg_relationships_touch before update on public.actor_relationships
  for each row execute function public.touch_updated_at();

-- ────────────────────────────────────────────────────────────────────────────
-- 4. RPCs
-- ────────────────────────────────────────────────────────────────────────────
-- create_resource: en un contexto (requiere resources.create) o personal (self)
create or replace function public.create_resource(
  p_context_actor_id uuid,
  p_resource_type text,
  p_display_name text,
  p_description text default null,
  p_estimated_value numeric default null,
  p_currency text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_owner uuid;
  v_id uuid;
  v_existing uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  -- el owner del resource es el contexto (o el caller si es contexto personal)
  v_owner := coalesce(p_context_actor_id, v_caller);

  if not public.has_actor_authority(v_owner, v_caller, 'resources.create') then
    raise exception 'not authorized to create resources in context %', v_owner using errcode = '42501';
  end if;

  -- idempotencia por client_id (D9)
  if p_client_id is not null then
    select id into v_existing from public.resources
     where created_by_actor_id = v_caller and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('resource_id', v_existing,
        'resource', (select to_jsonb(r) from public.resources r where r.id = v_existing));
    end if;
  end if;

  insert into public.resources
    (resource_type, display_name, description, estimated_value, currency,
     created_by_actor_id, canonical_owner_actor_id, metadata, client_id)
  values
    (p_resource_type, btrim(p_display_name), p_description, p_estimated_value, p_currency,
     v_caller, v_owner, coalesce(p_metadata, '{}'::jsonb), p_client_id)
  returning id into v_id;

  perform public._emit_activity(v_owner, v_caller, 'resource.created', 'resource', v_id,
    jsonb_build_object('resource_type', p_resource_type, 'display_name', btrim(p_display_name)),
    p_resource_id := v_id);

  return jsonb_build_object('resource_id', v_id,
    'resource', (select to_jsonb(r) from public.resources r where r.id = v_id));
end; $$;

revoke all on function public.create_resource(uuid, text, text, text, numeric, text, jsonb, text) from public, anon;
grant execute on function public.create_resource(uuid, text, text, text, numeric, text, jsonb, text) to authenticated, service_role;

-- grant_right: requiere OWN/MANAGE del caller o resources.manage en el contexto owner
create or replace function public.grant_right(
  p_resource_id uuid,
  p_holder_actor_id uuid,
  p_right_kind text,
  p_percent numeric default null,
  p_scope text default null,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_resource public.resources%rowtype;
  v_authorized boolean;
  v_executive boolean;
  v_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_resource from public.resources where id = p_resource_id;
  if v_resource.id is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;

  v_executive := p_right_kind in ('OWN', 'SELL', 'TRANSFER', 'LIEN');
  if v_executive then
    v_authorized := public.actor_has_right(v_caller, p_resource_id, 'OWN')
      or (v_resource.canonical_owner_actor_id is not null
          and public.has_actor_authority(v_resource.canonical_owner_actor_id, v_caller, 'resources.manage'));
  else
    v_authorized := public.actor_has_right(v_caller, p_resource_id, 'OWN')
      or public.actor_has_right(v_caller, p_resource_id, 'MANAGE')
      or (v_resource.canonical_owner_actor_id is not null
          and public.has_actor_authority(v_resource.canonical_owner_actor_id, v_caller, 'resources.manage'));
  end if;

  if not v_authorized then
    raise exception 'not authorized to grant % on resource %', p_right_kind, p_resource_id using errcode = '42501';
  end if;

  -- upsert/undelete (un right activo por resource+holder+kind)
  select id into v_id from public.resource_rights
   where resource_id = p_resource_id and holder_actor_id = p_holder_actor_id and right_kind = p_right_kind
   order by (revoked_at is null and expired_at is null) desc, created_at desc limit 1;

  if v_id is not null then
    update public.resource_rights
       set percent = p_percent, scope = p_scope, starts_at = p_starts_at, ends_at = p_ends_at,
           revoked_at = null, expired_at = null,
           granted_by_actor_id = v_caller,
           metadata = metadata || coalesce(p_metadata, '{}'::jsonb)
     where id = v_id;
  else
    insert into public.resource_rights
      (resource_id, holder_actor_id, right_kind, percent, scope, starts_at, ends_at,
       granted_by_actor_id, metadata)
    values
      (p_resource_id, p_holder_actor_id, p_right_kind, p_percent, p_scope, p_starts_at, p_ends_at,
       v_caller, coalesce(p_metadata, '{}'::jsonb))
    returning id into v_id;
  end if;

  perform public._emit_activity(v_resource.canonical_owner_actor_id, v_caller, 'right.granted', 'right', v_id,
    jsonb_build_object('right_kind', p_right_kind, 'holder_actor_id', p_holder_actor_id, 'percent', p_percent),
    p_resource_id := p_resource_id);

  return jsonb_build_object('right_id', v_id);
end; $$;

revoke all on function public.grant_right(uuid, uuid, text, numeric, text, timestamptz, timestamptz, jsonb) from public, anon;
grant execute on function public.grant_right(uuid, uuid, text, numeric, text, timestamptz, timestamptz, jsonb) to authenticated, service_role;

-- revoke_right
create or replace function public.revoke_right(p_right_id uuid)
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_right public.resource_rights%rowtype;
  v_owner uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_right from public.resource_rights where id = p_right_id;
  if v_right.id is null or v_right.revoked_at is not null then return; end if;

  select canonical_owner_actor_id into v_owner from public.resources where id = v_right.resource_id;

  if not (
    v_right.holder_actor_id = v_caller
    or public.actor_has_right(v_caller, v_right.resource_id, 'OWN')
    or public.actor_has_right(v_caller, v_right.resource_id, 'MANAGE')
    or (v_owner is not null and public.has_actor_authority(v_owner, v_caller, 'resources.manage'))
  ) then
    raise exception 'not authorized to revoke right %', p_right_id using errcode = '42501';
  end if;

  update public.resource_rights
     set revoked_at = now(), metadata = metadata || jsonb_build_object('revoked_by_actor_id', v_caller)
   where id = p_right_id and revoked_at is null;

  perform public._emit_activity(v_owner, v_caller, 'right.revoked', 'right', p_right_id,
    jsonb_build_object('right_kind', v_right.right_kind, 'holder_actor_id', v_right.holder_actor_id),
    p_resource_id := v_right.resource_id);
end; $$;

revoke all on function public.revoke_right(uuid) from public, anon;
grant execute on function public.revoke_right(uuid) to authenticated, service_role;

-- list_context_resources: recursos cuyo canonical owner es el contexto + con rights del contexto
create or replace function public.list_context_resources(p_context_actor_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
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
      'resource_id', r.id,
      'resource_type', r.resource_type,
      'display_name', r.display_name,
      'status', r.status,
      'estimated_value', r.estimated_value,
      'currency', r.currency,
      'canonical_owner_actor_id', r.canonical_owner_actor_id,
      'rights', coalesce((
        select jsonb_agg(jsonb_build_object(
          'right_id', rr.id, 'holder_actor_id', rr.holder_actor_id,
          'right_kind', rr.right_kind, 'percent', rr.percent))
        from public.resource_rights rr
        where rr.resource_id = r.id and rr.revoked_at is null and rr.expired_at is null), '[]'::jsonb)
    ) order by r.created_at desc)
    from public.resources r
    where r.archived_at is null
      and (r.canonical_owner_actor_id = p_context_actor_id
           or exists (
             select 1 from public.resource_rights rr
             where rr.resource_id = r.id and rr.holder_actor_id = p_context_actor_id
               and rr.revoked_at is null and rr.expired_at is null))
  ), '[]'::jsonb);
end; $$;

revoke all on function public.list_context_resources(uuid) from public, anon;
grant execute on function public.list_context_resources(uuid) to authenticated, service_role;

-- resource_detail
create or replace function public.resource_detail(p_resource_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_resource public.resources%rowtype;
  v_can_view boolean;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_resource from public.resources where id = p_resource_id;
  if v_resource.id is null then raise exception 'resource not found' using errcode = 'P0002'; end if;

  -- puede ver: holder de cualquier right activo, o miembro del contexto owner
  v_can_view := exists (
      select 1 from public.resource_rights rr
      where rr.resource_id = p_resource_id and rr.holder_actor_id = v_caller
        and rr.revoked_at is null and rr.expired_at is null)
    or (v_resource.canonical_owner_actor_id is not null
        and public.is_context_member(v_resource.canonical_owner_actor_id));

  if not v_can_view then
    raise exception 'not authorized to view resource %', p_resource_id using errcode = '42501';
  end if;

  return jsonb_build_object(
    'resource', to_jsonb(v_resource),
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

-- ────────────────────────────────────────────────────────────────────────────
-- 5. RLS
-- ────────────────────────────────────────────────────────────────────────────
alter table public.resources enable row level security;
alter table public.resource_rights enable row level security;
alter table public.actor_relationships enable row level security;

create policy resources_select on public.resources
  for select to authenticated
  using (
    created_by_actor_id = public.current_actor_id()
    or canonical_owner_actor_id = public.current_actor_id()
    or (canonical_owner_actor_id is not null and public.is_context_member(canonical_owner_actor_id))
    or exists (
      select 1 from public.resource_rights rr
      where rr.resource_id = resources.id and rr.holder_actor_id = public.current_actor_id()
        and rr.revoked_at is null and rr.expired_at is null)
  );

create policy rights_select on public.resource_rights
  for select to authenticated
  using (
    holder_actor_id = public.current_actor_id()
    or exists (
      select 1 from public.resources r
      where r.id = resource_rights.resource_id
        and (r.canonical_owner_actor_id = public.current_actor_id()
             or r.created_by_actor_id = public.current_actor_id()
             or (r.canonical_owner_actor_id is not null and public.is_context_member(r.canonical_owner_actor_id))))
  );

create policy relationships_select on public.actor_relationships
  for select to authenticated
  using (
    subject_actor_id = public.current_actor_id()
    or object_actor_id = public.current_actor_id()
    or (object_actor_id is not null and public.is_context_member(object_actor_id))
    or public.is_context_member(subject_actor_id)
  );

revoke all on public.resources, public.resource_rights, public.actor_relationships from anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Smoke
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_m4_resources()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_ctx uuid;
  v_result jsonb; v_res uuid; v_right uuid;
  v_caught boolean;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M4A', '+520000000007', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M4B', '+520000000008', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_context('_smoke_m4 Casa Familiar', 'collective', 'family');
  v_ctx := (v_result->>'context_actor_id')::uuid;

  -- Caso 1: create_resource en contexto → auto-OWN al contexto + canonical sync
  v_result := public.create_resource(v_ctx, 'house', '_smoke_m4 Casa Valle',
    p_estimated_value := 5000000, p_currency := 'MXN');
  v_res := (v_result->>'resource_id')::uuid;
  if not public.actor_has_right(v_ctx, v_res, 'OWN') then
    raise exception 'mvp2_m4 Caso1: auto-OWN no creado';
  end if;

  -- Caso 2: create_resource personal (self-context)
  v_result := public.create_resource(v_a, 'vehicle', '_smoke_m4 Coche', p_client_id := '_smoke_m4_car');
  if not public.actor_has_right(v_a, (v_result->>'resource_id')::uuid, 'OWN') then
    raise exception 'mvp2_m4 Caso2: personal resource sin OWN';
  end if;
  -- idempotencia por client_id
  if (public.create_resource(v_a, 'vehicle', '_smoke_m4 Coche', p_client_id := '_smoke_m4_car')->>'resource_id')::uuid
     is distinct from (v_result->>'resource_id')::uuid then
    raise exception 'mvp2_m4 Caso2: client_id no es idempotente';
  end if;

  -- Caso 3: B (no miembro) NO puede crear resource en el contexto
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_caught := false;
  begin
    perform public.create_resource(v_ctx, 'equipment', '_smoke_m4 hack');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'mvp2_m4 Caso3: no-member creó resource'; end if;

  -- Caso 4: B NO puede grant right sobre resource ajeno
  v_caught := false;
  begin
    perform public.grant_right(v_res, v_b, 'OWN', 100);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'mvp2_m4 Caso4: no autorizado pudo grant OWN'; end if;

  -- Caso 5: A (admin del contexto owner) SÍ puede grant USE a B
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.grant_right(v_res, v_b, 'USE');
  v_right := (v_result->>'right_id')::uuid;
  if not public.actor_has_right(v_b, v_res, 'USE') then
    raise exception 'mvp2_m4 Caso5: grant USE falló';
  end if;

  -- Caso 6: B (holder) puede revocar su propio right
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.revoke_right(v_right);
  if public.actor_has_right(v_b, v_res, 'USE') then
    raise exception 'mvp2_m4 Caso6: revoke falló';
  end if;

  -- Caso 7: list_context_resources + resource_detail
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.list_context_resources(v_ctx);
  if not exists (
    select 1 from jsonb_array_elements(v_result) e where (e->>'resource_id')::uuid = v_res
  ) then
    raise exception 'mvp2_m4 Caso7: resource no aparece en list_context_resources';
  end if;
  v_result := public.resource_detail(v_res);
  if (v_result->'resource'->>'id')::uuid is distinct from v_res then
    raise exception 'mvp2_m4 Caso7: resource_detail falló';
  end if;

  -- Caso 8: relationships shape (exactly-one object + whitelist)
  insert into public.actor_relationships (subject_actor_id, relationship_type, object_actor_id, created_by_actor_id)
  values (v_a, 'partner_of', v_b, v_a);
  v_caught := false;
  begin
    insert into public.actor_relationships (subject_actor_id, relationship_type, object_actor_id, object_resource_id, created_by_actor_id)
    values (v_a, 'related_to', v_b, v_res, v_a);
  exception when check_violation then v_caught := true;
  end;
  if not v_caught then raise exception 'mvp2_m4 Caso8: exactly-one constraint no aplica'; end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.actor_relationships where subject_actor_id in (v_a, v_b);
  delete from public.resource_rights where resource_id in (select id from public.resources where display_name like '_smoke_m4%');
  delete from public.resources where display_name like '_smoke_m4%';
  delete from public.context_invites where context_actor_id = v_ctx;
  delete from public.role_assignments where context_actor_id = v_ctx;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx;
  delete from public.roles where context_actor_id = v_ctx;
  delete from public.actor_memberships where context_actor_id = v_ctx;
  delete from public.actors where id = v_ctx;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_m4_resources passed (8 casos)';
end; $$;

revoke all on function public._smoke_mvp2_m4_resources() from public, anon, authenticated;

comment on function public._smoke_mvp2_m4_resources() is 'Smoke MVP2 M.4: resources, rights, auto-OWN, canonical sync, relationships, RLS.';
