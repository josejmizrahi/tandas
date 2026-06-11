-- ────────────────────────────────────────────────────────────────────────────
-- FE.3 (V.1) — delete_my_account(): eliminación de cuenta con pseudonimización.
-- App Store 5.1.1(v) + derechos ARCO (LFPDPPP). Doctrina de la visión:
-- identidad desacoplada del acto — la identidad personal se elimina/
-- pseudonimiza; los átomos del grupo (obligations, activity, votos) se
-- conservan de forma no identificable porque otros miembros dependen de ese
-- historial. El actor row sobrevive (FKs de los átomos apuntan a él);
-- event_guests.invited_by tiene ON DELETE RESTRICT — otra razón para NO
-- borrar el actor.
-- ────────────────────────────────────────────────────────────────────────────

create or replace function public.delete_my_account()
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_id uuid := auth.uid();
  v_actor uuid;
  v_contexts uuid[];
  v_ctx uuid;
  v_memberships integer := 0;
begin
  if v_auth_id is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  select actor_id into v_actor from public.person_profiles where auth_user_id = v_auth_id;
  if v_actor is null then
    raise exception 'no person actor for caller' using errcode = '28000';
  end if;

  -- Contextos donde participa (para emitir activity después del update).
  select array_agg(distinct context_actor_id) into v_contexts
    from public.actor_memberships
   where member_actor_id = v_actor
     and membership_status in ('active', 'invited', 'paused', 'requested');

  -- 1) Pseudonimizar la identidad.
  update public.person_profiles
     set full_name      = 'Usuario eliminado',
         preferred_name = null,
         phone          = null,
         email          = null,
         avatar_url     = null,
         -- auth_user_id es NOT NULL: queda apuntando al auth user borrado
         -- (sin FK — dangla inofensivo y único; un re-registro con el mismo
         -- teléfono crea un actor nuevo porque auth.uid() ya no coincide).
         metadata       = jsonb_build_object('deleted_at', now())
   where actor_id = v_actor;

  update public.actors
     set display_name = 'Usuario eliminado',
         status = 'archived'
   where id = v_actor;

  -- 2) Salir de todos los contextos + cerrar roles.
  update public.actor_memberships
     set membership_status = 'left', left_at = now()
   where member_actor_id = v_actor
     and membership_status in ('active', 'invited', 'paused', 'requested');
  get diagnostics v_memberships = row_count;

  update public.role_assignments
     set ends_at = now()
   where member_actor_id = v_actor and ends_at is null;

  -- 3) Cerrar relaciones vivas: confianza, delegaciones, suscripciones,
  --    códigos de invitación que creó.
  update public.trust_edges
     set removed_at = now()
   where (source_actor_id = v_actor or target_actor_id = v_actor)
     and removed_at is null;

  update public.vote_delegations
     set revoked_at = now()
   where (delegator_actor_id = v_actor or delegate_actor_id = v_actor)
     and revoked_at is null;

  update public.subscriptions
     set removed_at = now()
   where subscriber_actor_id = v_actor and removed_at is null;

  update public.context_invites
     set status = 'revoked'
   where created_by_actor_id = v_actor and status = 'active';

  -- 4) Registro auditable en cada contexto (átomos append-only).
  if v_contexts is not null then
    foreach v_ctx in array v_contexts loop
      perform public._emit_activity(v_ctx, v_actor, 'member.left', 'actor', v_actor,
        jsonb_build_object('via', 'account_deletion'));
    end loop;
  end if;

  -- 5) Borrar las credenciales (sin FK hacia public.* — no cascadea).
  delete from auth.users where id = v_auth_id;

  return jsonb_build_object(
    'deleted', true,
    'actor_id', v_actor,
    'memberships_left', v_memberships
  );
end; $$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated, service_role;

comment on function public.delete_my_account() is
  'FE.3: eliminación de cuenta (App Store 5.1.1(v) + ARCO). Pseudonimiza la identidad, sale de los contextos, cierra relaciones vivas y borra auth.users; los átomos del grupo se conservan no identificables. El cliente debe signOut() después.';

-- Smoke
create or replace function public._smoke_mvp2_delete_my_account()
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
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke Del A', '+520000000920', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke Del B', '+520000000921', null);

  -- A crea contexto, invita a B; B acepta; A crea obligación de acción para B.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_context('_smoke_delete Cena', 'collective', 'friend_group');
  v_ctx := (v_result->>'context_actor_id')::uuid;
  perform public.invite_member(v_ctx, v_b);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.create_action_obligation(v_ctx, v_b, 'Llevar vino', 'action');

  -- B elimina su cuenta.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.delete_my_account();
  if not (v_result->>'deleted')::boolean then
    raise exception 'delete smoke: deleted != true';
  end if;

  perform set_config('request.jwt.claims', null, true);

  -- Identidad pseudonimizada.
  if exists (
    select 1 from public.person_profiles
    where actor_id = v_b
      and (full_name <> 'Usuario eliminado' or phone is not null or email is not null)
  ) then
    raise exception 'delete smoke: person_profiles no pseudonimizado';
  end if;
  if not exists (select 1 from public.actors where id = v_b and status = 'archived'
                   and display_name = 'Usuario eliminado') then
    raise exception 'delete smoke: actor no archivado/pseudonimizado';
  end if;

  -- Membership left + auth user borrado + átomos preservados.
  if not exists (
    select 1 from public.actor_memberships
    where context_actor_id = v_ctx and member_actor_id = v_b
      and membership_status = 'left' and left_at is not null
  ) then
    raise exception 'delete smoke: membership no quedó left';
  end if;
  if exists (select 1 from auth.users where id = v_auth_b) then
    raise exception 'delete smoke: auth.users no fue borrado';
  end if;
  if not exists (select 1 from public.obligations where debtor_actor_id = v_b) then
    raise exception 'delete smoke: la obligación del grupo se perdió (debe preservarse)';
  end if;
  if not exists (
    select 1 from public.activity_events
    where context_actor_id = v_ctx and event_type = 'membership.left' and actor_id = v_b
  ) then
    raise exception 'delete smoke: activity member.left (account_deletion) no emitida';
  end if;

  -- Cleanup (activity_events es append-only — residuo aceptado).
  delete from public.obligations where context_actor_id = v_ctx;
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

  raise notice '_smoke_mvp2_delete_my_account passed';
end; $$;

revoke all on function public._smoke_mvp2_delete_my_account() from public, anon, authenticated;

comment on function public._smoke_mvp2_delete_my_account() is
  'Smoke MVP2: delete_my_account (pseudonimización, memberships left, auth borrado, átomos preservados).';
