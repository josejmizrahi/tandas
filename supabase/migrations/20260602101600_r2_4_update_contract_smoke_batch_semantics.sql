-- ============================================================================
-- R.2-4 — Actualizar _smoke_mvp2_contract a la semántica de cierre por-batch
-- ============================================================================
-- R.2-3 cambió el cierre de obligations: ya no es por-item sino al finalizar el
-- batch completo (semántica de acuerdo de neteo). El contract smoke pagaba solo
-- 1 de los 2 items de Linda y esperaba cierre inmediato. Fix: pagar TODOS los
-- items (el flujo real) y verificar el cierre al finalizar el batch.
-- ============================================================================

create or replace function public._smoke_mvp2_contract()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_linda uuid := gen_random_uuid();
  v_jose uuid; v_linda uuid; v_ctx uuid;
  v_result jsonb; v_code text; v_event uuid; v_next uuid;
  v_batch uuid; v_summary jsonb;
  v_total_closed integer := 0;
  r record;
begin
  -- ═══ 1-2. Identity + contexto ═══
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'Jose Contract', '+520000000022', null);
  v_linda := public._create_person_actor_for_auth_user(v_auth_linda, 'Linda Contract', '+520000000023', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_ctx := (public.create_context('_contract Cena de los Jueves', 'collective', 'friend_group'))->>'context_actor_id';

  -- ═══ 3. Linda se une ═══
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- ═══ 4. Regla de multa ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  perform public.create_rule(v_ctx::uuid, '_contract Multa por tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": ">", "field": "minutes_late", "value": 15}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);

  -- ═══ 5. Cena recurrente ═══
  v_event := (public.create_calendar_event(v_ctx::uuid, '_contract Cena Jueves', 'dinner',
    p_starts_at := now() - interval '30 minutes',
    p_recurrence_rule := 'weekly', p_host_actor_id := v_jose))->>'event_id';

  -- ═══ 6. Linda check-in tarde → multa ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  v_result := public.check_in_participant(v_event::uuid);
  if (v_result->'rules'->>'rules_matched')::integer < 1 then
    raise exception 'contract: multa automática por tarde no se generó';
  end if;

  -- ═══ 7. Gasto con split ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_result := public.record_expense(v_ctx::uuid, 600, 'MXN', '_contract Cena sushi', p_event_id := v_event::uuid);
  if (v_result->>'share_per_person')::numeric <> 300 then
    raise exception 'contract: split de gasto incorrecto';
  end if;

  -- ═══ 8. Cierre + recurrencia + host rotation ═══
  v_result := public.close_event(v_event::uuid);
  v_next := (v_result->>'next_event_id')::uuid;
  if v_next is null or (v_result->>'next_host_actor_id')::uuid is distinct from v_linda then
    raise exception 'contract: recurrencia/rotación de host falló';
  end if;

  -- ═══ 9. Settlement ═══
  v_result := public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  if v_batch is null then raise exception 'contract: settlement batch no generado'; end if;
  if (select sum((i->>'amount')::numeric) from jsonb_array_elements(v_result->'items') i
      where (i->>'from')::uuid = v_linda) <> 400 then
    raise exception 'contract: neteo de Linda incorrecto (esperaba 400)';
  end if;

  -- ═══ 10. Linda paga TODOS sus items (R.2-3: el batch cierra al completarse) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  for r in select id from public.settlement_items
            where settlement_batch_id = v_batch and from_actor_id = v_linda loop
    v_result := public.mark_settlement_paid(r.id);
    v_total_closed := v_total_closed + coalesce((v_result->>'obligations_closed')::integer, 0);
  end loop;
  if v_total_closed < 2 then
    raise exception 'contract: obligations no cerradas al finalizar batch (cerradas: %)', v_total_closed;
  end if;
  if exists (select 1 from public.obligations where context_actor_id = v_ctx::uuid and status = 'open') then
    raise exception 'contract: quedaron obligations abiertas';
  end if;

  -- ═══ 11. context_summary refleja todo ═══
  v_summary := public.context_summary(v_ctx::uuid);
  if jsonb_array_length(v_summary->'members') <> 2 then
    raise exception 'contract: summary.members incorrecto';
  end if;
  if jsonb_array_length(v_summary->'upcoming_events') < 1 then
    raise exception 'contract: summary.upcoming_events no muestra la siguiente cena';
  end if;
  if jsonb_array_length(v_summary->'active_rules') <> 1 then
    raise exception 'contract: summary.active_rules incorrecto';
  end if;
  if (v_summary->>'open_obligations')::integer <> 0 then
    raise exception 'contract: summary.open_obligations debió ser 0';
  end if;

  -- ═══ 12. context_candidates ═══
  v_result := public.context_candidates();
  if not exists (select 1 from jsonb_array_elements(v_result->'contexts') c
                 where (c->>'context_actor_id')::uuid = v_ctx::uuid) then
    raise exception 'contract: context_candidates no muestra el contexto';
  end if;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[v_jose, v_linda], array[v_auth_jose, v_auth_linda]);

  raise notice '_smoke_mvp2_contract passed (cena semanal end-to-end con semántica de batch R.2-3)';
end; $$;

revoke all on function public._smoke_mvp2_contract() from public, anon, authenticated;
