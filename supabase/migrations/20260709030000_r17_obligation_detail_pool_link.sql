-- R.17 — obligation_detail expone pool_account_id (link deuda → bote).
--
-- Una obligación de aporte a bote (obligation_type='contribution',
-- status='pending_pool') no tiene pago individual: se salda al resolver el bote.
-- El frontend necesita poder navegar al bote desde el detalle del compromiso,
-- pero el link vive one-way en pool_basis_entries.paired_obligation_id.
--
-- Additive + read-only: recrea obligation_detail con el mismo shape R.2S.9 +
-- una key nueva `pool_account_id` (NULL cuando la obligación no es de un bote).

create or replace function public.obligation_detail(p_obligation_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ob public.obligations%rowtype;
  v_pool_account_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ob from public.obligations where id = p_obligation_id;
  if v_ob.id is null then raise exception 'obligation not found' using errcode = 'P0002'; end if;

  if v_caller <> v_ob.debtor_actor_id
     and v_caller <> v_ob.creditor_actor_id
     and not (v_ob.context_actor_id is not null and public.is_context_member(v_ob.context_actor_id)) then
    raise exception 'not authorized to view this obligation' using errcode = '42501';
  end if;

  -- R.17 — resolver el bote origen (si esta obligación es un aporte pareado).
  select pbe.pool_account_id into v_pool_account_id
    from public.pool_basis_entries pbe
   where pbe.paired_obligation_id = v_ob.id
   limit 1;

  return jsonb_build_object(
    'id', v_ob.id,
    'context_actor_id', v_ob.context_actor_id,
    'kind', v_ob.obligation_kind,
    'obligation_type', v_ob.obligation_type,
    'status', v_ob.status,
    'title', v_ob.title,
    'description', v_ob.description,
    'amount', v_ob.amount,
    'currency', v_ob.currency,
    'due_at', v_ob.due_at,
    'debtor_actor_id', v_ob.debtor_actor_id,
    'creditor_actor_id', v_ob.creditor_actor_id,
    'completed_at', v_ob.completed_at,
    'completed_by_actor_id', v_ob.completed_by_actor_id,
    'completion_notes', v_ob.completion_notes,
    'source_event_id', v_ob.source_event_id,
    'source_rule_id', v_ob.source_rule_id,
    'source_reservation_id', v_ob.source_reservation_id,
    'source_decision_id', v_ob.source_decision_id,
    'pool_account_id', v_pool_account_id,
    'metadata', v_ob.metadata,
    'available_actions', public.obligation_available_actions(p_obligation_id, v_caller),
    'created_at', v_ob.created_at);
end; $$;

revoke all on function public.obligation_detail(uuid) from public, anon;
grant execute on function public.obligation_detail(uuid) to authenticated, service_role;
comment on function public.obligation_detail(uuid) is
  'R.2S.9 + R.17: detalle de obligación + available_actions + pool_account_id (link a bote).';
