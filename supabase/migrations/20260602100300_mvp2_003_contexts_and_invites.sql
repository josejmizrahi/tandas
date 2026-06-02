-- ============================================================================
-- MVP 2.0 — M.3 CONTEXTS & INVITES
-- ============================================================================
-- context_invites (D2) + activity_events (adelantada de M.10 para que todos los
-- RPCs emitan actividad desde el inicio) + RPCs: create_context / create_invite /
-- join_by_invite_code / context_candidates / context_summary + RLS + smoke.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. activity_events (adelantada — append-only)
-- ────────────────────────────────────────────────────────────────────────────
-- NOTA: audit log append-only SIN foreign keys — debe sobrevivir al borrado de
-- sus referentes y las referential actions (SET NULL/CASCADE) dispararían el
-- guard append-only. Los ids quedan como referencias débiles.
create table public.activity_events (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid,
  actor_id uuid,
  event_type text not null,
  subject_type text,
  subject_id uuid,
  resource_id uuid,
  decision_id uuid,
  obligation_id uuid,
  payload jsonb not null default '{}',
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index idx_activity_context on public.activity_events (context_actor_id, occurred_at desc);
create index idx_activity_actor on public.activity_events (actor_id, occurred_at desc);

-- Append-only guard
create or replace function public._activity_events_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'activity_events is append-only' using errcode = '42501';
end; $$;

create trigger trg_activity_append_only
  before update or delete on public.activity_events
  for each row execute function public._activity_events_append_only();

alter table public.activity_events enable row level security;
create policy activity_select on public.activity_events
  for select to authenticated
  using (
    actor_id = public.current_actor_id()
    or (context_actor_id is not null and public.is_context_member(context_actor_id))
  );
revoke all on public.activity_events from anon;

-- Helper interno de emisión
create or replace function public._emit_activity(
  p_context_actor_id uuid,
  p_actor_id uuid,
  p_event_type text,
  p_subject_type text default null,
  p_subject_id uuid default null,
  p_payload jsonb default '{}'::jsonb,
  p_resource_id uuid default null,
  p_decision_id uuid default null,
  p_obligation_id uuid default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  insert into public.activity_events
    (context_actor_id, actor_id, event_type, subject_type, subject_id, payload,
     resource_id, decision_id, obligation_id)
  values
    (p_context_actor_id, coalesce(p_actor_id, public.system_actor_id()), p_event_type,
     p_subject_type, p_subject_id, coalesce(p_payload, '{}'::jsonb),
     p_resource_id, p_decision_id, p_obligation_id)
  returning id into v_id;
  return v_id;
end; $$;

revoke all on function public._emit_activity(uuid, uuid, text, text, uuid, jsonb, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public._emit_activity(uuid, uuid, text, text, uuid, jsonb, uuid, uuid, uuid) to service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. context_invites (D2)
-- ────────────────────────────────────────────────────────────────────────────
create table public.context_invites (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  code text not null unique,
  created_by_actor_id uuid not null references public.actors(id),
  max_uses integer,
  used_count integer not null default 0,
  expires_at timestamptz,
  status text not null default 'active' check (status in ('active', 'revoked', 'exhausted')),
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_invites_context on public.context_invites (context_actor_id, status);

create trigger trg_invites_touch before update on public.context_invites
  for each row execute function public.touch_updated_at();

alter table public.context_invites enable row level security;
create policy invites_select on public.context_invites
  for select to authenticated
  using (public.is_context_member(context_actor_id));
revoke all on public.context_invites from anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. create_context
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.create_context(
  p_display_name text,
  p_actor_kind text default 'collective',
  p_actor_subtype text default 'friend_group',
  p_visibility text default 'private',
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ctx uuid;
  v_admin_role uuid;
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

  insert into public.actors (actor_kind, actor_subtype, display_name, visibility, metadata, created_by_actor_id)
  values (p_actor_kind, p_actor_subtype, btrim(p_display_name), p_visibility,
          coalesce(p_metadata, '{}'::jsonb), v_caller)
  returning id into v_ctx;

  perform public._seed_context_roles(v_ctx);
  select id into v_admin_role from public.roles where context_actor_id = v_ctx and role_key = 'admin';

  insert into public.actor_memberships (context_actor_id, member_actor_id, membership_status, membership_type, joined_at)
  values (v_ctx, v_caller, 'active', 'founder', now());

  insert into public.role_assignments (context_actor_id, member_actor_id, role_id)
  values (v_ctx, v_caller, v_admin_role);

  perform public._emit_activity(v_ctx, v_caller, 'context.created', 'actor', v_ctx,
    jsonb_build_object('display_name', btrim(p_display_name), 'actor_kind', p_actor_kind, 'actor_subtype', p_actor_subtype));

  return jsonb_build_object(
    'context_actor_id', v_ctx,
    'context', (select to_jsonb(a) from public.actors a where a.id = v_ctx)
  );
end; $$;

revoke all on function public.create_context(text, text, text, text, jsonb) from public, anon;
grant execute on function public.create_context(text, text, text, text, jsonb) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. create_invite / revoke_invite / join_by_invite_code
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.create_invite(
  p_context_actor_id uuid,
  p_max_uses integer default null,
  p_expires_at timestamptz default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_code text;
  v_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'context.invite') then
    raise exception 'not authorized to invite to context %', p_context_actor_id using errcode = '42501';
  end if;

  -- código de 8 chars (hex de uuid random — built-in, sin dependencia de pgcrypto schema)
  v_code := upper(substr(md5(gen_random_uuid()::text || clock_timestamp()::text), 1, 8));

  insert into public.context_invites (context_actor_id, code, created_by_actor_id, max_uses, expires_at)
  values (p_context_actor_id, v_code, v_caller, p_max_uses, p_expires_at)
  returning id into v_id;

  perform public._emit_activity(p_context_actor_id, v_caller, 'invite.created', 'invite', v_id,
    jsonb_build_object('max_uses', p_max_uses, 'expires_at', p_expires_at));

  return jsonb_build_object('invite_id', v_id, 'code', v_code);
end; $$;

revoke all on function public.create_invite(uuid, integer, timestamptz) from public, anon;
grant execute on function public.create_invite(uuid, integer, timestamptz) to authenticated, service_role;

create or replace function public.revoke_invite(p_invite_id uuid)
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_inv public.context_invites%rowtype;
begin
  select * into v_inv from public.context_invites where id = p_invite_id;
  if v_inv.id is null then return; end if;
  if not public.has_actor_authority(v_inv.context_actor_id, v_caller, 'context.invite') then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  update public.context_invites set status = 'revoked' where id = p_invite_id and status = 'active';
end; $$;

revoke all on function public.revoke_invite(uuid) from public, anon;
grant execute on function public.revoke_invite(uuid) to authenticated, service_role;

create or replace function public.join_by_invite_code(p_code text)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_inv public.context_invites%rowtype;
  v_member_role uuid;
  v_membership uuid;
begin
  if v_caller is null then
    raise exception 'no person actor — call ensure_person_actor first' using errcode = '28000';
  end if;

  select * into v_inv from public.context_invites
   where code = upper(btrim(p_code)) and status = 'active'
   for update;

  if v_inv.id is null then
    raise exception 'invalid or revoked invite code' using errcode = 'P0002';
  end if;
  if v_inv.expires_at is not null and v_inv.expires_at <= now() then
    raise exception 'invite code expired' using errcode = 'P0002';
  end if;
  if v_inv.max_uses is not null and v_inv.used_count >= v_inv.max_uses then
    update public.context_invites set status = 'exhausted' where id = v_inv.id;
    raise exception 'invite code exhausted' using errcode = 'P0002';
  end if;

  -- Idempotente: si ya hay membership, reactivar si estaba left/removed, no duplicar
  select id into v_membership from public.actor_memberships
   where context_actor_id = v_inv.context_actor_id and member_actor_id = v_caller and membership_type = 'member';

  if v_membership is not null then
    update public.actor_memberships
       set membership_status = 'active', joined_at = coalesce(joined_at, now()), left_at = null
     where id = v_membership and membership_status in ('left', 'removed', 'invited', 'requested');
  else
    insert into public.actor_memberships
      (context_actor_id, member_actor_id, membership_status, membership_type, invited_by_actor_id, joined_at)
    values (v_inv.context_actor_id, v_caller, 'active', 'member', v_inv.created_by_actor_id, now())
    returning id into v_membership;

    update public.context_invites set used_count = used_count + 1 where id = v_inv.id;
  end if;

  -- Role assignment de member (idempotente)
  select id into v_member_role from public.roles where context_actor_id = v_inv.context_actor_id and role_key = 'member';
  insert into public.role_assignments (context_actor_id, member_actor_id, role_id)
  values (v_inv.context_actor_id, v_caller, v_member_role)
  on conflict (context_actor_id, member_actor_id, role_id) do nothing;

  perform public._emit_activity(v_inv.context_actor_id, v_caller, 'member.joined', 'membership', v_membership,
    jsonb_build_object('via', 'invite_code'));

  return jsonb_build_object(
    'context_actor_id', v_inv.context_actor_id,
    'membership_id', v_membership,
    'context', (select to_jsonb(a) from public.actors a where a.id = v_inv.context_actor_id)
  );
end; $$;

revoke all on function public.join_by_invite_code(text) from public, anon;
grant execute on function public.join_by_invite_code(text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. context_candidates / context_summary
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.context_candidates()
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  return jsonb_build_object(
    'personal_context', (select to_jsonb(a) from public.actors a where a.id = v_caller),
    'contexts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'context_actor_id', a.id,
        'display_name', a.display_name,
        'actor_kind', a.actor_kind,
        'actor_subtype', a.actor_subtype,
        'visibility', a.visibility,
        'membership_type', am.membership_type,
        'member_count', (select count(*) from public.actor_memberships x
                         where x.context_actor_id = a.id and x.membership_status = 'active'),
        'roles', coalesce((
          select jsonb_agg(r.role_key)
            from public.role_assignments ra join public.roles r on r.id = ra.role_id
           where ra.context_actor_id = a.id and ra.member_actor_id = v_caller), '[]'::jsonb)
      ) order by a.created_at)
      from public.actor_memberships am
      join public.actors a on a.id = am.context_actor_id
      where am.member_actor_id = v_caller and am.membership_status = 'active'
        and a.archived_at is null
    ), '[]'::jsonb)
  );
end; $$;

revoke all on function public.context_candidates() from public, anon;
grant execute on function public.context_candidates() to authenticated, service_role;

-- context_summary M.3 (versión base; M.10 la extiende con resources/events/money)
create or replace function public.context_summary(p_context_actor_id uuid)
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

  return jsonb_build_object(
    'context', (select to_jsonb(a) from public.actors a where a.id = p_context_actor_id),
    'as_of', now(),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'actor_id', m.member_actor_id,
        'display_name', a.display_name,
        'membership_type', m.membership_type,
        'membership_status', m.membership_status,
        'joined_at', m.joined_at,
        'roles', coalesce((
          select jsonb_agg(r.role_key)
            from public.role_assignments ra join public.roles r on r.id = ra.role_id
           where ra.context_actor_id = m.context_actor_id and ra.member_actor_id = m.member_actor_id), '[]'::jsonb)
      ) order by m.joined_at)
      from public.actor_memberships m
      join public.actors a on a.id = m.member_actor_id
      where m.context_actor_id = p_context_actor_id and m.membership_status = 'active'
    ), '[]'::jsonb),
    'my_permissions', coalesce((
      select jsonb_agg(distinct rp.permission_key)
        from public.role_assignments ra
        join public.role_permissions rp on rp.role_id = ra.role_id and rp.allowed
       where ra.context_actor_id = p_context_actor_id and ra.member_actor_id = v_caller
    ), '[]'::jsonb),
    'recent_activity', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_type', ae.event_type, 'actor_id', ae.actor_id,
        'subject_type', ae.subject_type, 'subject_id', ae.subject_id,
        'payload', ae.payload, 'occurred_at', ae.occurred_at) order by ae.occurred_at desc)
      from (select * from public.activity_events
            where context_actor_id = p_context_actor_id
            order by occurred_at desc limit 20) ae
    ), '[]'::jsonb)
  );
