-- ============================================================================
-- R.2-1 — BEHAVIOR RPCs (schema congelado: cero tablas nuevas)
-- ============================================================================
-- Completa los RPCs de comportamiento que faltan para los 4 escenarios R.2:
--   R.2A: context_summary con counts
--   R.2B: invite_member / accept_invitation / remove_member / leave_context
--   R.2C: update_resource / archive_resource
--   R.2F: cancel_reservation
--   R.2G: vote_decision con soporte de opciones (via jsonb, sin tablas)
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- R.2A — context_summary: agregar counts (members_count, resources_count,
--        pending_decisions, open_obligations) manteniendo las secciones existentes
-- ────────────────────────────────────────────────────────────────────────────
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
    -- R.2A counts
    'members_count', (select count(*) from public.actor_memberships
                      where context_actor_id = p_context_actor_id and membership_status = 'active'),
    'resources_count', (select count(*) from public.resources
                        where canonical_owner_actor_id = p_context_actor_id and archived_at is null),
    'pending_decisions', (select count(*) from public.decisions
                          where context_actor_id = p_context_actor_id and status = 'open'),
    'open_obligations', (select count(*) from public.obligations
                         where context_actor_id = p_context_actor_id and status = 'open'),
    -- secciones detalladas (MVP 2.0)
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'actor_id', m.member_actor_id, 'display_name', a.display_name,
        'membership_type', m.membership_type, 'joined_at', m.joined_at,
        'roles', coalesce((select jsonb_agg(r.role_key)
          from public.role_assignments ra join public.roles r on r.id = ra.role_id
          where ra.context_actor_id = m.context_actor_id and ra.member_actor_id = m.member_actor_id), '[]'::jsonb)
      ) order by m.joined_at)
      from public.actor_memberships m join public.actors a on a.id = m.member_actor_id
      where m.context_actor_id = p_context_actor_id and m.membership_status = 'active'), '[]'::jsonb),
    'my_permissions', coalesce((
      select jsonb_agg(distinct rp.permission_key)
        from public.role_assignments ra
        join public.role_permissions rp on rp.role_id = ra.role_id and rp.allowed
       where ra.context_actor_id = p_context_actor_id and ra.member_actor_id = v_caller), '[]'::jsonb),
    'resources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'resource_id', r.id, 'display_name', r.display_name, 'resource_type', r.resource_type,
        'estimated_value', r.estimated_value, 'currency', r.currency) order by r.created_at desc)
      from (select * from public.resources
            where canonical_owner_actor_id = p_context_actor_id and archived_at is null
            order by created_at desc limit 20) r), '[]'::jsonb),
    'upcoming_events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_id', e.id, 'title', e.title, 'event_type', e.event_type,
        'starts_at', e.starts_at, 'host_actor_id', e.host_actor_id, 'status', e.status) order by e.starts_at)
      from (select * from public.calendar_events
            where context_actor_id = p_context_actor_id and status = 'scheduled'
              and (starts_at is null or starts_at > now() - interval '1 day')
            order by starts_at limit 10) e), '[]'::jsonb),
    'open_decisions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'decision_id', d.id, 'title', d.title, 'decision_type', d.decision_type,
        'payload', d.payload, 'created_at', d.created_at) order by d.created_at desc)
      from (select * from public.decisions
            where context_actor_id = p_context_actor_id and status = 'open'
            order by created_at desc limit 10) d), '[]'::jsonb),
    'money', jsonb_build_object(
      'open_obligations', coalesce((
        select jsonb_agg(jsonb_build_object(
          'obligation_id', o.id, 'debtor_actor_id', o.debtor_actor_id,
          'creditor_actor_id', o.creditor_actor_id, 'obligation_type', o.obligation_type,
          'amount', o.amount, 'currency', o.currency) order by o.created_at desc)
        from (select * from public.obligations
              where context_actor_id = p_context_actor_id and status = 'open'
              order by created_at desc limit 20) o), '[]'::jsonb),
      'my_balance', coalesce((
        select sum(case when creditor_actor_id = v_caller then amount
                        when debtor_actor_id = v_caller then -amount
                        else 0 end)
        from public.obligations
        where context_actor_id = p_context_actor_id and status = 'open'), 0)),
    'active_rules', coalesce((
      select jsonb_agg(jsonb_build_object(
        'rule_id', r.id, 'title', r.title, 'trigger_event_type', r.trigger_event_type) order by r.created_at)
      from public.rules r
      where r.context_actor_id = p_context_actor_id and r.status = 'active'), '[]'::jsonb),
    'recent_activity', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_type', ae.event_type, 'actor_id', ae.actor_id, 'payload', ae.payload,
        'occurred_at', ae.occurred_at) order by ae.occurred_at desc)
      from (select * from public.activity_events
            where context_actor_id = p_context_actor_id
            order by occurred_at desc limit 20) ae), '[]'::jsonb)
  );
