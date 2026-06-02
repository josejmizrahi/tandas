-- d24_p8_fix_status_ambiguous
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- Hot-fix: 'status' is ambiguous between OUT col (RETURN TABLE) and group_sanctions.status.
-- Qualify the column in the sanction_appeal branch.
create or replace function public.execute_decision(p_decision_id uuid)
returns table(decision_id uuid, status text, outcome text, effects jsonb)
language plpgsql security definer set search_path='public','pg_catalog' as $function$
DECLARE
  v_uid             uuid := auth.uid();
  v_d               public.group_decisions%ROWTYPE;
  v_target_state    text;
  v_membership_row  public.group_memberships%ROWTYPE;
  v_rule_action     text;
  v_rule            public.group_rules%ROWTYPE;
  v_pool_amount     numeric;
  v_pool_unit       text;
  v_pool_kind       text;
  v_pool_reason     text;
  v_pool_obligation uuid;
  v_res_action      text;
  v_res_amount      numeric;
  v_res_unit        text;
  v_res_basis       text;
  v_res_target_mid  uuid;
  v_res_ownership_k text;
  v_res_event_type  text;
  v_res_payload     jsonb;
  v_action_key      text;
  v_grp_visibility  text;
  v_engine_active   boolean;
  v_role_id         uuid;
  v_perm_keys       text[];
  v_pay_amount      numeric;
  v_pay_unit        text;
  v_pay_to_mid      uuid;
  v_pay_reason      text;
  v_payout_id       uuid;
  v_reverse_txn_id  uuid;
  v_reverse_reason  text;
  v_reversal_id     uuid;
  v_norm_id         uuid;
  v_norm_rule_type  text;
  v_norm_severity   integer;
  v_promoted_rule   uuid;
  v_effects         jsonb := '{}'::jsonb;
  v_event_uuid      uuid;
  v_err_msg         text;
  v_err_state       text;
  v_appeal_outcome  text;
  v_appeal_amount   numeric;
  v_appeal_ends_at  timestamptz;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'must be authenticated' USING errcode = '42501'; END IF;
  IF p_decision_id IS NULL THEN RAISE EXCEPTION 'p_decision_id is required' USING errcode = '22023'; END IF;

  SELECT * INTO v_d FROM public.group_decisions WHERE id = p_decision_id FOR UPDATE;
  IF v_d.id IS NULL THEN RAISE EXCEPTION 'decision % not found', p_decision_id USING errcode = 'P0002'; END IF;

  PERFORM public.assert_permission(v_d.group_id, 'decisions.execute');

  IF v_d.execution_status = 'executed' THEN
    decision_id := v_d.id; status := 'executed'; outcome := (v_d.result->>'outcome');
    effects := COALESCE(v_d.execution_payload, '{}'::jsonb) || jsonb_build_object('reason','already_executed');
    RETURN NEXT; RETURN;
  END IF;

  IF v_d.status IN ('rejected','cancelled') THEN
    decision_id := v_d.id; status := v_d.status; outcome := (v_d.result->>'outcome');
    effects := jsonb_build_object('reason','already_finalized');
    RETURN NEXT; RETURN;
  END IF;

  IF v_d.status <> 'passed' THEN
    RAISE EXCEPTION 'decision % is not passed (status=%)', p_decision_id, v_d.status USING errcode = '22023';
  END IF;

  UPDATE public.group_decisions
     SET execution_status     = 'executing',
         execution_attempts   = execution_attempts + 1,
         execution_started_at = COALESCE(execution_started_at, now()),
         execution_error      = NULL
   WHERE id = p_decision_id;

  PERFORM public.record_system_event(
    v_d.group_id, 'decision.execution_started', 'decision', p_decision_id,
    'Decisión iniciando ejecución',
    jsonb_build_object('reference_kind', v_d.reference_kind, 'reference_id', v_d.reference_id,
      'execution_mode', v_d.execution_mode, 'template_key', v_d.template_key,
      'attempt', v_d.execution_attempts + 1));

  v_action_key := NULLIF(v_d.metadata->>'action_key', '');

  BEGIN
    -- PHASE 8: sanction_appeal branch
    IF v_d.decision_type = 'sanction_appeal' AND v_d.reference_kind = 'sanction' AND v_d.reference_id IS NOT NULL THEN
      v_appeal_outcome := NULLIF(v_d.metadata->>'appeal_outcome','');
      IF NOT EXISTS (SELECT 1 FROM public.group_sanctions WHERE id = v_d.reference_id) THEN
        RAISE EXCEPTION 'sanction_not_found_during_appeal' USING errcode='P0002';
      END IF;
      IF v_appeal_outcome IS NULL OR v_appeal_outcome NOT IN ('upheld','reduced','overturned') THEN
        RAISE EXCEPTION 'invalid_appeal_outcome' USING errcode='22023';
      END IF;

      IF v_appeal_outcome = 'upheld' THEN
        UPDATE public.group_sanctions s
           SET appeal_status='upheld',
               status = CASE WHEN s.status='disputed' THEN 'active' ELSE s.status END,
               updated_at = now()
         WHERE s.id = v_d.reference_id;
        v_effects := v_effects || jsonb_build_object('appeal_outcome','upheld','sanction_id', v_d.reference_id);

      ELSIF v_appeal_outcome = 'reduced' THEN
        v_appeal_amount := NULLIF(v_d.metadata->>'appeal_amount','')::numeric;
        v_appeal_ends_at := NULLIF(v_d.metadata->>'appeal_ends_at','')::timestamptz;
        UPDATE public.group_sanctions s
           SET appeal_status='reduced',
               status = CASE WHEN s.status='disputed' THEN 'active' ELSE s.status END,
               amount = COALESCE(v_appeal_amount, s.amount),
               ends_at = COALESCE(v_appeal_ends_at, s.ends_at),
               metadata = s.metadata || jsonb_build_object('appeal_adjustment', jsonb_build_object(
                   'amount', v_appeal_amount, 'ends_at', v_appeal_ends_at, 'decision_id', p_decision_id)),
               updated_at = now()
         WHERE s.id = v_d.reference_id;
        v_effects := v_effects || jsonb_build_object('appeal_outcome','reduced','sanction_id', v_d.reference_id,
            'new_amount', v_appeal_amount, 'new_ends_at', v_appeal_ends_at);

      ELSIF v_appeal_outcome = 'overturned' THEN
        PERFORM public.update_sanction_status(v_d.reference_id, 'reversed', 'appeal_overturned');
        UPDATE public.group_sanctions s
           SET appeal_status='overturned', resolved_at=now(),
               metadata = s.metadata || jsonb_build_object('overturned_by_decision', p_decision_id),
               updated_at=now()
         WHERE s.id = v_d.reference_id;
        v_effects := v_effects || jsonb_build_object('appeal_outcome','overturned','sanction_id', v_d.reference_id);
      END IF;

      PERFORM public.record_system_event(
        v_d.group_id, 'sanction.appeal_resolved', 'sanction', v_d.reference_id,
        'Apelación resuelta: ' || v_appeal_outcome,
        jsonb_build_object('appeal_outcome', v_appeal_outcome,
          'decision_id', p_decision_id, 'sanction_id', v_d.reference_id));

    ELSIF v_d.reference_kind = 'sanction' AND v_d.reference_id IS NOT NULL THEN
      PERFORM public.update_sanction_status(v_d.reference_id, 'reversed', 'decision_executed');
      v_effects := v_effects || jsonb_build_object('sanction_reversed', v_d.reference_id);

    ELSIF v_d.reference_kind = 'dispute' AND v_d.reference_id IS NOT NULL THEN
      UPDATE public.group_disputes SET status='resolved', resolved_at=now() WHERE id = v_d.reference_id;
      v_effects := v_effects || jsonb_build_object('dispute_resolved', v_d.reference_id);

    ELSIF v_d.reference_kind = 'mandate_grant' AND v_d.reference_id IS NOT NULL THEN
      UPDATE public.group_mandates SET source_decision_id = p_decision_id WHERE id = v_d.reference_id;
      v_effects := v_effects || jsonb_build_object('mandate_linked', v_d.reference_id);

    ELSIF v_d.reference_kind = 'mandate_revoke' AND v_d.reference_id IS NOT NULL THEN
      PERFORM public.revoke_mandate(v_d.reference_id, 'decision_executed', p_decision_id);
      v_effects := v_effects || jsonb_build_object('mandate_revoked', v_d.reference_id);

    ELSIF v_d.reference_kind = 'dissolution' AND v_d.reference_id IS NOT NULL THEN
      IF v_d.template_key = 'decision.dissolution_finalize' THEN
        PERFORM public.finalize_dissolution(v_d.reference_id);
        v_effects := v_effects || jsonb_build_object('dissolution_finalized', v_d.reference_id);
      ELSE
        PERFORM public.approve_dissolution(v_d.reference_id);
        v_effects := v_effects || jsonb_build_object('dissolution_approved', v_d.reference_id);
      END IF;

    ELSIF v_d.reference_kind = 'membership' AND v_d.reference_id IS NOT NULL THEN
      v_target_state := NULLIF(v_d.metadata->>'target_state', '');
      v_target_state := CASE v_target_state WHEN 'expelled' THEN 'banned' WHEN 'inactive' THEN 'left' ELSE v_target_state END;
      IF v_target_state IN ('active','paused','suspended','removed','left','banned') THEN
        SELECT * INTO v_membership_row FROM public.group_memberships WHERE id = v_d.reference_id FOR UPDATE;
        IF v_membership_row.id IS NOT NULL AND v_membership_row.status = 'banned' AND v_target_state = 'active' THEN
          UPDATE public.group_memberships SET unban_decision_id = p_decision_id WHERE id = v_membership_row.id;
        END IF;
        PERFORM public.set_membership_state(v_d.reference_id, v_target_state, 'decision_executed', NULL);
        v_effects := v_effects || jsonb_build_object('membership_state', v_target_state);
      ELSE
        v_effects := v_effects || jsonb_build_object('membership_state','noop','message','target_state ausente o desconocido');
      END IF;

    ELSIF v_d.reference_kind = 'rule' AND v_d.reference_id IS NOT NULL THEN
      v_rule_action := COALESCE(NULLIF(v_d.metadata->>'action', ''), NULLIF(v_d.metadata->>'rule_action',''));
      SELECT * INTO v_rule FROM public.group_rules WHERE id = v_d.reference_id FOR UPDATE;
      IF v_rule.id IS NOT NULL THEN
        IF v_rule_action = 'archive' AND v_rule.status <> 'archived' THEN
          UPDATE public.group_rules SET status='archived', updated_at=now() WHERE id = v_rule.id;
          IF v_rule.current_version_id IS NOT NULL THEN
            UPDATE public.group_rule_versions SET effective_until = now()
             WHERE id = v_rule.current_version_id AND effective_until IS NULL;
          END IF;
          PERFORM public.record_system_event(v_rule.group_id, 'rule.archived', 'rule', v_rule.id,
            'Regla archivada por decisión', jsonb_build_object('source','decision','decision_id', p_decision_id));
          v_effects := v_effects || jsonb_build_object('rule_archived', v_rule.id);
        ELSIF v_rule_action = 'activate' AND v_rule.status IN ('archived','draft') THEN
          UPDATE public.group_rules SET status='active', updated_at=now() WHERE id = v_rule.id;
          PERFORM public.record_system_event(v_rule.group_id, 'rule.activated', 'rule', v_rule.id,
            'Regla reactivada por decisión', jsonb_build_object('source','decision','decision_id', p_decision_id));
          v_effects := v_effects || jsonb_build_object('rule_activated', v_rule.id);
        ELSE
          v_effects := v_effects || jsonb_build_object('rule_action','noop');
        END IF;
      END IF;

    ELSIF v_d.reference_kind = 'pool_charge' AND v_d.reference_id IS NOT NULL THEN
      v_pool_amount := NULLIF(v_d.metadata->>'amount', '')::numeric;
      v_pool_unit   := COALESCE(NULLIF(v_d.metadata->>'unit', ''), 'MXN');
      v_pool_kind   := NULLIF(v_d.metadata->>'charge_kind', '');
      v_pool_reason := NULLIF(v_d.metadata->>'reason', '');
      IF v_pool_amount IS NOT NULL AND v_pool_amount > 0 AND v_pool_kind IN ('quota','buy_in','fee') THEN
        INSERT INTO public.group_obligations (group_id, owed_by_membership_id, owed_to_kind,
          obligation_kind, amount_original, amount_outstanding, unit, description, metadata)
        VALUES (v_d.group_id, v_d.reference_id, 'pool', 'pool_charge', v_pool_amount, v_pool_amount, v_pool_unit,
          COALESCE(v_pool_reason, v_d.title),
          jsonb_build_object('charge_kind', v_pool_kind, 'source','decision','decision_id', p_decision_id))
        RETURNING id INTO v_pool_obligation;
        PERFORM public.record_system_event(v_d.group_id, 'money.pool_charge_created', 'obligation', v_pool_obligation,
          COALESCE(v_pool_reason, v_d.title),
          jsonb_build_object('amount', v_pool_amount, 'unit', v_pool_unit, 'kind', v_pool_kind,
            'target', v_d.reference_id, 'source','decision','decision_id', p_decision_id));
        v_effects := v_effects || jsonb_build_object('pool_charge_created', v_pool_obligation);
      END IF;

    ELSIF v_d.reference_kind = 'resource' AND v_d.reference_id IS NOT NULL THEN
      v_res_action := COALESCE(NULLIF(v_d.metadata->>'action', ''), NULLIF(v_d.metadata->>'resource_action',''));
      IF v_res_action = 'archive' THEN
        PERFORM public.archive_resource(v_d.reference_id, 'decision_executed');
        v_effects := v_effects || jsonb_build_object('resource_archived', v_d.reference_id);
      ELSIF v_res_action = 'unarchive' THEN
        PERFORM public.revert_archive_resource(v_d.reference_id, 'decision_executed');
        v_effects := v_effects || jsonb_build_object('resource_unarchived', v_d.reference_id);
      ELSIF v_res_action = 'transfer' THEN
        v_res_target_mid  := NULLIF(v_d.metadata->>'target_membership_id','')::uuid;
        v_res_ownership_k := COALESCE(NULLIF(v_d.metadata->>'target_ownership_kind',''), 'individual');
        IF v_res_target_mid IS NULL THEN RAISE EXCEPTION 'transfer requires metadata.target_membership_id' USING errcode = '22023'; END IF;
        PERFORM public.set_resource_ownership(v_d.reference_id, v_res_ownership_k, v_res_target_mid,
          COALESCE(v_d.metadata->'ownership_metadata', '{}'::jsonb));
        v_effects := v_effects || jsonb_build_object('resource_transferred', v_d.reference_id,
          'to_membership', v_res_target_mid, 'ownership_kind', v_res_ownership_k);
      ELSIF v_res_action = 'value_update' THEN
        v_res_amount := NULLIF(v_d.metadata->>'amount','')::numeric;
        v_res_unit   := NULLIF(v_d.metadata->>'unit','');
        v_res_basis  := NULLIF(v_d.metadata->>'basis','');
        IF v_res_amount IS NULL OR v_res_unit IS NULL THEN RAISE EXCEPTION 'value_update requires metadata.amount and metadata.unit' USING errcode = '22023'; END IF;
        PERFORM public.update_resource_value(v_d.reference_id, v_res_amount, v_res_unit, COALESCE(v_res_basis, 'decision'));
        v_effects := v_effects || jsonb_build_object('resource_value_updated', v_d.reference_id, 'value', v_res_amount::text, 'unit', v_res_unit);
      ELSIF v_res_action = 'lifecycle_event' THEN
        v_res_event_type := NULLIF(v_d.metadata->>'event_type','');
        v_res_payload    := COALESCE(v_d.metadata->'payload', '{}'::jsonb);
        IF v_res_event_type IS NULL THEN RAISE EXCEPTION 'lifecycle_event requires metadata.event_type' USING errcode = '22023'; END IF;
        PERFORM public.record_resource_lifecycle_event(v_d.reference_id, v_res_event_type, v_res_payload, NULL);
        v_effects := v_effects || jsonb_build_object('resource_event_recorded', v_d.reference_id, 'event_type', v_res_event_type);
      ELSE
        v_effects := v_effects || jsonb_build_object('resource_action','not_implemented','message','metadata.action ausente o desconocido');
      END IF;

    ELSIF v_d.reference_kind = 'group' AND v_action_key IS NOT NULL THEN
      IF v_action_key = 'engine.toggle' THEN
        v_engine_active := COALESCE((v_d.metadata->>'active')::boolean,
                                    NOT (SELECT engine_active FROM public.groups WHERE id = v_d.group_id));
        PERFORM public.set_group_engine_active(v_d.group_id, v_engine_active);
        v_effects := v_effects || jsonb_build_object('engine_active', v_engine_active);
      ELSIF v_action_key = 'group.visibility.set' THEN
        v_grp_visibility := NULLIF(v_d.metadata->>'visibility', '');
        IF v_grp_visibility IS NULL THEN RAISE EXCEPTION 'group.visibility.set requires metadata.visibility' USING errcode = '22023'; END IF;
        PERFORM public.set_group_visibility(v_d.group_id, v_grp_visibility);
        v_effects := v_effects || jsonb_build_object('visibility_set', v_grp_visibility);
      ELSIF v_action_key = 'group.boundary.set' THEN
        PERFORM public.set_group_boundary_policy(v_d.group_id,
          NULLIF(v_d.metadata->>'entry_mode',''), NULLIF(v_d.metadata->>'who_can_invite',''),
          COALESCE((v_d.metadata->>'requires_approval')::boolean, true),
          NULLIF(v_d.metadata->>'exit_mode',''), NULLIF(v_d.metadata->>'notes',''));
        v_effects := v_effects || jsonb_build_object('boundary_updated', true);
      ELSIF v_action_key = 'group.decision_rules.set' THEN
        PERFORM public.set_decision_rules(v_d.group_id,
          NULLIF(v_d.metadata->>'default_style',''),
          COALESCE((v_d.metadata->>'quorum_min')::int, 1),
          NULLIF(v_d.metadata->>'notes',''),
          NULLIF(v_d.metadata->>'default_method',''),
          NULLIF(v_d.metadata->>'default_legitimacy_source',''));
        v_effects := v_effects || jsonb_build_object('decision_rules_updated', true);
      ELSE
        v_effects := v_effects || jsonb_build_object('group_action','not_implemented','action_key',v_action_key);
      END IF;

    ELSIF v_d.reference_kind = 'role' AND v_action_key IS NOT NULL THEN
      IF v_action_key = 'role.create' THEN
        v_perm_keys := ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_d.metadata->'permission_keys','[]'::jsonb)));
        v_role_id := public.create_custom_role(v_d.group_id,
          NULLIF(v_d.metadata->>'key',''), NULLIF(v_d.metadata->>'name',''),
          NULLIF(v_d.metadata->>'description',''), v_perm_keys);
        v_effects := v_effects || jsonb_build_object('role_created', v_role_id);
      ELSIF v_action_key = 'role.update_permissions' AND v_d.reference_id IS NOT NULL THEN
        v_perm_keys := ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_d.metadata->'permission_keys','[]'::jsonb)));
        PERFORM public.update_role_permissions(v_d.reference_id, v_perm_keys);
        v_effects := v_effects || jsonb_build_object('role_updated', v_d.reference_id);
      ELSE
        v_effects := v_effects || jsonb_build_object('role_action','not_implemented','action_key',v_action_key);
      END IF;

    ELSIF v_d.reference_kind = 'money_movement' AND v_action_key IS NOT NULL THEN
      IF v_action_key = 'money.payout' THEN
        v_pay_amount := NULLIF(v_d.metadata->>'amount','')::numeric;
        v_pay_unit   := COALESCE(NULLIF(v_d.metadata->>'unit',''), 'MXN');
        v_pay_to_mid := NULLIF(v_d.metadata->>'to_membership_id','')::uuid;
        v_pay_reason := COALESCE(NULLIF(v_d.metadata->>'reason',''), 'decision_executed');
        IF v_pay_amount IS NULL OR v_pay_amount <= 0 OR v_pay_to_mid IS NULL THEN
          RAISE EXCEPTION 'money.payout requires metadata.amount + to_membership_id' USING errcode = '22023'; END IF;
        v_payout_id := public.record_payout(v_d.group_id, v_pay_to_mid, v_pay_amount, v_pay_unit,
          NULLIF(v_d.metadata->>'source_resource_id','')::uuid, v_pay_reason,
          NULLIF(v_d.metadata->>'mandate_id','')::uuid, 'decision:' || p_decision_id::text);
        v_effects := v_effects || jsonb_build_object('payout_recorded', v_payout_id);
      ELSIF v_action_key = 'money.transaction.reverse' THEN
        v_reverse_txn_id := COALESCE(v_d.reference_id, NULLIF(v_d.metadata->>'transaction_id','')::uuid);
        v_reverse_reason := COALESCE(NULLIF(v_d.metadata->>'reason',''), 'decision_executed');
        IF v_reverse_txn_id IS NULL THEN RAISE EXCEPTION 'money.transaction.reverse requires transaction_id' USING errcode = '22023'; END IF;
        v_reversal_id := public.reverse_transaction(v_reverse_txn_id, v_reverse_reason);
        v_effects := v_effects || jsonb_build_object('transaction_reversed', v_reverse_txn_id, 'reversal_id', v_reversal_id);
      ELSE
        v_effects := v_effects || jsonb_build_object('money_action','not_implemented','action_key',v_action_key);
      END IF;

    ELSIF v_d.reference_kind = 'norm' AND v_action_key = 'norm.promote_to_rule' AND v_d.reference_id IS NOT NULL THEN
      v_norm_id := v_d.reference_id;
      v_norm_rule_type := COALESCE(NULLIF(v_d.metadata->>'rule_type',''), 'cultural');
      v_norm_severity  := COALESCE(NULLIF(v_d.metadata->>'severity','')::int, 0);
      SELECT rule_id INTO v_promoted_rule FROM public.promote_norm_to_rule(v_norm_id, v_norm_rule_type, v_norm_severity);
      v_effects := v_effects || jsonb_build_object('norm_promoted', v_norm_id, 'rule_id', v_promoted_rule);

    ELSE
      v_effects := v_effects || jsonb_build_object('no_effects','reference_kind_not_handled', 'reference_kind', v_d.reference_kind);
    END IF;

  EXCEPTION WHEN OTHERS THEN
    v_err_msg := SQLERRM; v_err_state := SQLSTATE;
    UPDATE public.group_decisions
       SET execution_status='failed', execution_error=v_err_msg, execution_finished_at=now(),
           execution_payload=jsonb_build_object('error', v_err_msg, 'sqlstate', v_err_state)
     WHERE id = p_decision_id;
    PERFORM public.record_system_event(v_d.group_id, 'decision.execution_failed', 'decision', p_decision_id,
      'Falló la ejecución de la decisión',
      jsonb_build_object('reference_kind', v_d.reference_kind, 'reference_id', v_d.reference_id,
        'action_key', v_action_key, 'attempt', v_d.execution_attempts + 1,
        'error', v_err_msg, 'sqlstate', v_err_state));
    decision_id := v_d.id; status := 'failed'; outcome := (v_d.result->>'outcome');
    effects := jsonb_build_object('error', v_err_msg, 'sqlstate', v_err_state,
      'action_key', v_action_key, 'reference_kind', v_d.reference_kind);
    RETURN NEXT; RETURN;
  END;

  UPDATE public.group_decisions
     SET status='executed', executed_at=now(), executed_by=v_uid,
         execution_status='executed', execution_finished_at=now(),
         execution_payload=v_effects, execution_error=NULL
   WHERE id = p_decision_id;

  SELECT rse.uuid_id INTO v_event_uuid FROM public.record_system_event(
    v_d.group_id, 'decision.executed', 'decision', p_decision_id, 'Decisión ejecutada',
    jsonb_build_object('reference_kind', v_d.reference_kind, 'reference_id', v_d.reference_id,
      'execution_mode', v_d.execution_mode, 'template_key', v_d.template_key,
      'action_key', v_action_key, 'effects', v_effects)) rse;
  PERFORM public.evaluate_rules_for_event(v_event_uuid, 'sync');

  PERFORM public.record_system_event(v_d.group_id, 'decision.execution_completed', 'decision', p_decision_id,
    'Ejecución completada',
    jsonb_build_object('reference_kind', v_d.reference_kind, 'reference_id', v_d.reference_id,
      'action_key', v_action_key, 'attempts', v_d.execution_attempts + 1, 'effects', v_effects));

  decision_id := v_d.id; status := 'executed'; outcome := (v_d.result->>'outcome'); effects := v_effects;
  RETURN NEXT;
END;
$function$;

grant execute on function public.execute_decision(uuid) to authenticated;

-- Cleanup the debug sanction we left around (it was flagged executed=failed)
-- Reset that decision back to retryable state
UPDATE public.group_decisions
SET execution_status='pending', execution_error=NULL, execution_payload=NULL,
    execution_finished_at=NULL
WHERE execution_status='failed' AND execution_error LIKE '%status%ambiguous%';
