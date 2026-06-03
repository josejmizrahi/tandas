-- ============================================================================
-- R.2S.11 — CONTRACT SMOKE (Universal Behavior Models)
-- ============================================================================
-- Smoke integral que valida los 11 puntos del contrato R.2S sobre un mundo
-- realista del founder (Familia Mizrahi + Quimibond):
--
--   1.  Casa Valle muestra reservation actions
--   2.  Cuenta del Viaje NO muestra reservation actions
--   3.  Acciones Quimibond NO reservation y SÍ beneficiary/ownership actions
--   4.  Decision Casa Valle usa options reales
--   5.  Obligation "llevar vino" funciona sin amount/currency
--   6.  Rule aplica a reservation y money, no solo events
--   7.  Expense percentage split funciona
--   8.  Reservation conflict puede resolverse con decision option
--   9.  Activity types están catalogados
--   10. Available actions cambian según estado/permisos
--   11. Explanation engine explica visibility, obligation, reservation y decision
-- ============================================================================

create or replace function public._smoke_r2s_universal_behavior_models()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  v_fam uuid; v_quimi uuid;
  v_casa uuid; v_cuenta uuid; v_acciones uuid;
  v_detail jsonb; v_actions jsonb; v_exp jsonb;
  v_decision uuid; v_options jsonb;
  v_vino uuid;
  v_resv1 uuid; v_resv2 uuid; v_conflict uuid; v_disp_decision uuid;
  v_obs_before int; v_obs_after int;
  v_winner_opt text;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2S-master', '+5210000121');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2S-master', '+5210000122');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2S-master', '+5210000123');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_fam   := (public.create_context('Familia Mizrahi R2S', 'collective', 'family'))->>'context_actor_id';
  v_quimi := (public.create_context('Quimibond R2S', 'legal_entity', 'company'))->>'context_actor_id';
  perform public.invite_member(v_fam::uuid, a_david);
  perform public.invite_member(v_fam::uuid, a_isaac);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_fam::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.accept_invitation(v_fam::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_casa     := (public.create_resource(v_fam::uuid, 'house', 'Casa Valle'))->>'resource_id';
  v_cuenta   := (public.create_resource(v_fam::uuid, 'bank_account', 'Cuenta del Viaje'))->>'resource_id';
  v_acciones := (public.create_resource(v_quimi::uuid, 'security', 'Acciones Quimibond'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, v_fam::uuid, 'MANAGE');
  perform public.grant_right(v_casa::uuid, a_david, 'USE');
  perform public.grant_right(v_casa::uuid, a_isaac, 'USE');

  -- ════════ 1. Casa Valle muestra reservation actions ════════
  v_actions := (public.resource_detail(v_casa::uuid))->'available_actions';
  if not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'reserve_resource') then
    raise exception 'R2S CONTRACT 1: Casa Valle no muestra reserve_resource';
  end if;

  -- ════════ 2. Cuenta del Viaje NO muestra reservation actions ════════
  v_actions := (public.resource_detail(v_cuenta::uuid))->'available_actions';
  if exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'reserve_resource') then
    raise exception 'R2S CONTRACT 2: la Cuenta del Viaje muestra reserve_resource';
  end if;

  -- ════════ 3. Acciones Quimibond: NO reservation, SÍ beneficiary + ownership ════════
  v_actions := (public.resource_detail(v_acciones::uuid))->'available_actions';
  if exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'reserve_resource') then
    raise exception 'R2S CONTRACT 3: Acciones Quimibond muestra reserve_resource';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'view_beneficiaries') then
    raise exception 'R2S CONTRACT 3: Acciones Quimibond no muestra view_beneficiaries';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'view_ownership') then
    raise exception 'R2S CONTRACT 3: Acciones Quimibond no muestra view_ownership';
  end if;

  -- ════════ 4. Decision Casa Valle usa options reales ════════
  v_decision := (public.create_decision(
    v_fam::uuid, 'reservation_dispute', '¿Quién se queda con Casa Valle?',
    'Disputa de fechas', null,
    jsonb_build_object('options', jsonb_build_array('David', 'Isaac', 'Dividir fechas')),
    null, 'single_choice'))->>'decision_id';
  v_options := (public.decision_detail(v_decision::uuid))->'options';
  if jsonb_array_length(v_options) < 3 then
    raise exception 'R2S CONTRACT 4: la decisión no tiene las opciones reales (got %)', jsonb_array_length(v_options);
  end if;

  -- ════════ 10a. Available actions cambian por estado: decisión abierta → vote ════════
  v_actions := public.decision_available_actions(v_decision::uuid, a_jose);
  if not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'vote') then
    raise exception 'R2S CONTRACT 10: la decisión abierta no muestra vote';
  end if;

  -- ════════ 5. Obligation "llevar vino" sin amount/currency ════════
  v_vino := (public.create_action_obligation(
    v_fam::uuid, a_david, 'Llevar vino', 'action',
    'David trae el vino a la próxima cena'))->>'obligation_id';
  v_detail := public.obligation_detail(v_vino::uuid);
  if v_detail->>'kind' <> 'action' or v_detail->>'amount' is not null or v_detail->>'currency' is not null then
    raise exception 'R2S CONTRACT 5: la obligación de acción no debería tener amount/currency';
  end if;
  -- y su available_actions incluye mark_completed (no pay, porque no es money)
  v_actions := v_detail->'available_actions';
  if not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'mark_completed') then
    raise exception 'R2S CONTRACT 5: la obligación de acción no muestra mark_completed';
  end if;
  if exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'pay') then
    raise exception 'R2S CONTRACT 5: la obligación de acción no debería mostrar pay';
  end if;

  -- ════════ 6. Rule aplica a reservation y money ════════
  perform public.create_rule(
    v_fam::uuid, 'Cancelación tardía Casa Valle', 'reservation.cancelled',
    '{"op": "<", "field": "hours_before", "value": 48}'::jsonb,
    '[{"type": "fine", "amount": 200, "currency": "MXN", "reason": "Cancelación tardía"}]'::jsonb,
    'resource', jsonb_build_object('resource_id', v_casa::text));
  perform public.create_rule(
    v_fam::uuid, 'Gasto grande revisión', 'money.expense_recorded',
    '{"op": ">", "field": "amount", "value": 5000}'::jsonb,
    '[{"type": "create_obligation", "obligation_type": "other", "amount": 0, "reason": "Gasto grande revisión"}]'::jsonb,
    'money_transaction', '{}'::jsonb);

  -- reservation rule fires
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_resv1 := (public.request_resource_reservation(v_casa::uuid, v_fam::uuid,
                now() + interval '24 hours', now() + interval '26 hours', a_david))->>'reservation_id';
  select count(*) into v_obs_before from public.obligations where context_actor_id = v_fam::uuid and obligation_type = 'fine';
  perform public.cancel_reservation(v_resv1::uuid);
  select count(*) into v_obs_after from public.obligations where context_actor_id = v_fam::uuid and obligation_type = 'fine';
  if v_obs_after <> v_obs_before + 1 then
    raise exception 'R2S CONTRACT 6: la regla de reservación no disparó';
  end if;
  -- money rule fires
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  select count(*) into v_obs_before from public.obligations where context_actor_id = v_fam::uuid and metadata->>'reason' = 'Gasto grande revisión';
  perform public.record_expense(v_fam::uuid, 9000, 'MXN', 'Reparación', p_split_with := array[a_jose]);
  select count(*) into v_obs_after from public.obligations where context_actor_id = v_fam::uuid and metadata->>'reason' = 'Gasto grande revisión';
  if v_obs_after <> v_obs_before + 1 then
    raise exception 'R2S CONTRACT 6: la regla del dominio money no disparó';
  end if;

  -- ════════ 7. Expense percentage split ════════
  v_detail := public.record_expense(v_fam::uuid, 1000, 'MXN', 'Hotel',
    p_split_method := 'percentage',
    p_splits := jsonb_build_array(
      jsonb_build_object('actor_id', a_david, 'percent', 30),
      jsonb_build_object('actor_id', a_isaac, 'percent', 70)));
  if (select sum(amount) from public.money_splits
      where transaction_id = (v_detail->>'transaction_id')::uuid and split_role = 'debtor') <> 1000 then
    raise exception 'R2S CONTRACT 7: percentage split no suma 1000';
  end if;

  -- ════════ 8. Reservation conflict resuelto con decision option ════════
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_resv1 := (public.request_resource_reservation(v_casa::uuid, v_fam::uuid,
                now() + interval '40 days', now() + interval '44 days', a_david))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_resv2 := (public.request_resource_reservation(v_casa::uuid, v_fam::uuid,
                now() + interval '41 days', now() + interval '45 days', a_isaac))->>'reservation_id';
  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_casa::uuid and resolution_status = 'open'
     and (reservation_a_id = v_resv2 or reservation_b_id = v_resv2) limit 1;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_disp_decision := (public.resolve_reservation_conflict(v_conflict, 'requires_decision'))->>'decision_id';
  select case when (payload->'option_reservations'->>'res_a')::uuid = v_resv1 then 'res_a' else 'res_b' end
    into v_winner_opt from public.decisions where id = v_disp_decision::uuid;
  perform public.vote_decision(v_disp_decision::uuid, 'approve', v_winner_opt);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.vote_decision(v_disp_decision::uuid, 'approve', v_winner_opt);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.execute_decision(v_disp_decision::uuid);
  if (select resolution_status from public.reservation_conflicts where id = v_conflict) <> 'resolved' then
    raise exception 'R2S CONTRACT 8: la decision option no resolvió el conflicto';
  end if;

  -- ════════ 9. Activity types catalogados ════════
  if exists (
    select 1 from public.activity_events ae
    where ae.context_actor_id = v_fam::uuid
      and (ae.payload->>'uncatalogued')::boolean is true
  ) then
    raise exception 'R2S CONTRACT 9: hay activity fuera del catálogo';
  end if;

  -- ════════ 10b. Available actions cambian por estado: decisión ejecutada → sin vote ════════
  v_actions := public.decision_available_actions(v_disp_decision::uuid, a_jose);
  if exists (select 1 from jsonb_array_elements(v_actions) a where a->>'action_key' = 'vote') then
    raise exception 'R2S CONTRACT 10: una decisión ejecutada todavía muestra vote';
  end if;

  -- ════════ 11. Explanation engine ════════
  -- visibility
  v_exp := public.why_can_view_resource(a_david, v_casa::uuid);
  if not (v_exp->>'can_view')::boolean then
    raise exception 'R2S CONTRACT 11: why_can_view_resource no explica la visibilidad de David';
  end if;
  -- obligation
  v_exp := public.why_obligation_exists(v_vino::uuid);
  if v_exp is null or not (v_exp ? 'source') then
    raise exception 'R2S CONTRACT 11: why_obligation_exists no explica la obligación';
  end if;
  -- reservation
  v_exp := public.why_reservation_won(v_conflict);
  if v_exp->>'winner_reservation_id' is null then
    raise exception 'R2S CONTRACT 11: why_reservation_won no explica al ganador';
  end if;
  -- decision
  v_exp := public.why_decision_result(v_disp_decision::uuid);
  if not (v_exp ? 'tally') then
    raise exception 'R2S CONTRACT 11: why_decision_result no explica el conteo';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_quimi::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(v_fam::uuid, array[a_jose, a_david, a_isaac], array[u_jose, u_david, u_isaac]);

  raise notice 'R.2S.11 UNIVERSAL BEHAVIOR MODELS CONTRACT: PASS (11/11 puntos)';
end; $$;

revoke all on function public._smoke_r2s_universal_behavior_models() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2s_universal_behavior_models()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_r2s_universal_behavior_models(); end; $$;
revoke all on function public._smoke_mvp2_r2s_universal_behavior_models() from public, anon, authenticated;
comment on function public._smoke_mvp2_r2s_universal_behavior_models() is
  'R.2S.11: contract smoke universal de behavior models (11 puntos). Wrapper CI.';
