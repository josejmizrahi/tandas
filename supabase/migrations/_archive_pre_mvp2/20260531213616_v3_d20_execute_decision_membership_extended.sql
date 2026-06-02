-- V3-D.20 FASE G — execute_decision: membership branch acepta los 8
-- estados nuevos. Cuando el target_state es `active` y la membresía
-- está en `banned`, set_membership_state requiere unban_decision_id;
-- lo set BEFORE llamando para satisfacer el guard.

CREATE OR REPLACE FUNCTION public.execute_decision(p_decision_id uuid)
RETURNS TABLE (
  decision_id uuid,
  status      text,
  outcome     text,
  effects     jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
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
  v_effects         jsonb := '{}'::jsonb;
  v_event_uuid      uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  IF p_decision_id IS NULL THEN
    RAISE EXCEPTION 'p_decision_id is required' USING errcode = '22023';
  END IF;

  SELECT * INTO v_d FROM public.group_decisions WHERE id = p_decision_id FOR UPDATE;
  IF v_d.id IS NULL THEN
    RAISE EXCEPTION 'decision % not found', p_decision_id USING errcode = 'P0002';
  END IF;

  PERFORM public.assert_permission(v_d.group_id, 'decisions.execute');

  IF v_d.status IN ('executed','rejected','cancelled') THEN
    decision_id := v_d.id;
    status      := v_d.status;
    outcome     := (v_d.result->>'outcome');
    effects     := jsonb_build_object('reason','already_finalized');
    RETURN NEXT;
    RETURN;
  END IF;

  IF v_d.status <> 'passed' THEN
    RAISE EXCEPTION 'decision % is not passed (status=%)', p_decision_id, v_d.status
      USING errcode = '22023';
  END IF;

  IF v_d.reference_kind = 'sanction' AND v_d.reference_id IS NOT NULL THEN
    PERFORM public.update_sanction_status(v_d.reference_id, 'reversed', 'decision_executed');
    v_effects := v_effects || jsonb_build_object('sanction_reversed', v_d.reference_id);

  ELSIF v_d.reference_kind = 'dispute' AND v_d.reference_id IS NOT NULL THEN
    UPDATE public.group_disputes SET status='resolved', resolved_at=now() WHERE id = v_d.reference_id;
    v_effects := v_effects || jsonb_build_object('dispute_resolved', v_d.reference_id);

  ELSIF v_d.reference_kind = 'mandate_grant' AND v_d.reference_id IS NOT NULL THEN
    UPDATE public.group_mandates SET source_decision_id = p_decision_id WHERE id = v_d.reference_id;
    v_effects := v_effects || jsonb_build_object('mandate_linked', v_d.reference_id);

  ELSIF v_d.reference_kind = 'mandate_revoke' AND v_d.reference_id IS NOT NULL THEN
    PERFORM public.revoke_mandate(v_d.reference_id, 'decision_executed');
    v_effects := v_effects || jsonb_build_object('mandate_revoked', v_d.reference_id);

  ELSIF v_d.reference_kind = 'dissolution' AND v_d.reference_id IS NOT NULL THEN
    PERFORM public.approve_dissolution(v_d.reference_id);
    v_effects := v_effects || jsonb_build_object('dissolution_approved', v_d.reference_id);

  ELSIF v_d.reference_kind = 'membership' AND v_d.reference_id IS NOT NULL THEN
    v_target_state := NULLIF(v_d.metadata->>'target_state', '');
    -- Legacy mapping compatibility
    v_target_state := CASE v_target_state
      WHEN 'expelled' THEN 'banned'
      WHEN 'inactive' THEN 'left'
      ELSE v_target_state
    END;

    IF v_target_state IN ('active','paused','suspended','removed','left','banned') THEN
      -- Special case: banned → active requires unban_decision_id (set first
      -- so the set_membership_state guard passes).
      SELECT * INTO v_membership_row FROM public.group_memberships
        WHERE id = v_d.reference_id FOR UPDATE;
      IF v_membership_row.id IS NOT NULL AND v_membership_row.status = 'banned' AND v_target_state = 'active' THEN
        UPDATE public.group_memberships
           SET unban_decision_id = p_decision_id
         WHERE id = v_membership_row.id;
      END IF;

      PERFORM public.set_membership_state(v_d.reference_id, v_target_state, 'decision_executed', NULL);
      v_effects := v_effects || jsonb_build_object('membership_state', v_target_state);
    ELSE
      v_effects := v_effects || jsonb_build_object(
        'membership_state','noop',
        'message','target_state ausente o desconocido'
      );
    END IF;

  ELSIF v_d.reference_kind = 'rule' AND v_d.reference_id IS NOT NULL THEN
    v_rule_action := NULLIF(v_d.metadata->>'action', '');
    SELECT * INTO v_rule FROM public.group_rules WHERE id = v_d.reference_id FOR UPDATE;
    IF v_rule.id IS NOT NULL THEN
      IF v_rule_action = 'archive' AND v_rule.status <> 'archived' THEN
        UPDATE public.group_rules SET status='archived', updated_at=now() WHERE id = v_rule.id;
        IF v_rule.current_version_id IS NOT NULL THEN
          UPDATE public.group_rule_versions SET effective_until = now()
           WHERE id = v_rule.current_version_id AND effective_until IS NULL;
        END IF;
        PERFORM public.record_system_event(
          v_rule.group_id, 'rule.archived', 'rule', v_rule.id,
          'Regla archivada por decisión',
          jsonb_build_object('source','decision','decision_id', p_decision_id)
        );
        v_effects := v_effects || jsonb_build_object('rule_archived', v_rule.id);
      ELSIF v_rule_action = 'activate' AND v_rule.status IN ('archived','draft') THEN
        UPDATE public.group_rules SET status='active', updated_at=now() WHERE id = v_rule.id;
        PERFORM public.record_system_event(
          v_rule.group_id, 'rule.activated', 'rule', v_rule.id,
          'Regla reactivada por decisión',
          jsonb_build_object('source','decision','decision_id', p_decision_id)
        );
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
    IF v_pool_amount IS NOT NULL AND v_pool_amount > 0
       AND v_pool_kind IN ('quota','buy_in','fee') THEN
      INSERT INTO public.group_obligations (
        group_id, owed_by_membership_id, owed_to_kind,
        obligation_kind, amount_original, amount_outstanding, unit, description, metadata
      ) VALUES (
        v_d.group_id, v_d.reference_id, 'pool',
        'pool_charge', v_pool_amount, v_pool_amount, v_pool_unit,
        COALESCE(v_pool_reason, v_d.title),
        jsonb_build_object('charge_kind', v_pool_kind, 'source','decision','decision_id', p_decision_id)
      ) RETURNING id INTO v_pool_obligation;
      PERFORM public.record_system_event(
        v_d.group_id, 'money.pool_charge_created', 'obligation', v_pool_obligation,
        COALESCE(v_pool_reason, v_d.title),
        jsonb_build_object('amount', v_pool_amount, 'unit', v_pool_unit, 'kind', v_pool_kind,
                           'target', v_d.reference_id, 'source','decision','decision_id', p_decision_id)
      );
      v_effects := v_effects || jsonb_build_object('pool_charge_created', v_pool_obligation);
    END IF;

  ELSIF v_d.reference_kind = 'resource' AND v_d.reference_id IS NOT NULL THEN
    v_res_action := NULLIF(v_d.metadata->>'action', '');

    IF v_res_action = 'archive' THEN
      PERFORM public.archive_resource(v_d.reference_id, 'decision_executed');
      v_effects := v_effects || jsonb_build_object('resource_archived', v_d.reference_id);

    ELSIF v_res_action = 'transfer' THEN
      v_res_target_mid  := NULLIF(v_d.metadata->>'target_membership_id','')::uuid;
      v_res_ownership_k := COALESCE(NULLIF(v_d.metadata->>'target_ownership_kind',''), 'individual');
      IF v_res_target_mid IS NULL THEN
        RAISE EXCEPTION 'transfer requires metadata.target_membership_id' USING errcode = '22023';
      END IF;
      PERFORM public.set_resource_ownership(
        v_d.reference_id, v_res_ownership_k, v_res_target_mid,
        COALESCE(v_d.metadata->'ownership_metadata', '{}'::jsonb)
      );
      v_effects := v_effects || jsonb_build_object(
        'resource_transferred', v_d.reference_id,
        'to_membership',        v_res_target_mid,
        'ownership_kind',       v_res_ownership_k
      );

    ELSIF v_res_action = 'value_update' THEN
      v_res_amount := NULLIF(v_d.metadata->>'amount','')::numeric;
      v_res_unit   := NULLIF(v_d.metadata->>'unit','');
      v_res_basis  := NULLIF(v_d.metadata->>'basis','');
      IF v_res_amount IS NULL OR v_res_unit IS NULL THEN
        RAISE EXCEPTION 'value_update requires metadata.amount and metadata.unit' USING errcode = '22023';
      END IF;
      PERFORM public.update_resource_value(
        v_d.reference_id, v_res_amount, v_res_unit, COALESCE(v_res_basis, 'decision')
      );
      v_effects := v_effects || jsonb_build_object(
        'resource_value_updated', v_d.reference_id,
        'value', v_res_amount::text, 'unit', v_res_unit
      );

    ELSIF v_res_action = 'lifecycle_event' THEN
      v_res_event_type := NULLIF(v_d.metadata->>'event_type','');
      v_res_payload    := COALESCE(v_d.metadata->'payload', '{}'::jsonb);
      IF v_res_event_type IS NULL THEN
        RAISE EXCEPTION 'lifecycle_event requires metadata.event_type' USING errcode = '22023';
      END IF;
      PERFORM public.record_resource_lifecycle_event(
        v_d.reference_id, v_res_event_type, v_res_payload, NULL
      );
      v_effects := v_effects || jsonb_build_object(
        'resource_event_recorded', v_d.reference_id,
        'event_type', v_res_event_type
      );

    ELSE
      v_effects := v_effects || jsonb_build_object(
        'resource_action','not_implemented',
        'message','metadata.action ausente o desconocido'
      );
    END IF;

  ELSE
    v_effects := v_effects || jsonb_build_object('no_effects','reference_kind_not_handled');
  END IF;

  UPDATE public.group_decisions
     SET status = 'executed', executed_at = now(), executed_by = v_uid
   WHERE id = p_decision_id;

  SELECT rse.uuid_id INTO v_event_uuid FROM public.record_system_event(
    v_d.group_id, 'decision.executed', 'decision', p_decision_id,
    'Decisión ejecutada',
    jsonb_build_object(
      'reference_kind', v_d.reference_kind,
      'reference_id',   v_d.reference_id,
      'execution_mode', v_d.execution_mode,
      'template_key',   v_d.template_key,
      'effects',        v_effects
    )
  ) rse;
  PERFORM public.evaluate_rules_for_event(v_event_uuid, 'sync');

  decision_id := v_d.id;
  status      := 'executed';
  outcome     := (v_d.result->>'outcome');
  effects     := v_effects;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.execute_decision(uuid) IS
  'V3-D.20 — membership branch acepta 8 estados; banned→active set unban_decision_id antes de llamar set_membership_state.';
