-- R.7.G — attention_inbox extension: governance_pending kind
-- Doctrina: Plans/Active/R7_GovernanceOrchestrationEngine.md (R.7 followup)
-- El proponente de un governance_action ve su propuesta en inbox mientras
-- espera aprobación. Cualquier miembro que pueda votar ya lo ve via
-- decision_vote kind existente — esto es info distinta y útil:
-- "una acción que TÚ propusiste está esperando votos".

create or replace function public.attention_inbox()
returns jsonb
language plpgsql stable security definer set search_path to public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_items jsonb := '[]'::jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  -- reservation_conflict (legacy)
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'reservation_conflict',
      'subject_id', c.id,
      'context_actor_id', r.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = r.context_actor_id),
      'title', 'Conflicto de reservación',
      'reason', 'Hay reservaciones que se solapan en un recurso donde participas',
      'cta_action_key', 'resolve_conflict',
      'cta_scope_kind', 'reservation',
      'cta_scope_id', r.id,
      'resource_id', r.resource_id,
      'occurred_at', c.created_at
    ))
    from public.reservation_conflicts c
    join public.resource_reservations r
      on r.id = c.reservation_a_id or r.id = c.reservation_b_id
    where c.resolution_status = 'open'
      and (r.requested_by_actor_id = v_caller or r.reserved_for_actor_id = v_caller)
  ), '[]'::jsonb);

  -- decision_vote
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'decision_vote',
      'subject_id', d.id,
      'context_actor_id', d.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = d.context_actor_id),
      'title', d.title,
      'reason', 'Decisión abierta donde puedes votar',
      'cta_action_key', 'vote',
      'cta_scope_kind', 'decision',
      'cta_scope_id', d.id,
      'occurred_at', d.created_at
    ))
    from public.decisions d
    where d.status = 'open'
      and public.has_actor_authority(d.context_actor_id, v_caller, 'decisions.vote')
      and not exists (
        select 1 from public.decision_votes dv
        where dv.decision_id = d.id and dv.voter_actor_id = v_caller
      )
  ), '[]'::jsonb);

  -- obligation_pay / obligation_complete
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', case when o.obligation_kind = 'money' then 'obligation_pay' else 'obligation_complete' end,
      'subject_id', o.id,
      'context_actor_id', o.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = o.context_actor_id),
      'title', coalesce(o.title, 'Compromiso pendiente'),
      'reason', case when o.obligation_kind = 'money' then 'Tienes un pago pendiente'
                     else 'Tienes un compromiso pendiente' end,
      'cta_action_key', case when o.obligation_kind = 'money' then 'pay' else 'mark_completed' end,
      'cta_scope_kind', 'obligation',
      'cta_scope_id', o.id,
      'occurred_at', o.created_at
    ))
    from public.obligations o
    where o.status = 'open' and o.debtor_actor_id = v_caller
  ), '[]'::jsonb);

  -- invitation
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'invitation',
      'subject_id', m.id,
      'context_actor_id', m.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = m.context_actor_id),
      'title', 'Invitación pendiente',
      'reason', 'Te invitaron a un contexto',
      'cta_action_key', 'accept_invitation',
      'cta_scope_kind', 'context',
      'cta_scope_id', m.context_actor_id,
      'occurred_at', m.created_at
    ))
    from public.actor_memberships m
    where m.member_actor_id = v_caller and m.membership_status = 'invited'
  ), '[]'::jsonb);

  -- settlement_open
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'settlement_open',
      'subject_id', si.id,
      'context_actor_id', sb.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = sb.context_actor_id),
      'title', 'Pago pendiente de liquidación',
      'reason', format('Debes %s %s a %s',
        si.amount, si.currency,
        (select display_name from public.actors where id = si.to_actor_id)
      ),
      'amount', si.amount,
      'currency', si.currency,
      'counterparty_name', (select display_name from public.actors where id = si.to_actor_id),
      'cta_action_key', 'mark_paid',
      'cta_scope_kind', 'settlement_item',
      'cta_scope_id', si.id,
      'occurred_at', sb.created_at
    ))
    from public.settlement_items si
    join public.settlement_batches sb on sb.id = si.settlement_batch_id
    where si.from_actor_id = v_caller
      and si.status not in ('paid', 'cancelled', 'voided')
      and sb.status not in ('finalized', 'cancelled')
  ), '[]'::jsonb);

  -- resource_conflict_direct
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'resource_conflict_direct',
      'subject_id', rc.id,
      'context_actor_id', rc.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = rc.context_actor_id),
      'title', coalesce(
        (select display_name from public.resources where id = rc.resource_id), 'Recurso'
      ) || ': conflicto',
      'reason', case rc.severity
        when 'critical' then 'Conflicto crítico en un recurso del contexto'
        when 'warning'  then 'Conflicto en un recurso del contexto'
        else 'Hay un conflicto que requiere revisión'
      end,
      'cta_action_key', 'resolve_resource_conflict',
      'cta_scope_kind', 'resource',
      'cta_scope_id', rc.resource_id,
      'resource_id', rc.resource_id,
      'occurred_at', rc.detected_at
    ))
    from public.resource_conflicts rc
    where rc.status = 'open'
      and coalesce(rc.source_type, '') != 'reservation_conflict'
      and exists (
        select 1 from public.actor_memberships m
        where m.context_actor_id = rc.context_actor_id
          and m.member_actor_id = v_caller
          and m.membership_status = 'active'
      )
  ), '[]'::jsonb);

  -- R.6.A: rule-emitted attention items
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', rai.kind,
      'subject_id', rai.id,
      'context_actor_id', rai.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = rai.context_actor_id),
      'title', rai.title,
      'reason', coalesce(rai.reason, ''),
      'cta_action_key', rai.cta_action_key,
      'cta_scope_kind', rai.cta_scope_kind,
      'cta_scope_id', rai.cta_scope_id,
      'resource_id', rai.resource_id,
      'occurred_at', rai.created_at
    ))
    from public.rule_attention_items rai
    where rai.subject_actor_id = v_caller
      and rai.status = 'open'
  ), '[]'::jsonb);

  -- R.7.G NEW: governance_pending — proponente espera aprobación de su propuesta
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'governance_pending',
      'subject_id', ga.id,
      'context_actor_id', ga.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = ga.context_actor_id),
      'title', coalesce(gac.display_name, ga.action_key),
      'reason', format('Tu propuesta de %s está esperando aprobación',
        coalesce(gac.display_name, ga.action_key)),
      'cta_action_key', 'view_decision',
      'cta_scope_kind', 'decision',
      'cta_scope_id', ga.decision_id,
      'occurred_at', ga.created_at
    ))
    from public.governance_actions ga
    left join public.governance_action_catalog gac
      on gac.action_key = public._governance_action_resolve(ga.action_key)
    join public.decisions d on d.id = ga.decision_id
    where ga.proposed_by_actor_id = v_caller
      and ga.status = 'proposed'
      and d.status = 'open'
  ), '[]'::jsonb);

  return coalesce((
    select jsonb_agg(item)
    from (
      select item
      from jsonb_array_elements(v_items) item
      order by (item->>'occurred_at')::timestamptz desc nulls last
      limit 5
    ) sorted
  ), '[]'::jsonb);
end;
$$;

comment on function public.attention_inbox() is
  'R.7.G extension — agrega kind governance_pending para que el proponente de un
governance_action vea su propuesta en inbox mientras espera aprobación. Cualquier
miembro que pueda votar ya lo ve via decision_vote kind existente. Mismo cta_scope_kind
=decision + cta_scope_id=decision_id -> iOS reusa el destination .decision sin nuevo
sheet handler.';
