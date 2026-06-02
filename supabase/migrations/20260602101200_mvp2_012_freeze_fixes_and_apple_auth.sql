-- ============================================================================
-- MVP 2.0 — M.12 FREEZE FIXES (review founder) + APPLE AUTH
-- ============================================================================
-- Review de freeze del founder (6 correcciones): 1, 2, 4 ya existían; este
-- migration aplica las 3 pendientes:
--   Fix 3: unique active right incluye coalesce(scope,'')
--   Fix 5: rules.condition_tree/consequences NOT NULL con defaults
--   Fix 6: FKs en activity_events + guard append-only que permite SET NULL referencial
--
-- + APPLE AUTH: la capa identity maneja usuarios de Sign in with Apple
-- (nombre ausente en metadata, provider tracking) y el upgrade anónimo→permanente
-- (AFTER UPDATE en auth.users).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- FIX 3 — unique active right con scope
-- ────────────────────────────────────────────────────────────────────────────
-- Permite el mismo right_kind con scopes distintos (ej. USE 'weekends' + USE 'weekdays')
-- pero impide duplicados exactos activos.
drop index if exists public.idx_rights_unique_active;
create unique index idx_rights_unique_active
  on public.resource_rights (resource_id, holder_actor_id, right_kind, coalesce(scope, ''))
  where revoked_at is null and expired_at is null;

-- grant_right debe matchear por scope también (consistente con el unique nuevo):
-- sin esto, otorgar USE 'weekdays' actualizaría el USE 'weekends' existente.
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

  -- upsert/undelete scope-aware (Fix 3): un right activo por resource+holder+kind+scope
  select id into v_id from public.resource_rights
   where resource_id = p_resource_id and holder_actor_id = p_holder_actor_id
     and right_kind = p_right_kind
     and coalesce(scope, '') = coalesce(p_scope, '')
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
    jsonb_build_object('right_kind', p_right_kind, 'holder_actor_id', p_holder_actor_id, 'percent', p_percent, 'scope', p_scope),
    p_resource_id := p_resource_id);

  return jsonb_build_object('right_id', v_id);
end; $$;

revoke all on function public.grant_right(uuid, uuid, text, numeric, text, timestamptz, timestamptz, jsonb) from public, anon;
grant execute on function public.grant_right(uuid, uuid, text, numeric, text, timestamptz, timestamptz, jsonb) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- FIX 5 — rules.condition_tree / consequences NOT NULL
-- ────────────────────────────────────────────────────────────────────────────
-- Nota: consequences default '[]' (no '{}') porque semánticamente es un ARRAY de
-- consecuencias y el evaluator hace jsonb_array_elements sobre él.
-- condition_tree default '{}' = "siempre matchea" (semántica del evaluator).
update public.rules set condition_tree = '{}'::jsonb where condition_tree is null;
update public.rules set consequences = '[]'::jsonb where consequences is null;

alter table public.rules
  alter column condition_tree set default '{}'::jsonb,
  alter column condition_tree set not null,
  alter column consequences set default '[]'::jsonb,
  alter column consequences set not null;

-- create_rule debe respetar los NOT NULL (coalesce de los params nullable)
create or replace function public.create_rule(
  p_context_actor_id uuid,
  p_title text,
  p_trigger_event_type text default null,
  p_condition_tree jsonb default null,
  p_consequences jsonb default null,
  p_body text default null,
  p_rule_type text default 'automation',
  p_severity int default 1
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'rules.manage') then
    raise exception 'not authorized to create rules in context %', p_context_actor_id using errcode = '42501';
  end if;

  insert into public.rules
    (context_actor_id, title, body, rule_type, severity, trigger_event_type,
     condition_tree, consequences, created_by_actor_id)
  values
    (p_context_actor_id, btrim(p_title), p_body, p_rule_type, p_severity, p_trigger_event_type,
     coalesce(p_condition_tree, '{}'::jsonb), coalesce(p_consequences, '[]'::jsonb), v_caller)
  returning id into v_id;

  perform public._emit_activity(p_context_actor_id, v_caller, 'rule.created', 'rule', v_id,
    jsonb_build_object('title', btrim(p_title), 'trigger_event_type', p_trigger_event_type));

  return jsonb_build_object('rule_id', v_id,
    'rule', (select to_jsonb(r) from public.rules r where r.id = v_id));
end; $$;

revoke all on function public.create_rule(uuid, text, text, jsonb, jsonb, text, text, int) from public, anon;
grant execute on function public.create_rule(uuid, text, text, jsonb, jsonb, text, text, int) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- FIX 6 — FKs en activity_events + guard que permite SET NULL referencial
-- ────────────────────────────────────────────────────────────────────────────
-- Orden importa: (1) guard nuevo que permite nullear FKs, (2) limpiar huérfanos,
-- (3) agregar FKs ON DELETE SET NULL.