end; $$;

-- ────────────────────────────────────────────────────────────────────────────
-- R.2B — invite_member / accept_invitation / remove_member / leave_context
-- ────────────────────────────────────────────────────────────────────────────
-- invite_member: invitación directa a un actor conocido (status 'invited')
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

  -- idempotente: si ya existe membership, retornarla (reactivar invited si estaba left/removed)
  select id into v_id from public.actor_memberships
   where context_actor_id = p_context_actor_id and member_actor_id = p_member_actor_id
     and membership_type = p_membership_type;
  if v_id is not null then
    update public.actor_memberships set membership_status = 'invited', invited_by_actor_id = v_caller
     where id = v_id and membership_status in ('left', 'removed');
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

revoke all on function public.invite_member(uuid, uuid, text) from public, anon;
grant execute on function public.invite_member(uuid, uuid, text) to authenticated, service_role;

-- accept_invitation: el invitado acepta → active + role member
create or replace function public.accept_invitation(p_context_actor_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_membership uuid;
  v_member_role uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select id into v_membership from public.actor_memberships
   where context_actor_id = p_context_actor_id and member_actor_id = v_caller
     and membership_status = 'invited';
  if v_membership is null then
    -- idempotente: ya activa
    select id into v_membership from public.actor_memberships
     where context_actor_id = p_context_actor_id and member_actor_id = v_caller
       and membership_status = 'active';
    if v_membership is not null then
      return jsonb_build_object('membership_id', v_membership, 'status', 'active', 'already_member', true);
    end if;
    raise exception 'no pending invitation for this context' using errcode = 'P0002';
  end if;

  update public.actor_memberships
     set membership_status = 'active', joined_at = now()
   where id = v_membership;

  -- role member (idempotente)
  select id into v_member_role from public.roles
   where context_actor_id = p_context_actor_id and role_key = 'member';
  if v_member_role is not null then
    insert into public.role_assignments (context_actor_id, member_actor_id, role_id)
    values (p_context_actor_id, v_caller, v_member_role)
    on conflict (context_actor_id, member_actor_id, role_id) do nothing;
  end if;

  perform public._emit_activity(p_context_actor_id, v_caller, 'member.joined', 'membership', v_membership,
    jsonb_build_object('via', 'invitation'));

  return jsonb_build_object('membership_id', v_membership, 'status', 'active');
end; $$;

revoke all on function public.accept_invitation(uuid) from public, anon;
grant execute on function public.accept_invitation(uuid) to authenticated, service_role;

-- remove_member: requiere members.manage; no puedes removerte a ti mismo (usa leave_context)
create or replace function public.remove_member(
  p_context_actor_id uuid,
  p_member_actor_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'members.manage') then
    raise exception 'not authorized to remove members' using errcode = '42501';
  end if;
  if p_member_actor_id = v_caller then
    raise exception 'use leave_context to remove yourself' using errcode = '22023';
  end if;

  update public.actor_memberships
     set membership_status = 'removed', left_at = now(),
         metadata = metadata || jsonb_strip_nulls(jsonb_build_object('removed_by', v_caller, 'reason', p_reason))
   where context_actor_id = p_context_actor_id and member_actor_id = p_member_actor_id
     and membership_status in ('active', 'invited', 'paused');

  -- terminar role assignments
  update public.role_assignments set ends_at = now()
   where context_actor_id = p_context_actor_id and member_actor_id = p_member_actor_id and ends_at is null;

  perform public._emit_activity(p_context_actor_id, v_caller, 'member.removed', 'actor', p_member_actor_id,
    jsonb_strip_nulls(jsonb_build_object('reason', p_reason)));

  return jsonb_build_object('removed', true);
end; $$;

revoke all on function public.remove_member(uuid, uuid, text) from public, anon;
grant execute on function public.remove_member(uuid, uuid, text) to authenticated, service_role;

-- leave_context: salirse voluntariamente
create or replace function public.leave_context(p_context_actor_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  update public.actor_memberships
     set membership_status = 'left', left_at = now()
   where context_actor_id = p_context_actor_id and member_actor_id = v_caller
     and membership_status in ('active', 'invited', 'paused');

  if not found then
    return jsonb_build_object('left', false, 'message', 'not an active member');
  end if;

  update public.role_assignments set ends_at = now()
   where context_actor_id = p_context_actor_id and member_actor_id = v_caller and ends_at is null;

  perform public._emit_activity(p_context_actor_id, v_caller, 'member.left', 'actor', v_caller, '{}'::jsonb);

  return jsonb_build_object('left', true);
end; $$;

revoke all on function public.leave_context(uuid) from public, anon;
grant execute on function public.leave_context(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- R.2C — update_resource / archive_resource
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.update_resource(
  p_resource_id uuid,
  p_display_name text default null,
  p_description text default null,
  p_estimated_value numeric default null,
  p_currency text default null,
  p_metadata jsonb default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_r public.resources%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_r from public.resources where id = p_resource_id;
  if v_r.id is null then raise exception 'resource not found' using errcode = 'P0002'; end if;

  if not (
    public.actor_has_right(v_caller, p_resource_id, 'OWN')
    or public.actor_has_right(v_caller, p_resource_id, 'MANAGE')
    or (v_r.canonical_owner_actor_id is not null
        and public.has_actor_authority(v_r.canonical_owner_actor_id, v_caller, 'resources.manage'))
  ) then
    raise exception 'not authorized to update resource %', p_resource_id using errcode = '42501';
  end if;

  update public.resources
     set display_name = coalesce(btrim(p_display_name), display_name),
         description = coalesce(p_description, description),
         estimated_value = coalesce(p_estimated_value, estimated_value),
         currency = coalesce(p_currency, currency),
         metadata = case when p_metadata is not null then metadata || p_metadata else metadata end
   where id = p_resource_id;

  perform public._emit_activity(v_r.canonical_owner_actor_id, v_caller, 'resource.updated', 'resource', p_resource_id,
    '{}'::jsonb, p_resource_id := p_resource_id);

  return jsonb_build_object('resource',
    (select to_jsonb(r) from public.resources r where r.id = p_resource_id));
end; $$;

revoke all on function public.update_resource(uuid, text, text, numeric, text, jsonb) from public, anon;
grant execute on function public.update_resource(uuid, text, text, numeric, text, jsonb) to authenticated, service_role;

create or replace function public.archive_resource(p_resource_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_r public.resources%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_r from public.resources where id = p_resource_id;
  if v_r.id is null then raise exception 'resource not found' using errcode = 'P0002'; end if;
  if v_r.archived_at is not null then
    return jsonb_build_object('archived', true, 'already_archived', true);
  end if;

  if not (
    public.actor_has_right(v_caller, p_resource_id, 'OWN')
    or (v_r.canonical_owner_actor_id is not null
        and public.has_actor_authority(v_r.canonical_owner_actor_id, v_caller, 'resources.manage'))
  ) then
    raise exception 'not authorized to archive resource %', p_resource_id using errcode = '42501';
  end if;

  update public.resources set archived_at = now(), status = 'archived' where id = p_resource_id;

  perform public._emit_activity(v_r.canonical_owner_actor_id, v_caller, 'resource.archived', 'resource', p_resource_id,
    '{}'::jsonb, p_resource_id := p_resource_id);

  return jsonb_build_object('archived', true);
end; $$;

revoke all on function public.archive_resource(uuid) from public, anon;
grant execute on function public.archive_resource(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- R.2F — cancel_reservation
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.cancel_reservation(p_reservation_id uuid)
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
  if v_r.status in ('cancelled', 'completed', 'rejected') then
    return jsonb_build_object('reservation_id', p_reservation_id, 'status', v_r.status, 'no_op', true);
  end if;

  -- el solicitante, el beneficiario, o quien tenga reservations.manage
  if not (
    v_r.requested_by_actor_id = v_caller
    or v_r.reserved_for_actor_id = v_caller
    or public.has_actor_authority(v_r.context_actor_id, v_caller, 'reservations.manage')
  ) then
    raise exception 'not authorized to cancel reservation %', p_reservation_id using errcode = '42501';
  end if;

  update public.resource_reservations set status = 'cancelled' where id = p_reservation_id;

  -- cerrar conflictos abiertos que involucren esta reservación
  update public.reservation_conflicts
     set resolution_status = 'dismissed', resolved_at = now(),
         metadata = metadata || jsonb_build_object('dismissed_reason', 'reservation_cancelled')
   where (reservation_a_id = p_reservation_id or reservation_b_id = p_reservation_id)
     and resolution_status = 'open';

  perform public._emit_activity(v_r.context_actor_id, v_caller, 'reservation.cancelled', 'reservation', p_reservation_id,
    '{}'::jsonb, p_resource_id := v_r.resource_id);

  return jsonb_build_object('reservation_id', p_reservation_id, 'status', 'cancelled');
end; $$;

revoke all on function public.cancel_reservation(uuid) from public, anon;
grant execute on function public.cancel_reservation(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- R.2G — vote_decision con opciones (via jsonb; cero tablas nuevas)
-- ────────────────────────────────────────────────────────────────────────────
-- decisions.payload.options = ["David", "Isaac"] (o actor ids)
-- vote_decision acepta p_option; el voto se guarda como 'approve' + metadata.option
-- El tally por opción vive en decisions.result.option_tally
-- Cuando todos los miembros votaron O una opción tiene mayoría absoluta → approved
create or replace function public.vote_decision(
  p_decision_id uuid,
  p_vote text,
  p_option text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_members numeric;
  v_approve numeric;
  v_reject numeric;
  v_total_votes numeric;
  v_new_status text;
  v_option_tally jsonb;
  v_winning_option text;
  v_winning_votes numeric;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if p_vote not in ('approve', 'reject', 'abstain') then
    raise exception 'invalid vote: %', p_vote using errcode = '22023';
  end if;

  select * into v_d from public.decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.vote') then
    raise exception 'not authorized to vote in context %', v_d.context_actor_id using errcode = '42501';
  end if;
  if v_d.status <> 'open' then
    raise exception 'decision is %', v_d.status using errcode = '22023';
  end if;
  if v_d.closes_at is not null and v_d.closes_at <= now() then
    raise exception 'voting window closed' using errcode = '22023';
  end if;

  -- si la decisión tiene opciones, el voto debe traer una opción válida
  if v_d.payload ? 'options' and p_option is not null then
    if not (v_d.payload->'options') ? p_option then
      raise exception 'invalid option: % (valid: %)', p_option, v_d.payload->'options' using errcode = '22023';
    end if;
  end if;

  insert into public.decision_votes (decision_id, voter_actor_id, vote, metadata)
  values (p_decision_id, v_caller, p_vote,
          jsonb_strip_nulls(jsonb_build_object('option', p_option)))
  on conflict (decision_id, voter_actor_id)
  do update set vote = excluded.vote, voted_at = now(),
                metadata = excluded.metadata;

  select count(*) into v_members from public.actor_memberships
   where context_actor_id = v_d.context_actor_id and membership_status = 'active';
  v_members := greatest(v_members, 1);

  select coalesce(sum(weight) filter (where vote = 'approve'), 0),
         coalesce(sum(weight) filter (where vote = 'reject'), 0),
         coalesce(sum(weight), 0)
    into v_approve, v_reject, v_total_votes
    from public.decision_votes where decision_id = p_decision_id;

  -- tally por opción (si hay opciones)
  if v_d.payload ? 'options' then
    select coalesce(jsonb_object_agg(opt, votes), '{}'::jsonb) into v_option_tally
    from (
      select dv.metadata->>'option' as opt, sum(dv.weight) as votes
        from public.decision_votes dv
       where dv.decision_id = p_decision_id and dv.metadata->>'option' is not null
       group by dv.metadata->>'option'
    ) t;

    select opt, votes into v_winning_option, v_winning_votes
    from (
      select dv.metadata->>'option' as opt, sum(dv.weight) as votes
        from public.decision_votes dv
       where dv.decision_id = p_decision_id and dv.metadata->>'option' is not null
       group by dv.metadata->>'option'
       order by sum(dv.weight) desc limit 1
    ) w;

    -- decisión por opciones: gana cuando una opción tiene mayoría absoluta
    -- O todos los miembros ya votaron (gana la de más votos)
    if v_winning_votes > v_members / 2.0
       or (v_total_votes >= v_members and v_winning_votes > 0) then
      v_new_status := 'approved';
    end if;
  else
    -- decisión approve/reject clásica
    if v_approve > v_members / 2.0 then
      v_new_status := 'approved';
    elsif v_reject >= v_members / 2.0 and v_reject > 0 and (v_members - v_reject) < v_members / 2.0 then
      v_new_status := 'rejected';
    end if;
  end if;

  if v_new_status is not null then
    update public.decisions
       set status = v_new_status, decided_at = now(),
           result = jsonb_strip_nulls(jsonb_build_object(
             'approve', v_approve, 'reject', v_reject, 'members', v_members,
             'option_tally', v_option_tally, 'winning_option', v_winning_option))
     where id = p_decision_id;

    perform public._emit_activity(v_d.context_actor_id, v_caller, 'decision.' || v_new_status, 'decision', p_decision_id,
      jsonb_strip_nulls(jsonb_build_object('winning_option', v_winning_option)),
      p_decision_id := p_decision_id);
  end if;

  return jsonb_build_object(
    'decision_id', p_decision_id, 'my_vote', p_vote, 'my_option', p_option,
    'status', coalesce(v_new_status, 'open'),
    'tally', jsonb_strip_nulls(jsonb_build_object(
      'approve', v_approve, 'reject', v_reject, 'members', v_members,
      'option_tally', v_option_tally)));
end; $$;

-- la firma vieja (2 args) sigue funcionando: p_option default null
drop function if exists public.vote_decision(uuid, text);

revoke all on function public.vote_decision(uuid, text, text) from public, anon;
grant execute on function public.vote_decision(uuid, text, text) to authenticated, service_role;
