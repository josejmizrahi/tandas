-- ────────────────────────────────────────────────────────────────────────────
-- FE.1b — fix del smoke de decline_invitation: el cleanup intentaba borrar
-- activity_events, que es append-only (guard trg_activity_append_only). El
-- patrón canónico de los smokes mvp2 deja esas rows como residuo aceptado.
-- ────────────────────────────────────────────────────────────────────────────

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

  -- Cleanup (activity_events es append-only — sus rows quedan como residuo aceptado).
  perform set_config('request.jwt.claims', null, true);
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