-- (1) Guard: DELETE siempre bloqueado; UPDATE solo permitido si únicamente
--     nullea columnas de referencia (lo que hace ON DELETE SET NULL) sin tocar
--     el contenido inmutable (event_type, payload, occurred_at, subject).
create or replace function public._activity_events_append_only()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'activity_events is append-only' using errcode = '42501';
  end if;

  if new.id = old.id
     and new.event_type = old.event_type
     and new.subject_type is not distinct from old.subject_type
     and new.subject_id is not distinct from old.subject_id
     and new.payload = old.payload
     and new.occurred_at = old.occurred_at
     and new.created_at = old.created_at
     and (new.context_actor_id is not distinct from old.context_actor_id or new.context_actor_id is null)
     and (new.actor_id is not distinct from old.actor_id or new.actor_id is null)
     and (new.resource_id is not distinct from old.resource_id or new.resource_id is null)
     and (new.decision_id is not distinct from old.decision_id or new.decision_id is null)
     and (new.obligation_id is not distinct from old.obligation_id or new.obligation_id is null) then
    return new;
  end if;

  raise exception 'activity_events is append-only (only referential SET NULL allowed)' using errcode = '42501';
end; $$;

-- (2) limpiar referencias huérfanas (de smoke cleanups previos sin FKs)
update public.activity_events set context_actor_id = null
 where context_actor_id is not null and not exists (select 1 from public.actors a where a.id = context_actor_id);
update public.activity_events set actor_id = null
 where actor_id is not null and not exists (select 1 from public.actors a where a.id = actor_id);
update public.activity_events set resource_id = null
 where resource_id is not null and not exists (select 1 from public.resources r where r.id = resource_id);
update public.activity_events set decision_id = null
 where decision_id is not null and not exists (select 1 from public.decisions d where d.id = decision_id);
update public.activity_events set obligation_id = null
 where obligation_id is not null and not exists (select 1 from public.obligations o where o.id = obligation_id);

-- (3) FKs ON DELETE SET NULL (la historia sobrevive a sus referentes)
alter table public.activity_events
  add constraint activity_events_context_fk foreign key (context_actor_id)
    references public.actors(id) on delete set null,
  add constraint activity_events_actor_fk foreign key (actor_id)
    references public.actors(id) on delete set null,
  add constraint activity_events_resource_fk foreign key (resource_id)
    references public.resources(id) on delete set null,
  add constraint activity_events_decision_fk foreign key (decision_id)
    references public.decisions(id) on delete set null,
  add constraint activity_events_obligation_fk foreign key (obligation_id)
    references public.obligations(id) on delete set null;

-- ────────────────────────────────────────────────────────────────────────────
-- APPLE AUTH — identity layer para Sign in with Apple + upgrade anónimo
-- ────────────────────────────────────────────────────────────────────────────
-- Shape real de un usuario Apple en este proyecto (verificado):
--   raw_app_meta_data:  {"provider": "apple", "providers": ["apple"]}
--   raw_user_meta_data: {iss, sub, email, provider_id, custom_claims, ...} — SIN nombre
--   email: real o @privaterelay.appleid.com; phone: null
--
-- El nombre de Apple solo está disponible en el cliente (ASAuthorization.fullName,
-- solo la 1ª vez) → iOS lo manda después vía update_my_profile.

