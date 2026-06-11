-- ────────────────────────────────────────────────────────────────────────────
-- FE.1 (P0.1) — decline_invitation: el invitado puede rechazar una invitación
-- directa. Cierra el flujo C de invitaciones en ambas direcciones (hoy solo
-- existe accept_invitation → las invitaciones no deseadas quedan zombie).
--
-- 1. Nuevo estado 'declined' en actor_memberships.membership_status.
-- 2. RPC decline_invitation(p_context_actor_id) — idempotente, emite
--    'member.declined'.
-- 3. invite_member reactiva también desde 'declined' (re-invitar a quien
--    rechazó vuelve a dejar la membership en 'invited').
-- 4. Smoke _smoke_mvp2_decline_invitation.
-- ────────────────────────────────────────────────────────────────────────────

-- 1) Estado nuevo en el CHECK (constraint inline auto-nombrado por Postgres).
alter table public.actor_memberships
  drop constraint actor_memberships_membership_status_check;
alter table public.actor_memberships
  add constraint actor_memberships_membership_status_check
    check (membership_status in
      ('invited', 'requested', 'active', 'paused', 'left', 'removed', 'declined', 'banned'));

-- 2) decline_invitation
create or replace function public.decline_invitation(p_context_actor_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_membership uuid;
begin
  if v_caller is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  select id into v_membership from public.actor_memberships
   where context_actor_id = p_context_actor_id
     and member_actor_id = v_caller
     and membership_status = 'invited'
   for update;

  if v_membership is null then
    -- Idempotente: re-llamar sobre una invitación ya rechazada es no-op.
    select id into v_membership from public.actor_memberships
     where context_actor_id = p_context_actor_id
       and member_actor_id = v_caller
       and membership_status = 'declined';
    if v_membership is not null then
      return jsonb_build_object(
        'membership_id', v_membership,
        'status', 'declined',
        'already_declined', true
      );
    end if;
    raise exception 'no pending invitation for this context' using errcode = 'P0002';
  end if;

  update public.actor_memberships
     set membership_status = 'declined', left_at = now()
   where id = v_membership;

  perform public._emit_activity(p_context_actor_id, v_caller, 'membership.declined', 'membership', v_membership,
    '{}'::jsonb);

  return jsonb_build_object('membership_id', v_membership, 'status', 'declined');
end; $$;

revoke all on function public.decline_invitation(uuid) from public, anon;
grant execute on function public.decline_invitation(uuid) to authenticated, service_role;

comment on function public.decline_invitation(uuid) is
  'FE.1: el invitado rechaza una invitación directa (invited → declined). Idempotente.';

insert into public.activity_event_catalog (event_type, domain, description, expected_subject_type)
values ('membership.declined', 'membership', 'El invitado rechazó la invitación al contexto', 'membership')
on conflict (event_type) do nothing;

-- 3) invite_member: reactivar también desde 'declined' (además de left/removed).
create or replace function public.invite_member(
  p_context_actor_id uuid,
  p_member_actor_id uuid,
  p_membership_type text default 'member'
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'context.invite') then
    raise exception 'not authorized to invite to context %', p_context_actor_id using errcode = '42501';
  end if;
  if not exists (select 1 from public.actors where id = p_member_actor_id and actor_kind = 'person') then
    raise exception 'member actor not found' using errcode = 'P0002';
  end if;

  -- idempotente: si ya existe membership, retornarla (reactivar invited si estaba left/removed/declined)
  select id into v_id from public.actor_memberships
   where context_actor_id = p_context_actor_id and member_actor_id = p_member_actor_id
     and membership_type = p_membership_type;
  if v_id is not null then
    update public.actor_memberships set membership_status = 'invited', invited_by_actor_id = v_caller
     where id = v_id and membership_status in ('left', 'removed', 'declined');
  else
    insert into public.actor_memberships
      (context_actor_id, member_actor_id, membership_status, membership_type, invited_by_actor_id)
    values (p_context_actor_id, p_member_actor_id, 'invited', p_membership_type, v_caller)
    returning id into v_id;
  end if;

  perform public._emit_activity(p_context_actor_id, v_caller, 'member.invited', 'membership', v_id,
    jsonb_build_object('member_actor_id', p_member_actor_id));

  return jsonb_build_object('membership_id', v_id, 'status',
    (select membership_status from public.actor_memberships where id = v_id));
end; $$;

-- 4) Smoke
create or replace function public._smoke_mvp2_decline_invitation()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid;
  v_b uuid;
  v_ctx uuid;
  v_result jsonb;
  v_caught boolean;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke Decline A', '+520000000910', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke Decline B', '+520000000911', null);

  -- A crea contexto e invita a B directamente.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_context('_smoke_decline Cena', 'collective', 'friend_group');
  v_ctx := (v_result->>'context_actor_id')::uuid;
  v_result := public.invite_member(v_ctx, v_b);
  if (v_result->>'status') <> 'invited' then
    raise exception 'decline smoke: invite_member no dejó status invited';
  end if;

  -- B rechaza.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.decline_invitation(v_ctx);
  if (v_result->>'status') <> 'declined' then
    raise exception 'decline smoke: decline_invitation no marcó declined (got %)', v_result->>'status';
  end if;
  if not exists (
    select 1 from public.actor_memberships
    where context_actor_id = v_ctx and member_actor_id = v_b and membership_status = 'declined'
  ) then
    raise exception 'decline smoke: membership no quedó declined';
  end if;
  if not exists (
    select 1 from public.activity_events
    where context_actor_id = v_ctx and event_type = 'membership.declined' and actor_id = v_b
  ) then
    raise exception 'decline smoke: activity member.declined no emitida';
  end if;

  -- Idempotencia.
  v_result := public.decline_invitation(v_ctx);
  if not coalesce((v_result->>'already_declined')::boolean, false) then
    raise exception 'decline smoke: segunda llamada no fue no-op idempotente';
  end if;

  -- Re-invitar reactiva desde declined.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.invite_member(v_ctx, v_b);
  if (v_result->>'status') <> 'invited' then
    raise exception 'decline smoke: re-invitar no reactivó desde declined (got %)', v_result->>'status';
  end if;

  -- B acepta; decline sobre membership active debe fallar.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.accept_invitation(v_ctx);
  v_caught := false;
  begin
    perform public.decline_invitation(v_ctx);
  exception when sqlstate 'P0002' then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'decline smoke: permitió decline con membership active';
  end if;

  -- Cleanup.
  perform set_config('request.jwt.claims', null, true);
  delete from public.activity_events where context_actor_id = v_ctx;
  delete from public.context_invites where context_actor_id = v_ctx;
  delete from public.role_assignments where context_actor_id = v_ctx;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = v_ctx;
  delete from public.roles where context_actor_id = v_ctx;
  delete from public.actor_memberships where context_actor_id = v_ctx;
  delete from public.actor_relationships
    where subject_actor_id in (v_a, v_b, v_ctx) or object_actor_id in (v_a, v_b, v_ctx);
  delete from public.actors where id = v_ctx;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_decline_invitation passed';
end; $$;

revoke all on function public._smoke_mvp2_decline_invitation() from public, anon, authenticated;

comment on function public._smoke_mvp2_decline_invitation() is
  'Smoke MVP2: decline_invitation (declined, idempotencia, re-invite reactiva, active no declinable).';
