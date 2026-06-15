-- R.5Z.fix.3 — context_summary().members incluye invited
--
-- Founder smoke Flow #3 (2026-06-09): "después de invitar (inviteMember /
-- createInvite) el invitado no aparece en MembersListView mientras está en
-- estado 'invited' (pre-accept). El founder no sabe si la acción funcionó
-- hasta que el invitado acepta."
--
-- Antes: context_summary().members filtraba m.membership_status = 'active',
-- excluyendo invitados.
-- Ahora: incluye invited + agrega membership_status al payload para que
-- iOS pueda renderear badge "Invitado" en Section "Pendientes de aceptar".
--
-- `members_count` permanece contando solo active (el "tamaño real" del
-- contexto). El array `members` ahora trae también los invited.

create or replace function public.context_summary(p_context_actor_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth'
as $function$
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
    'members_count', (select count(*) from public.actor_memberships
                      where context_actor_id = p_context_actor_id and membership_status = 'active'),
    'resources_count', (select count(*) from public.resources
                        where canonical_owner_actor_id = p_context_actor_id and archived_at is null),
    'pending_decisions', (select count(*) from public.decisions
                          where context_actor_id = p_context_actor_id and status = 'open'),
    'open_obligations', (select count(*) from public.obligations
                         where context_actor_id = p_context_actor_id and status = 'open'),
    -- R.5W: include is_placeholder + contact_phone + contact_email so iOS can
    -- show "Sin app" badge + optional secondary line in MembersListView.
    -- R.5Z.fix.3 (2026-06-16): include invited (pre-accept) + membership_status
    -- field so iOS can distinguish active vs invited and surface "Invitado"
    -- badge in MembersListView (founder Flow #3 smoke).
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'actor_id', m.member_actor_id, 'display_name', a.display_name,
        'membership_type', m.membership_type, 'joined_at', m.joined_at,
        'membership_status', m.membership_status,
        'is_placeholder', a.is_placeholder,
        'contact_phone', a.contact_phone,
        'contact_email', a.contact_email,
        'roles', coalesce((select jsonb_agg(r.role_key)
          from public.role_assignments ra join public.roles r on r.id = ra.role_id
          where ra.context_actor_id = m.context_actor_id and ra.member_actor_id = m.member_actor_id), '[]'::jsonb)
      ) order by m.membership_status, m.joined_at nulls last, m.created_at)
      from public.actor_memberships m join public.actors a on a.id = m.member_actor_id
      where m.context_actor_id = p_context_actor_id
        and m.membership_status in ('active', 'invited')), '[]'::jsonb),
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
            order by occurred_at desc limit 20) ae), '[]'::jsonb),
    'available_actions', public.context_available_actions(p_context_actor_id, v_caller)
  );
end; $function$;

revoke execute on function public.context_summary(uuid) from public, anon;
grant execute on function public.context_summary(uuid) to authenticated;