end; $$;

revoke all on function public.context_summary(uuid) from public, anon;
grant execute on function public.context_summary(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. Smoke
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_m3_contexts()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_ctx uuid;
  v_result jsonb; v_code text; v_invite_id uuid;
  v_caught boolean;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M3A', '+520000000004', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M3B', '+520000000005', null);

  -- Caso 1: create_context crea actor + founder membership + admin role
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_context('_smoke_m3 Cena Semanal', 'collective', 'friend_group');
  v_ctx := (v_result->>'context_actor_id')::uuid;
  if v_ctx is null then raise exception 'mvp2_m3 Caso1: create_context failed'; end if;
  if not public.has_actor_authority(v_ctx, v_a, 'context.manage') then
    raise exception 'mvp2_m3 Caso1: founder sin context.manage';
  end if;

  -- Caso 2: create_invite por founder
  v_result := public.create_invite(v_ctx, p_max_uses := 5);
  v_code := v_result->>'code';
  v_invite_id := (v_result->>'invite_id')::uuid;
  if v_code is null or length(v_code) <> 8 then
    raise exception 'mvp2_m3 Caso2: invite code inválido: %', v_code;
  end if;

  -- Caso 3: B sin autoridad NO puede crear invite
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_caught := false;
  begin
    perform public.create_invite(v_ctx);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'mvp2_m3 Caso3: no-member pudo crear invite'; end if;

  -- Caso 4: B se une con el código → miembro activo con role member
  v_result := public.join_by_invite_code(v_code);
  if (v_result->>'context_actor_id')::uuid is distinct from v_ctx then
    raise exception 'mvp2_m3 Caso4: join failed';
  end if;
  if not public.has_actor_authority(v_ctx, v_b, 'events.view') then
    raise exception 'mvp2_m3 Caso4: B sin permissions de member';
  end if;

  -- Caso 5: join idempotente (no duplica membership)
  v_result := public.join_by_invite_code(v_code);
  if (select count(*) from public.actor_memberships
      where context_actor_id = v_ctx and member_actor_id = v_b) <> 1 then
    raise exception 'mvp2_m3 Caso5: membership duplicada';
  end if;

  -- Caso 6: context_candidates de B incluye el contexto
  v_result := public.context_candidates();
  if not exists (
    select 1 from jsonb_array_elements(v_result->'contexts') c
    where (c->>'context_actor_id')::uuid = v_ctx
  ) then
    raise exception 'mvp2_m3 Caso6: contexto no aparece en candidates de B';
  end if;

  -- Caso 7: context_summary para member + actividad registrada
  v_result := public.context_summary(v_ctx);
  if jsonb_array_length(v_result->'members') < 2 then
    raise exception 'mvp2_m3 Caso7: members incompletos';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_result->'recent_activity') e
    where e->>'event_type' = 'member.joined'
  ) then
    raise exception 'mvp2_m3 Caso7: activity member.joined no registrada';
  end if;

  -- Caso 8: invite revocado rechaza joins
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.revoke_invite(v_invite_id);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_caught := false;
  begin
    perform public.join_by_invite_code(v_code);
  exception when no_data_found or sqlstate 'P0002' then v_caught := true;
  end;
  if not v_caught then raise exception 'mvp2_m3 Caso8: invite revocado aceptó join'; end if;

  -- Caso 9: no-member NO puede ver context_summary
  perform set_config('request.jwt.claims', null, true);
  declare
    v_auth_c uuid := gen_random_uuid();
    v_c uuid;
  begin
    v_c := public._create_person_actor_for_auth_user(v_auth_c, 'Smoke M3C', '+520000000006', null);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
    v_caught := false;
    begin
      perform public.context_summary(v_ctx);
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m3 Caso9: no-member vio context_summary'; end if;
    perform set_config('request.jwt.claims', null, true);
    delete from public.person_profiles where actor_id = v_c;
    delete from public.actors where id = v_c;
    delete from auth.users where id = v_auth_c;
  end;

  -- Cleanup (activity_events es append-only — sus rows quedan como residuo aceptado)
  perform set_config('request.jwt.claims', null, true);
  delete from public.context_invites where context_actor_id = v_ctx;
  delete from public.role_assignments where context_actor_id = v_ctx;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx;
  delete from public.roles where context_actor_id = v_ctx;
  delete from public.actor_memberships where context_actor_id = v_ctx;
  delete from public.actors where id = v_ctx;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_m3_contexts passed (9 casos)';
end; $$;

revoke all on function public._smoke_mvp2_m3_contexts() from public, anon, authenticated;

comment on function public._smoke_mvp2_m3_contexts() is 'Smoke MVP2 M.3: create_context, invites, join, candidates, summary, activity.';
