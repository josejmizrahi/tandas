-- R.14.C — RPC consolidada de miembros + reputación.
--
-- Friend Groups Launch P0 #1: hoy iOS computa reputación cliente-side haciendo
-- 3-4 RPC calls por miembro (listEvents + listObligations + contextSummary).
-- Para un grupo con 8 miembros = 32 round-trips al abrir Members.
--
-- Esta RPC consolida todo en 1 sola consulta SQL con métricas pre-agregadas:
--   - attended/missed/late/cancelled events (de event_participants)
--   - hosted_events (de calendar_events.host_actor_id)
--   - open_fines / open_money / settled_money (de obligations)
--   - recent_activity_count (últimos 14 días de activity_events)
--
-- iOS recibe lista pre-computada y solo presenta. El cómputo del score sigue
-- en iOS (es UI policy, no autoridad).
--
-- Permisos: caller debe ser miembro active del contexto.
-- Idempotency: STABLE (no escribe nada).

create or replace function public.list_context_members_with_reputation(
  p_context_actor_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.actor_memberships
    where context_actor_id = p_context_actor_id
      and member_actor_id = v_caller
      and membership_status = 'active'
  ) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  return coalesce((
    with members as (
      select m.member_actor_id as actor_id,
             a.display_name,
             m.membership_type
      from public.actor_memberships m
      join public.actors a on a.id = m.member_actor_id
      where m.context_actor_id = p_context_actor_id
        and m.membership_status = 'active'
    ),
    event_stats as (
      select ep.participant_actor_id as actor_id,
        count(*) filter (where ep.status = 'attended') as attended_events,
        count(*) filter (where ep.status = 'no_show')  as missed_events,
        count(*) filter (where ep.status = 'late')     as late_events,
        count(*) filter (where ep.status = 'cancelled') as cancelled_events
      from public.event_participants ep
      join public.calendar_events ce on ce.id = ep.event_id
      where ce.context_actor_id = p_context_actor_id
      group by ep.participant_actor_id
    ),
    hosted_stats as (
      select ce.host_actor_id as actor_id,
             count(*) as hosted_events
      from public.calendar_events ce
      where ce.context_actor_id = p_context_actor_id
        and ce.host_actor_id is not null
      group by ce.host_actor_id
    ),
    obligation_stats as (
      select o.debtor_actor_id as actor_id,
        count(*) filter (where o.status='open' and o.obligation_type='fine') as open_fines,
        count(*) filter (where o.status='open' and o.obligation_type in ('expense_share','iou','other')) as open_money,
        count(*) filter (where o.status='settled' and o.obligation_type in ('expense_share','iou','other')) as settled_money
      from public.obligations o
      where o.context_actor_id = p_context_actor_id
      group by o.debtor_actor_id
    ),
    activity_stats as (
      select ae.actor_id,
             count(*) as recent_activity_count
      from public.activity_events ae
      where ae.context_actor_id = p_context_actor_id
        and ae.created_at > now() - interval '14 days'
        and ae.actor_id is not null
      group by ae.actor_id
    )
    select jsonb_agg(jsonb_build_object(
      'actor_id',              m.actor_id,
      'display_name',          m.display_name,
      'membership_type',       m.membership_type,
      'attended_events',       coalesce(es.attended_events, 0),
      'missed_events',         coalesce(es.missed_events, 0),
      'late_events',           coalesce(es.late_events, 0),
      'cancelled_events',      coalesce(es.cancelled_events, 0),
      'hosted_events',         coalesce(hs.hosted_events, 0),
      'open_fines',            coalesce(os.open_fines, 0),
      'open_money',            coalesce(os.open_money, 0),
      'settled_money',         coalesce(os.settled_money, 0),
      'recent_activity_count', coalesce(acs.recent_activity_count, 0)
    ))
    from members m
    left join event_stats es      on es.actor_id  = m.actor_id
    left join hosted_stats hs     on hs.actor_id  = m.actor_id
    left join obligation_stats os on os.actor_id  = m.actor_id
    left join activity_stats acs  on acs.actor_id = m.actor_id
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.list_context_members_with_reputation(uuid) from public, anon;
grant execute on function public.list_context_members_with_reputation(uuid) to authenticated, service_role;
