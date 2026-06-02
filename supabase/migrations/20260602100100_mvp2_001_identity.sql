-- ============================================================================
-- MVP 2.0 — M.1 IDENTITY
-- ============================================================================
-- actors + person_profiles + system actor seed (D8) + current_actor_id() (D1)
-- + trigger auth.users → person actor + ensure_person_actor() + RLS + smoke.
--
-- D1: auth.uid() ≠ actor_id. El mapping vive SOLO en person_profiles.auth_user_id
--     y se resuelve vía current_actor_id().
-- "Empezar vacío": los 156 auth.users existentes NO se backfillean; obtienen su
-- person actor lazy vía ensure_person_actor() en su primer login del iOS nuevo.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. actors
-- ────────────────────────────────────────────────────────────────────────────
create table public.actors (
  id uuid primary key default gen_random_uuid(),
  actor_kind text not null check (actor_kind in ('person', 'collective', 'legal_entity', 'system')),
  actor_subtype text not null check (actor_subtype in
    ('person', 'friend_group', 'family', 'company', 'trust', 'trip', 'community', 'project', 'system', 'other')),
  display_name text not null,
  slug text,
  status text not null default 'active' check (status in ('active', 'inactive', 'archived')),
  visibility text not null default 'private' check (visibility in ('private', 'members', 'public')),
  metadata jsonb not null default '{}',
  created_by_actor_id uuid references public.actors(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create unique index idx_actors_slug on public.actors (slug) where slug is not null;
create index idx_actors_kind on public.actors (actor_kind, actor_subtype);

create trigger trg_actors_touch before update on public.actors
  for each row execute function public.touch_updated_at();

comment on table public.actors is 'MVP2: quién existe — person, collective, legal_entity, system.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. person_profiles
-- ────────────────────────────────────────────────────────────────────────────
create table public.person_profiles (
  actor_id uuid primary key references public.actors(id) on delete cascade,
  auth_user_id uuid unique not null,
  full_name text,
  preferred_name text,
  phone text,
  email text,
  avatar_url text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_person_profiles_touch before update on public.person_profiles
  for each row execute function public.touch_updated_at();

comment on table public.person_profiles is 'MVP2: datos de persona; auth_user_id es el único puente a auth.users (D1).';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. System actor seed (D8) + helper
-- ────────────────────────────────────────────────────────────────────────────
insert into public.actors (id, actor_kind, actor_subtype, display_name, status, visibility, metadata)
values ('00000000-0000-0000-0000-000000000001', 'system', 'system', 'Ruul System', 'active', 'private',
        '{"seed": "mvp2_m1"}'::jsonb);

create or replace function public.system_actor_id()
returns uuid
language sql
immutable
as $$ select '00000000-0000-0000-0000-000000000001'::uuid $$;

grant execute on function public.system_actor_id() to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. current_actor_id() — el ÚNICO punto de mapping auth ↔ actor (D1)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.current_actor_id()
returns uuid
language sql
stable
security definer
set search_path = public, auth
as $$
  select actor_id from public.person_profiles where auth_user_id = auth.uid();
$$;

comment on function public.current_actor_id() is
  'MVP2 D1: resuelve auth.uid() → person actor id. NULL si el caller no tiene actor todavía.';

grant execute on function public.current_actor_id() to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Creación de person actor: trigger (signups nuevos) + RPC lazy (users existentes)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._create_person_actor_for_auth_user(
  p_auth_user_id uuid,
  p_full_name text,
  p_phone text,
  p_email text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid;
begin
  -- idempotente
  select actor_id into v_actor_id from public.person_profiles where auth_user_id = p_auth_user_id;
  if v_actor_id is not null then
    return v_actor_id;
  end if;

  insert into public.actors (actor_kind, actor_subtype, display_name, created_by_actor_id, metadata)
  values ('person', 'person',
          coalesce(nullif(trim(p_full_name), ''), p_phone, p_email, 'Usuario'),
          public.system_actor_id(),
          jsonb_build_object('source', 'auth_signup'))
  returning id into v_actor_id;

  insert into public.person_profiles (actor_id, auth_user_id, full_name, phone, email)
  values (v_actor_id, p_auth_user_id, nullif(trim(p_full_name), ''), p_phone, p_email);

  return v_actor_id;
end;
$$;

-- Trigger: signups nuevos
create or replace function public._handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._create_person_actor_for_auth_user(
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.phone,
    new.email
  );
  return new;
end;
$$;

drop trigger if exists trg_mvp2_handle_new_auth_user on auth.users;
create trigger trg_mvp2_handle_new_auth_user
  after insert on auth.users
  for each row execute function public._handle_new_auth_user();

-- RPC: users existentes (los 156 pre-reset) obtienen su actor en el primer login
create or replace function public.ensure_person_actor()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid      uuid := auth.uid();
  v_actor_id uuid;
  v_user     record;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  select u.phone, u.email, u.raw_user_meta_data into v_user
    from auth.users u where u.id = v_uid;

  v_actor_id := public._create_person_actor_for_auth_user(
    v_uid,
    coalesce(v_user.raw_user_meta_data->>'full_name', v_user.raw_user_meta_data->>'name'),
    v_user.phone,
    v_user.email
  );

  return jsonb_build_object(
    'actor_id', v_actor_id,
    'actor', (select to_jsonb(a) from public.actors a where a.id = v_actor_id),
    'profile', (select to_jsonb(pp) from public.person_profiles pp where pp.actor_id = v_actor_id)
  );
end;
$$;

comment on function public.ensure_person_actor() is
  'MVP2: idempotente — crea (si no existe) y retorna el person actor del caller. iOS lo llama post-login.';

grant execute on function public.ensure_person_actor() to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. update_my_profile
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.update_my_profile(
  p_full_name text default null,
  p_preferred_name text default null,
  p_avatar_url text default null,
  p_metadata jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_actor_id uuid := public.current_actor_id();
begin
  if v_actor_id is null then
    raise exception 'no person actor for caller — call ensure_person_actor first' using errcode = '28000';
  end if;

  update public.person_profiles
     set full_name      = coalesce(p_full_name, full_name),
         preferred_name = coalesce(p_preferred_name, preferred_name),
         avatar_url     = coalesce(p_avatar_url, avatar_url),
         metadata       = case when p_metadata is not null then metadata || p_metadata else metadata end
   where actor_id = v_actor_id;

  update public.actors
     set display_name = coalesce(nullif(trim(p_preferred_name), ''), nullif(trim(p_full_name), ''), display_name)
   where id = v_actor_id;

  return jsonb_build_object(
    'actor', (select to_jsonb(a) from public.actors a where a.id = v_actor_id),
    'profile', (select to_jsonb(pp) from public.person_profiles pp where pp.actor_id = v_actor_id)
  );
end;
$$;

grant execute on function public.update_my_profile(text, text, text, jsonb) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 7. RLS (D4) — versión M.1; M.2 la extiende con visibilidad por co-membership
-- ────────────────────────────────────────────────────────────────────────────
alter table public.actors enable row level security;
alter table public.person_profiles enable row level security;

-- actors: el propio actor, actores públicos, o el system actor
create policy actors_select_m1 on public.actors
  for select to authenticated
  using (
    id = public.current_actor_id()
    or visibility = 'public'
    or actor_kind = 'system'
  );

-- person_profiles: solo el propio
create policy person_profiles_select_own on public.person_profiles
  for select to authenticated
  using (auth_user_id = (select auth.uid()));

-- Cero write policies: toda escritura via RPCs SECURITY DEFINER (D4).

-- ────────────────────────────────────────────────────────────────────────────
-- 8. Smoke
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_m1_identity()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_auth_id  uuid := gen_random_uuid();
  v_actor_id uuid;
  v_result   jsonb;
  v_count    integer;
begin
  -- Caso 1: system actor existe
  if not exists (select 1 from public.actors where id = public.system_actor_id() and actor_kind = 'system') then
    raise exception 'mvp2_m1 Caso1: system actor missing';
  end if;

  -- Caso 2: INSERT en auth.users dispara creación de person actor + profile
  insert into auth.users (id, instance_id, aud, role, phone, raw_user_meta_data, created_at, updated_at)
  values (v_auth_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          '+520000000001', '{"full_name": "Smoke M1"}'::jsonb, now(), now());

  select actor_id into v_actor_id from public.person_profiles where auth_user_id = v_auth_id;
  if v_actor_id is null then
    raise exception 'mvp2_m1 Caso2: trigger no creó person actor';
  end if;
  if not exists (select 1 from public.actors where id = v_actor_id and actor_kind = 'person' and display_name = 'Smoke M1') then
    raise exception 'mvp2_m1 Caso2: actor mal creado';
  end if;

  -- Caso 3: current_actor_id() resuelve auth → actor
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_id::text)::text, true);
  if public.current_actor_id() is distinct from v_actor_id then
    raise exception 'mvp2_m1 Caso3: current_actor_id() mismatch';
  end if;

  -- Caso 4: ensure_person_actor() es idempotente (mismo actor, no duplica)
  v_result := public.ensure_person_actor();
  if (v_result->>'actor_id')::uuid is distinct from v_actor_id then
    raise exception 'mvp2_m1 Caso4: ensure_person_actor no es idempotente';
  end if;
  select count(*) into v_count from public.person_profiles where auth_user_id = v_auth_id;
  if v_count <> 1 then
    raise exception 'mvp2_m1 Caso4: profiles duplicados (%)', v_count;
  end if;

  -- Caso 5: update_my_profile actualiza profile + display_name del actor
  v_result := public.update_my_profile(p_preferred_name := 'Smokey');
  if (v_result->'actor'->>'display_name') <> 'Smokey' then
    raise exception 'mvp2_m1 Caso5: display_name no sincronizado';
  end if;

  -- Caso 6: RLS habilitado + cero write policies + anon sin grants
  if exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname in ('actors', 'person_profiles') and not c.relrowsecurity
  ) then
    raise exception 'mvp2_m1 Caso6: RLS disabled en tabla de identidad';
  end if;
  if exists (
    select 1 from pg_policy pol join pg_class c on c.oid = pol.polrelid
    where c.relname in ('actors', 'person_profiles') and pol.polcmd in ('a', 'w', 'd')
  ) then
    raise exception 'mvp2_m1 Caso6: existe write policy directa (violación D4)';
  end if;
  if has_table_privilege('anon', 'public.actors', 'SELECT')
     or has_table_privilege('anon', 'public.person_profiles', 'SELECT') then
    raise exception 'mvp2_m1 Caso6: anon tiene SELECT en tablas de identidad';
  end if;
  if has_function_privilege('anon', 'public.ensure_person_actor()', 'EXECUTE')
     or has_function_privilege('anon', 'public.current_actor_id()', 'EXECUTE') then
    raise exception 'mvp2_m1 Caso6: anon puede ejecutar RPCs de identidad';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.person_profiles where auth_user_id = v_auth_id;
  delete from public.actors where id = v_actor_id;
  delete from auth.users where id = v_auth_id;

  raise notice '_smoke_mvp2_m1_identity passed (6 casos)';
end;
$$;

comment on function public._smoke_mvp2_m1_identity() is 'Smoke MVP2 M.1: identidad, mapping auth↔actor, RLS deny-by-default.';
