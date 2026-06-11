-- ────────────────────────────────────────────────────────────────────────────
-- FE.4 (P1.1) — primer emisor real de notificaciones R.4D: `decision.opened`.
-- La infraestructura R.4D (tabla + RPCs de marcado) existía desde 2026-06-04
-- pero NADIE emitía notificaciones en producción — el centro de notificaciones
-- iOS habría nacido vacío para siempre.
--
-- Trigger AFTER INSERT en `decisions` (additivo — cubre create_decision,
-- governance y cualquier camino futuro): notifica a todos los miembros
-- activos del contexto excepto el proponente.
-- ────────────────────────────────────────────────────────────────────────────

create or replace function public._decisions_notify_opened()
returns trigger
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_member uuid;
  v_ctx_name text;
begin
  if new.context_actor_id is null then
    return new;
  end if;

  select display_name into v_ctx_name from public.actors where id = new.context_actor_id;

  for v_member in
    select am.member_actor_id
      from public.actor_memberships am
     where am.context_actor_id = new.context_actor_id
       and am.membership_status = 'active'
       and am.member_actor_id <> coalesce(new.created_by_actor_id, '00000000-0000-0000-0000-000000000000'::uuid)
  loop
    perform public.emit_notification(
      p_recipient_actor_id := v_member,
      p_notification_type  := 'decision.opened',
      p_title              := 'Nueva decisión en ' || coalesce(v_ctx_name, 'tu espacio'),
      p_body               := new.title,
      p_context_actor_id   := new.context_actor_id,
      p_target_type        := 'decision',
      p_target_id          := new.id
    );
  end loop;

  return new;
end; $$;

drop trigger if exists trg_decisions_notify_opened on public.decisions;
create trigger trg_decisions_notify_opened
  after insert on public.decisions
  for each row execute function public._decisions_notify_opened();

comment on function public._decisions_notify_opened() is
  'FE.4: emite notificación decision.opened a los miembros activos (excepto el proponente) al crear una decisión.';

-- Smoke
create or replace function public._smoke_mvp2_decision_opened_notification()
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
  v_decision uuid;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke Notif A', '+520000000930', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke Notif B', '+520000000931', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_context('_smoke_notif Cena', 'collective', 'friend_group');
  v_ctx := (v_result->>'context_actor_id')::uuid;
  perform public.invite_member(v_ctx, v_b);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.accept_invitation(v_ctx);

  -- A propone → B (miembro activo) recibe notificación; A (proponente) no.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_decision(v_ctx, 'expense_approval', '_smoke_notif ¿Compramos parrilla?');
  v_decision := (v_result->>'decision_id')::uuid;

  if not exists (
    select 1 from public.notifications
    where recipient_actor_id = v_b
      and notification_type = 'decision.opened'
      and target_id = v_decision
      and status = 'unread'
  ) then
    raise exception 'notif smoke: B no recibió decision.opened';
  end if;
  if exists (
    select 1 from public.notifications
    where recipient_actor_id = v_a and target_id = v_decision
  ) then
    raise exception 'notif smoke: el proponente no debe recibir notificación';
  end if;

  -- mark_notification_read por el recipient.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.mark_notification_read(
    (select id from public.notifications
     where recipient_actor_id = v_b and target_id = v_decision limit 1));
  if not exists (
    select 1 from public.notifications
    where recipient_actor_id = v_b and target_id = v_decision
      and status = 'read' and read_at is not null
  ) then
    raise exception 'notif smoke: mark_notification_read no marcó read/read_at';
  end if;

  -- Cleanup (activity_events append-only — residuo aceptado; notifications
  -- cascadea al borrar los actors recipients).
  perform set_config('request.jwt.claims', null, true);
  delete from public.decision_votes where decision_id = v_decision;
  delete from public.decision_options where decision_id = v_decision;
  delete from public.decisions where id = v_decision;
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

  raise notice '_smoke_mvp2_decision_opened_notification passed';
end; $$;

revoke all on function public._smoke_mvp2_decision_opened_notification() from public, anon, authenticated;

comment on function public._smoke_mvp2_decision_opened_notification() is
  'Smoke MVP2: trigger decision.opened emite a miembros activos (no al proponente) + mark_notification_read.';