-- (1) Creación de person actor: provider tracking + display name digno para Apple
create or replace function public._create_person_actor_for_auth_user(
  p_auth_user_id uuid,
  p_full_name text,
  p_phone text,
  p_email text
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_actor_id uuid;
  v_provider text;
  v_display text;
begin
  -- idempotente
  select actor_id into v_actor_id from public.person_profiles where auth_user_id = p_auth_user_id;
  if v_actor_id is not null then
    return v_actor_id;
  end if;

  select coalesce(u.raw_app_meta_data->>'provider', case when u.is_anonymous then 'anonymous' else null end)
    into v_provider
    from auth.users u where u.id = p_auth_user_id;

  -- display name: nombre > phone > email local-part (si no es relay de Apple) > 'Usuario'
  v_display := coalesce(
    nullif(trim(p_full_name), ''),
    p_phone,
    case
      when p_email is null then null
      when p_email like '%privaterelay.appleid.com' then null
      else split_part(p_email, '@', 1)
    end,
    'Usuario');

  insert into public.actors (actor_kind, actor_subtype, display_name, created_by_actor_id, metadata)
  values ('person', 'person', v_display, public.system_actor_id(),
          jsonb_build_object('source', 'auth_signup', 'auth_provider', coalesce(v_provider, 'unknown')))
  returning id into v_actor_id;

  insert into public.person_profiles (actor_id, auth_user_id, full_name, phone, email, metadata)
  values (v_actor_id, p_auth_user_id, nullif(trim(p_full_name), ''), p_phone, p_email,
          jsonb_build_object('auth_provider', coalesce(v_provider, 'unknown')));

  return v_actor_id;
end;
$$;

revoke all on function public._create_person_actor_for_auth_user(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public._create_person_actor_for_auth_user(uuid, text, text, text) to service_role;

-- (2) Upgrade anónimo → permanente / linking de identidades:
--     auth.users recibe UPDATE (no INSERT) → sincronizar profile + actor
create or replace function public._handle_auth_user_updated()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_provider text;
  v_actor_id uuid;
begin
  select actor_id into v_actor_id from public.person_profiles where auth_user_id = new.id;
  if v_actor_id is null then
    return new;  -- sin profile todavía (lo creará ensure_person_actor en el primer login)
  end if;

  v_name := nullif(trim(coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name')), '');
  v_provider := coalesce(new.raw_app_meta_data->>'provider',
                         case when new.is_anonymous then 'anonymous' else null end);

  update public.person_profiles pp
     set phone = coalesce(new.phone, pp.phone),
         email = coalesce(new.email, pp.email),
         full_name = coalesce(v_name, pp.full_name),
         metadata = pp.metadata || jsonb_strip_nulls(jsonb_build_object('auth_provider', v_provider))
   where pp.auth_user_id = new.id;

  -- actualizar display_name del actor solo si sigue siendo el genérico
  if v_name is not null then
    update public.actors a
       set display_name = v_name
      from public.person_profiles pp
     where pp.auth_user_id = new.id
       and a.id = pp.actor_id
       and (a.display_name = 'Usuario' or a.display_name = split_part(coalesce(new.email, ''), '@', 1));
  end if;

  return new;
end;
$$;

drop trigger if exists trg_mvp2_handle_auth_user_updated on auth.users;
create trigger trg_mvp2_handle_auth_user_updated
  after update on auth.users
  for each row execute function public._handle_auth_user_updated();

revoke all on function public._handle_auth_user_updated() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- Smoke M.12
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_m12_freeze_and_apple()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_apple uuid := gen_random_uuid();
  v_auth_anon uuid := gen_random_uuid();
  v_apple_actor uuid;
  v_anon_actor uuid;
  v_caught boolean;
  v_act_id uuid;
begin
  -- ═══ Caso 1 (Fix 3): mismo right kind con scopes distintos permitido; duplicado exacto no ═══
  declare
    v_auth_a uuid := gen_random_uuid();
    v_a uuid; v_res jsonb; v_resource uuid;
  begin
    v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M12', '+520000000024', null);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    v_res := public.create_resource(v_a, 'house', '_smoke_m12 casa');
    v_resource := (v_res->>'resource_id')::uuid;
    -- USE con dos scopes distintos: permitido
    perform public.grant_right(v_resource, v_a, 'USE', p_scope := 'weekends');
    perform public.grant_right(v_resource, v_a, 'USE', p_scope := 'weekdays');
    if (select count(*) from public.resource_rights
        where resource_id = v_resource and right_kind = 'USE' and revoked_at is null) <> 2 then
      raise exception 'mvp2_m12 Caso1: scopes distintos no permitidos';
    end if;
    -- duplicado exacto (mismo scope): el unique lo colapsa vía upsert de grant_right
    perform public.grant_right(v_resource, v_a, 'USE', p_scope := 'weekends');
    if (select count(*) from public.resource_rights
        where resource_id = v_resource and right_kind = 'USE' and revoked_at is null) <> 2 then
      raise exception 'mvp2_m12 Caso1: duplicado exacto creó tercera fila';
    end if;
    -- cleanup
    perform set_config('request.jwt.claims', null, true);
    delete from public.resource_rights where resource_id = v_resource;
    delete from public.resources where id = v_resource;
    delete from public.person_profiles where actor_id = v_a;
    delete from public.actors where id = v_a;
    delete from auth.users where id = v_auth_a;
  end;

  -- ═══ Caso 2 (Fix 5): rules NOT NULL defaults ═══
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'rules'
      and column_name in ('condition_tree', 'consequences') and is_nullable = 'YES'
  ) then
    raise exception 'mvp2_m12 Caso2: condition_tree/consequences siguen nullable';
  end if;

  -- ═══ Caso 3 (Fix 6): FKs existen + guard permite SET NULL referencial + bloquea tampering ═══
  if (select count(*) from pg_constraint
      where conrelid = 'public.activity_events'::regclass and contype = 'f') < 5 then
    raise exception 'mvp2_m12 Caso3: faltan FKs en activity_events';
  end if;
  -- el guard sigue bloqueando UPDATE de contenido
  select id into v_act_id from public.activity_events limit 1;
  if v_act_id is not null then
    v_caught := false;
    begin
      update public.activity_events set payload = '{"tampered": true}'::jsonb where id = v_act_id;
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m12 Caso3: guard permite tampering de payload'; end if;
    -- y bloquea DELETE
    v_caught := false;
    begin
      delete from public.activity_events where id = v_act_id;
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m12 Caso3: guard permite DELETE'; end if;
  end if;

  -- ═══ Caso 4 (Apple): usuario con shape real de Apple → actor con provider + nombre digno ═══
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_auth_apple, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'smoketest@privaterelay.appleid.com',
          '{"provider": "apple", "providers": ["apple"]}'::jsonb,
          '{"iss": "https://appleid.apple.com", "sub": "001234.smoke", "email": "smoketest@privaterelay.appleid.com", "email_verified": true}'::jsonb,
          now(), now());

  select actor_id into v_apple_actor from public.person_profiles where auth_user_id = v_auth_apple;
  if v_apple_actor is null then
    raise exception 'mvp2_m12 Caso4: trigger no creó actor para usuario Apple';
  end if;
  -- relay email NO debe ser el display name → 'Usuario'
  if (select display_name from public.actors where id = v_apple_actor) <> 'Usuario' then
    raise exception 'mvp2_m12 Caso4: display name de relay email incorrecto (%)',
      (select display_name from public.actors where id = v_apple_actor);
  end if;
  -- provider registrado
  if (select metadata->>'auth_provider' from public.person_profiles where actor_id = v_apple_actor) <> 'apple' then
    raise exception 'mvp2_m12 Caso4: auth_provider no registrado';
  end if;

  -- ═══ Caso 5 (Apple): iOS manda el nombre después → actor actualizado ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_apple::text)::text, true);
  perform public.update_my_profile(p_full_name := 'Jose Apple');
  if (select display_name from public.actors where id = v_apple_actor) <> 'Jose Apple' then
    raise exception 'mvp2_m12 Caso5: nombre post sign-in no actualizado';
  end if;
  perform set_config('request.jwt.claims', null, true);

  -- ═══ Caso 6 (Anonymous → upgrade): UPDATE de auth.users sincroniza el profile ═══
  insert into auth.users (id, instance_id, aud, role, is_anonymous, created_at, updated_at)
  values (v_auth_anon, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', true, now(), now());

  select actor_id into v_anon_actor from public.person_profiles where auth_user_id = v_auth_anon;
  if v_anon_actor is null then
    raise exception 'mvp2_m12 Caso6: trigger no creó actor para usuario anónimo';
  end if;
  if (select metadata->>'auth_provider' from public.person_profiles where actor_id = v_anon_actor) <> 'anonymous' then
    raise exception 'mvp2_m12 Caso6: provider anonymous no registrado';
  end if;

  -- upgrade: el usuario vincula Apple (UPDATE en auth.users)
  update auth.users
     set is_anonymous = false,
         email = 'upgraded@example.com',
         raw_app_meta_data = '{"provider": "apple", "providers": ["apple"]}'::jsonb,
         raw_user_meta_data = '{"full_name": "Ana Upgraded"}'::jsonb
   where id = v_auth_anon;

  if (select email from public.person_profiles where actor_id = v_anon_actor) <> 'upgraded@example.com' then
    raise exception 'mvp2_m12 Caso6: email no sincronizado en upgrade';
  end if;
  if (select display_name from public.actors where id = v_anon_actor) <> 'Ana Upgraded' then
    raise exception 'mvp2_m12 Caso6: display name no sincronizado en upgrade';
  end if;
  if (select metadata->>'auth_provider' from public.person_profiles where actor_id = v_anon_actor) <> 'apple' then
    raise exception 'mvp2_m12 Caso6: provider no actualizado en upgrade';
  end if;

  -- ═══ Cleanup ═══
  delete from public.person_profiles where actor_id in (v_apple_actor, v_anon_actor);
  delete from public.actors where id in (v_apple_actor, v_anon_actor);
  delete from auth.users where id in (v_auth_apple, v_auth_anon);

  raise notice '_smoke_mvp2_m12_freeze_and_apple passed (6 casos)';
end; $$;

revoke all on function public._smoke_mvp2_m12_freeze_and_apple() from public, anon, authenticated;

comment on function public._smoke_mvp2_m12_freeze_and_apple() is
  'Smoke MVP2 M.12: fixes de freeze (unique scope, rules not null, activity FKs) + Apple auth + anonymous upgrade.';
