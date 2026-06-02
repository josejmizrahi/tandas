-- ============================================================================
-- MVP 2.0 — M.6 RESERVATIONS
-- ============================================================================
-- resource_reservations + reservation_conflicts + EXCLUDE constraint (D5) +
-- RPCs: request_resource_reservation / approve_reservation / detect_reservation_conflicts /
-- resolve_reservation_conflict + RLS + smoke.
-- Doctrina D5: requested pueden traslaparse (conflicto detectable); approved/confirmed
-- NO pueden traslaparse (EXCLUDE constraint a nivel DB).
-- ============================================================================

create table public.resource_reservations (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references public.resources(id) on delete cascade,
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  requested_by_actor_id uuid not null references public.actors(id),
  reserved_for_actor_id uuid references public.actors(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'requested' check (status in
    ('requested', 'approved', 'confirmed', 'rejected', 'cancelled', 'completed')),
  priority_score numeric,
  source_decision_id uuid,
  metadata jsonb not null default '{}',
  client_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create index idx_reservations_resource on public.resource_reservations (resource_id, starts_at);
create unique index idx_reservations_client_id on public.resource_reservations (requested_by_actor_id, client_id) where client_id is not null;

-- D5: approved/confirmed no pueden traslaparse para el mismo resource
alter table public.resource_reservations
  add constraint excl_reservations_no_overlap
  exclude using gist (
    resource_id with =,
    tstzrange(starts_at, ends_at) with &&
  ) where (status in ('approved', 'confirmed'));

create trigger trg_reservations_touch before update on public.resource_reservations
  for each row execute function public.touch_updated_at();

create table public.reservation_conflicts (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references public.resources(id) on delete cascade,
  reservation_a_id uuid not null references public.resource_reservations(id) on delete cascade,
  reservation_b_id uuid not null references public.resource_reservations(id) on delete cascade,
  conflict_type text not null default 'overlap' check (conflict_type in ('overlap', 'double_booking', 'other')),
  resolution_status text not null default 'open' check (resolution_status in ('open', 'resolved', 'dismissed')),
  recommended_winner_actor_id uuid references public.actors(id),
  source_decision_id uuid,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  unique (reservation_a_id, reservation_b_id)
);

-- ────────────────────────────────────────────────────────────────────────────
-- RPCs
-- ────────────────────────────────────────────────────────────────────────────
-- request_resource_reservation: cualquier miembro con reservations.request
create or replace function public.request_resource_reservation(
  p_resource_id uuid,
  p_context_actor_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_reserved_for_actor_id uuid default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
  v_existing uuid;
  v_conflicts integer;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'reservations.request') then
    raise exception 'not authorized to request reservations in context %', p_context_actor_id using errcode = '42501';
  end if;
  if not exists (select 1 from public.resources where id = p_resource_id and archived_at is null) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;

  if p_client_id is not null then
    select id into v_existing from public.resource_reservations
     where requested_by_actor_id = v_caller and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('reservation_id', v_existing,
        'reservation', (select to_jsonb(r) from public.resource_reservations r where r.id = v_existing));
    end if;
  end if;

  insert into public.resource_reservations
    (resource_id, context_actor_id, requested_by_actor_id, reserved_for_actor_id,
     starts_at, ends_at, metadata, client_id,
     -- priority score MVP: menor uso reciente gana → score = reservaciones completadas
     -- del solicitante sobre este recurso en los últimos 30 días (menos = mejor)
     priority_score)
  values
    (p_resource_id, p_context_actor_id, v_caller, coalesce(p_reserved_for_actor_id, v_caller),
     p_starts_at, p_ends_at, coalesce(p_metadata, '{}'::jsonb), p_client_id,
     (select count(*) from public.resource_reservations rr
       where rr.resource_id = p_resource_id
         and rr.reserved_for_actor_id = coalesce(p_reserved_for_actor_id, v_caller)
         and rr.status = 'completed'
         and rr.starts_at > now() - interval '30 days'))
  returning id into v_id;

  -- detección inmediata de conflictos con otras requested/approved/confirmed
  select count(*) into v_conflicts from public.detect_reservation_conflicts(p_resource_id);

  perform public._emit_activity(p_context_actor_id, v_caller, 'reservation.requested', 'reservation', v_id,
    jsonb_build_object('resource_id', p_resource_id, 'starts_at', p_starts_at, 'ends_at', p_ends_at,
                       'conflicts_detected', v_conflicts),
    p_resource_id := p_resource_id);

  return jsonb_build_object('reservation_id', v_id, 'conflicts_detected', v_conflicts,
    'reservation', (select to_jsonb(r) from public.resource_reservations r where r.id = v_id));
end; $$;

revoke all on function public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text) from public, anon;
grant execute on function public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text) to authenticated, service_role;

-- approve_reservation: requiere reservations.manage; el EXCLUDE constraint
-- rechaza la aprobación si traslapa con otra approved/confirmed
create or replace function public.approve_reservation(p_reservation_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_r public.resource_reservations%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_r from public.resource_reservations where id = p_reservation_id for update;
  if v_r.id is null then raise exception 'reservation not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_r.context_actor_id, v_caller, 'reservations.manage') then
    raise exception 'not authorized to approve reservations' using errcode = '42501';
  end if;
  if v_r.status <> 'requested' then
    return jsonb_build_object('reservation_id', p_reservation_id, 'status', v_r.status, 'no_op', true);
  end if;

  -- el EXCLUDE constraint lanza exclusion_violation (23P01) si traslapa
  update public.resource_reservations set status = 'approved' where id = p_reservation_id;

  perform public._emit_activity(v_r.context_actor_id, v_caller, 'reservation.approved', 'reservation', p_reservation_id,
    '{}'::jsonb, p_resource_id := v_r.resource_id);

  return jsonb_build_object('reservation_id', p_reservation_id, 'status', 'approved');
end; $$;

revoke all on function public.approve_reservation(uuid) from public, anon;
grant execute on function public.approve_reservation(uuid) to authenticated, service_role;

-- detect_reservation_conflicts: registra pares de reservaciones traslapadas (requested+)
create or replace function public.detect_reservation_conflicts(p_resource_id uuid)
returns setof public.reservation_conflicts
language plpgsql security definer set search_path = public
as $$
begin
  -- insertar conflictos nuevos (pares ordenados para unicidad)
  insert into public.reservation_conflicts
    (resource_id, reservation_a_id, reservation_b_id, conflict_type, recommended_winner_actor_id, metadata)
  select p_resource_id,
         least(a.id, b.id), greatest(a.id, b.id), 'overlap',
         -- recomendación MVP: menor uso reciente gana (priority_score más bajo)
         case when coalesce(a.priority_score, 0) <= coalesce(b.priority_score, 0)
              then (case when a.id = least(a.id, b.id) then a.reserved_for_actor_id else b.reserved_for_actor_id end)
              else (case when a.id = least(a.id, b.id) then b.reserved_for_actor_id else a.reserved_for_actor_id end)
         end,
         jsonb_build_object('detected_at', now())
    from public.resource_reservations a
    join public.resource_reservations b
      on b.resource_id = a.resource_id
     and b.id > a.id
     and tstzrange(a.starts_at, a.ends_at) && tstzrange(b.starts_at, b.ends_at)
   where a.resource_id = p_resource_id
     and a.status in ('requested', 'approved', 'confirmed')
     and b.status in ('requested', 'approved', 'confirmed')
  on conflict (reservation_a_id, reservation_b_id) do nothing;

  return query
    select * from public.reservation_conflicts
    where resource_id = p_resource_id and resolution_status = 'open';
end; $$;

revoke all on function public.detect_reservation_conflicts(uuid) from public, anon;
grant execute on function public.detect_reservation_conflicts(uuid) to authenticated, service_role;

-- resolve_reservation_conflict: el manager elige ganador; el perdedor queda rejected
create or replace function public.resolve_reservation_conflict(
  p_conflict_id uuid,
  p_winner_reservation_id uuid
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_c public.reservation_conflicts%rowtype;
  v_loser uuid;
  v_ctx uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_c from public.reservation_conflicts where id = p_conflict_id for update;
  if v_c.id is null then raise exception 'conflict not found' using errcode = 'P0002'; end if;
  if p_winner_reservation_id not in (v_c.reservation_a_id, v_c.reservation_b_id) then
    raise exception 'winner must be one of the conflicting reservations' using errcode = '22023';
  end if;

  select context_actor_id into v_ctx from public.resource_reservations where id = p_winner_reservation_id;
  if not public.has_actor_authority(v_ctx, v_caller, 'reservations.manage') then
    raise exception 'not authorized to resolve conflicts' using errcode = '42501';
  end if;
  if v_c.resolution_status <> 'open' then
    return jsonb_build_object('conflict_id', p_conflict_id, 'no_op', true);
  end if;

  v_loser := case when p_winner_reservation_id = v_c.reservation_a_id
                  then v_c.reservation_b_id else v_c.reservation_a_id end;

  -- perdedor rejected ANTES de aprobar al ganador (libera el rango para el EXCLUDE)
  update public.resource_reservations set status = 'rejected',
         metadata = metadata || jsonb_build_object('rejected_by_conflict', p_conflict_id)
   where id = v_loser and status in ('requested', 'approved');

  update public.resource_reservations set status = 'approved'
   where id = p_winner_reservation_id and status = 'requested';

  update public.reservation_conflicts
     set resolution_status = 'resolved', resolved_at = now(),
         metadata = metadata || jsonb_build_object('winner', p_winner_reservation_id, 'resolved_by', v_caller)
   where id = p_conflict_id;

  perform public._emit_activity(v_ctx, v_caller, 'reservation.conflict_resolved', 'reservation_conflict', p_conflict_id,
    jsonb_build_object('winner', p_winner_reservation_id, 'loser', v_loser),
    p_resource_id := v_c.resource_id);

  return jsonb_build_object('conflict_id', p_conflict_id, 'winner', p_winner_reservation_id, 'loser', v_loser);
end; $$;

revoke all on function public.resolve_reservation_conflict(uuid, uuid) from public, anon;
grant execute on function public.resolve_reservation_conflict(uuid, uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- RLS
-- ────────────────────────────────────────────────────────────────────────────
alter table public.resource_reservations enable row level security;
alter table public.reservation_conflicts enable row level security;

create policy reservations_select on public.resource_reservations
  for select to authenticated
  using (
    requested_by_actor_id = public.current_actor_id()
    or reserved_for_actor_id = public.current_actor_id()
    or public.is_context_member(context_actor_id)
  );

create policy conflicts_select on public.reservation_conflicts
  for select to authenticated
  using (exists (
    select 1 from public.resource_reservations r
    where r.id = reservation_conflicts.reservation_a_id and public.is_context_member(r.context_actor_id)
  ));

revoke all on public.resource_reservations, public.reservation_conflicts from anon;

-- ────────────────────────────────────────────────────────────────────────────
-- Smoke
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_m6_reservations()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_ctx uuid; v_house uuid;
  v_result jsonb; v_res_a uuid; v_res_b uuid; v_conflict uuid; v_code text;
  v_caught boolean;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M6A', '+520000000012', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M6B', '+520000000013', null);

  -- Setup: contexto familia + casa + B como member
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_m6 Familia', 'collective', 'family'))->>'context_actor_id';
  v_house := (public.create_resource(v_ctx::uuid, 'house', '_smoke_m6 Casa Lago'))->>'resource_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Caso 1: A solicita reservación del fin de semana
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.request_resource_reservation(
    v_house::uuid, v_ctx::uuid,
    now() + interval '5 days', now() + interval '7 days');
  v_res_a := (v_result->>'reservation_id')::uuid;
  if v_res_a is null then raise exception 'mvp2_m6 Caso1: request falló'; end if;

  -- Caso 2: B solicita el MISMO fin de semana → conflicto detectado
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.request_resource_reservation(
    v_house::uuid, v_ctx::uuid,
    now() + interval '6 days', now() + interval '8 days');
  v_res_b := (v_result->>'reservation_id')::uuid;
  if (v_result->>'conflicts_detected')::integer < 1 then
    raise exception 'mvp2_m6 Caso2: conflicto no detectado';
  end if;

  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_house::uuid and resolution_status = 'open' limit 1;
  if v_conflict is null then raise exception 'mvp2_m6 Caso2: conflict row no existe'; end if;

  -- Caso 3: B (sin reservations.manage) NO puede resolver el conflicto
  v_caught := false;
  begin
    perform public.resolve_reservation_conflict(v_conflict, v_res_b);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'mvp2_m6 Caso3: member resolvió conflicto sin autoridad'; end if;

  -- Caso 4: A (admin) resuelve a favor de A → B queda rejected, A approved
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.resolve_reservation_conflict(v_conflict, v_res_a);
  if not exists (select 1 from public.resource_reservations where id = v_res_a and status = 'approved') then
    raise exception 'mvp2_m6 Caso4: ganador no quedó approved';
  end if;
  if not exists (select 1 from public.resource_reservations where id = v_res_b and status = 'rejected') then
    raise exception 'mvp2_m6 Caso4: perdedor no quedó rejected';
  end if;

  -- Caso 5: EXCLUDE constraint — aprobar otra reservación traslapada explota a nivel DB
  declare
    v_res_c uuid;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
    v_res_c := (public.request_resource_reservation(
      v_house::uuid, v_ctx::uuid,
      now() + interval '5 days' + interval '12 hours', now() + interval '6 days'))->>'reservation_id';
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    v_caught := false;
    begin
      perform public.approve_reservation(v_res_c::uuid);
    exception when exclusion_violation then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m6 Caso5: EXCLUDE constraint no aplicó'; end if;
  end;

  -- Caso 6: anon sin acceso
  if has_table_privilege('anon', 'public.resource_reservations', 'SELECT')
     or has_function_privilege('anon', 'public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text)', 'EXECUTE') then
    raise exception 'mvp2_m6 Caso6: anon tiene acceso a reservaciones';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.reservation_conflicts where resource_id = v_house::uuid;
  delete from public.resource_reservations where resource_id = v_house::uuid;
  delete from public.resource_rights where resource_id = v_house::uuid;
  delete from public.resources where id = v_house::uuid;
  delete from public.context_invites where context_actor_id = v_ctx::uuid;
  delete from public.role_assignments where context_actor_id = v_ctx::uuid;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx::uuid;
  delete from public.roles where context_actor_id = v_ctx::uuid;
  delete from public.actor_memberships where context_actor_id = v_ctx::uuid;
  delete from public.actors where id = v_ctx::uuid;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_m6_reservations passed (6 casos)';
end; $$;

revoke all on function public._smoke_mvp2_m6_reservations() from public, anon, authenticated;

comment on function public._smoke_mvp2_m6_reservations() is 'Smoke MVP2 M.6: reservaciones, conflictos, resolución, EXCLUDE constraint.';
