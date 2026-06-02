-- Pre-existing bug in _rule_eval_dispatch surfaced by D.14 R5: passed NULL to
-- start_vote's p_legitimacy_source, violating NOT NULL on group_decisions.legitimacy_source.
-- Fix: let rule consequence carry legitimacy_source field; default to 'majority'.

CREATE OR REPLACE FUNCTION public._rule_eval_dispatch(
  p_action jsonb,
  p_event public.group_events,
  p_rule_version_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_kind text := p_action->>'kind';
  v_fields jsonb := COALESCE(p_action->'fields', '{}'::jsonb);
  v_target_user_id uuid;
  v_target_membership uuid;
  v_severity int;
  v_message text;
  v_audience text;
  v_new_state text;
  v_reason text;
  v_sanction_id uuid;
  v_error text;
  v_notified int;
  v_amount numeric;
  v_currency text;
  v_charge_kind text;
  v_obligation_id uuid;
  v_decision_id uuid;
  v_title text;
  v_decision_type text;
  v_method text;
  v_legitimacy text;
  v_closes_at timestamptz;
  v_use_entity boolean;
  v_ref_kind text;
  v_ref_id uuid;
  v_to_membership uuid;
  v_basis text;
  v_unit text;
  v_owner_user uuid;
  v_custodian_user uuid;
  v_holder_user uuid;
BEGIN
  v_target_user_id := COALESCE(
    NULLIF(p_event.payload->>'target_user_id','')::uuid,
    p_event.actor_user_id);
  SELECT id INTO v_target_membership FROM public.group_memberships
   WHERE group_id = p_event.group_id AND user_id = v_target_user_id;

  IF v_kind = 'consequence.issue_sanction' THEN
    v_severity := COALESCE((v_fields->>'severity')::int, 1);
    v_reason := COALESCE(v_fields->>'reason', 'Regla con engine');
    IF v_target_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'target_membership_not_found');
    END IF;
    BEGIN
      v_sanction_id := public.issue_sanction(
        p_group_id => p_event.group_id, p_target_membership_id => v_target_membership,
        p_sanction_kind => 'warning', p_reason => v_reason,
        p_amount => NULL, p_unit => NULL, p_ends_at => NULL,
        p_rule_version_id => p_rule_version_id, p_source_event_id => p_event.uuid_id,
        p_client_id => NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', v_sanction_id,
                                'severity', v_severity);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.set_membership_state' THEN
    v_new_state := v_fields->>'new_state';
    v_reason := v_fields->>'reason';
    IF v_target_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'target_membership_not_found');
    END IF;
    BEGIN
      PERFORM public.set_membership_state(v_target_membership, v_new_state, v_reason, NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', v_target_membership,
                                'new_state', v_new_state);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.send_notification' THEN
    v_message := COALESCE(v_fields->>'message', 'Regla disparada');
    v_audience := COALESCE(v_fields->>'audience', 'admins');
    v_notified := 0;
    BEGIN
      IF v_audience = 'actor' AND p_event.actor_user_id IS NOT NULL THEN
        INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
        VALUES (p_event.group_id, p_event.actor_user_id, 'rule_consequence',
                jsonb_build_object('rule_version_id', p_rule_version_id,
                                   'message', v_message,
                                   'source_event_id', p_event.uuid_id));
        v_notified := 1;
      ELSIF v_audience = 'target' AND v_target_user_id IS NOT NULL THEN
        INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
        VALUES (p_event.group_id, v_target_user_id, 'rule_consequence',
                jsonb_build_object('rule_version_id', p_rule_version_id,
                                   'message', v_message,
                                   'source_event_id', p_event.uuid_id));
        v_notified := 1;
      ELSIF v_audience = 'owner' THEN
        SELECT gm.user_id INTO v_owner_user
          FROM public.group_resources r
          JOIN public.group_memberships gm ON gm.id = r.owner_membership_id
         WHERE r.id = p_event.entity_id;
        IF v_owner_user IS NOT NULL THEN
          INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
          VALUES (p_event.group_id, v_owner_user, 'rule_consequence',
                  jsonb_build_object('rule_version_id', p_rule_version_id,
                                     'message', v_message,
                                     'source_event_id', p_event.uuid_id));
          v_notified := 1;
        END IF;
      ELSIF v_audience = 'custodian' THEN
        SELECT gm.user_id INTO v_custodian_user
          FROM public.group_resource_assets a
          JOIN public.group_memberships gm ON gm.id = a.custodian_membership_id
         WHERE a.resource_id = p_event.entity_id;
        IF v_custodian_user IS NOT NULL THEN
          INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
          VALUES (p_event.group_id, v_custodian_user, 'rule_consequence',
                  jsonb_build_object('rule_version_id', p_rule_version_id,
                                     'message', v_message,
                                     'source_event_id', p_event.uuid_id));
          v_notified := 1;
        END IF;
      ELSIF v_audience = 'holder' THEN
        SELECT gm.user_id INTO v_holder_user
          FROM public.group_resource_rights rr
          JOIN public.group_memberships gm ON gm.id = rr.holder_membership_id
         WHERE rr.resource_id = p_event.entity_id;
        IF v_holder_user IS NOT NULL THEN
          INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
          VALUES (p_event.group_id, v_holder_user, 'rule_consequence',
                  jsonb_build_object('rule_version_id', p_rule_version_id,
                                     'message', v_message,
                                     'source_event_id', p_event.uuid_id));
          v_notified := 1;
        END IF;
      ELSIF v_audience = 'group' THEN
        WITH ins AS (
          INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
          SELECT p_event.group_id, gm.user_id, 'rule_consequence',
                 jsonb_build_object('rule_version_id', p_rule_version_id,
                                    'message', v_message,
                                    'source_event_id', p_event.uuid_id)
            FROM public.group_memberships gm
           WHERE gm.group_id = p_event.group_id AND gm.status = 'active'
          RETURNING 1)
        SELECT count(*) INTO v_notified FROM ins;
      ELSE
        WITH ins AS (
          INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
          SELECT DISTINCT p_event.group_id, gm.user_id, 'rule_consequence',
                 jsonb_build_object('rule_version_id', p_rule_version_id,
                                    'message', v_message,
                                    'source_event_id', p_event.uuid_id)
            FROM public.group_memberships gm
            JOIN public.group_member_roles mr ON mr.membership_id = gm.id
            JOIN public.group_roles r ON r.id = mr.role_id
           WHERE gm.group_id = p_event.group_id AND gm.status = 'active'
             AND r.key IN ('admin','founder')
          RETURNING 1)
        SELECT count(*) INTO v_notified FROM ins;
      END IF;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'async',
                                'status', 'emitted', 'audience', v_audience,
                                'recipients', v_notified);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'async',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.create_pool_charge' THEN
    v_amount := NULLIF(v_fields->>'amount','')::numeric;
    v_currency := COALESCE(v_fields->>'currency', 'MXN');
    v_charge_kind := v_fields->>'charge_kind';
    v_reason := v_fields->>'reason';
    IF v_target_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'target_membership_not_found');
    END IF;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'amount_required');
    END IF;
    IF v_charge_kind NOT IN ('quota','buy_in','fee') THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'invalid_charge_kind');
    END IF;
    BEGIN
      v_obligation_id := public.record_pool_charge(
        p_group_id => p_event.group_id,
        p_target_membership_id => v_target_membership,
        p_amount => v_amount,
        p_unit => v_currency,
        p_charge_kind => v_charge_kind,
        p_reason => COALESCE(v_reason, 'Generado por regla con engine'),
        p_mandate_id => NULL,
        p_client_id => NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', v_obligation_id,
                                'amount', v_amount, 'currency', v_currency,
                                'charge_kind', v_charge_kind);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.start_vote' THEN
    v_title := COALESCE(v_fields->>'title', 'Decisión generada por regla');
    v_decision_type := COALESCE(v_fields->>'decision_type', 'proposal');
    v_method := COALESCE(v_fields->>'method', 'majority');
    -- FIX: legitimacy_source can come from rule, defaults to 'majority' (NOT NULL on group_decisions)
    v_legitimacy := COALESCE(v_fields->>'legitimacy_source', 'majority');
    v_closes_at := now() + (COALESCE((v_fields->>'closes_in_hours')::int, 72)::text || ' hours')::interval;
    v_use_entity := COALESCE((v_fields->>'use_event_entity')::boolean, true);
    v_ref_kind := NULL;
    v_ref_id := NULL;
    IF v_use_entity AND p_event.entity_kind IS NOT NULL AND p_event.entity_id IS NOT NULL THEN
      v_ref_kind := p_event.entity_kind;
      v_ref_id := p_event.entity_id;
    END IF;
    BEGIN
      v_decision_id := public.start_vote(
        p_group_id => p_event.group_id,
        p_title => v_title,
        p_body => format('Disparada por regla %s sobre evento %s', p_rule_version_id::text, p_event.event_type),
        p_decision_type => v_decision_type,
        p_method => v_method,
        p_legitimacy_source => v_legitimacy,
        p_opens_at => now(),
        p_closes_at => v_closes_at,
        p_threshold_pct => NULL,
        p_quorum_pct => NULL,
        p_committee_only => false,
        p_reference_kind => v_ref_kind,
        p_reference_id => v_ref_id,
        p_options => NULL,
        p_metadata => jsonb_build_object(
          'engine_rule_version_id', p_rule_version_id,
          'engine_source_event_id', p_event.uuid_id));
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', v_decision_id,
                                'decision_type', v_decision_type, 'method', v_method,
                                'reference_kind', v_ref_kind);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.lock_resource' THEN
    v_reason := v_fields->>'reason';
    IF p_event.entity_id IS NULL OR p_event.entity_kind <> 'resource' THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'event_not_resource_scoped');
    END IF;
    BEGIN
      PERFORM public.lock_fund(p_event.entity_id, COALESCE(v_reason, 'Bloqueado por regla'), NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', p_event.entity_id);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.unlock_resource' THEN
    v_reason := v_fields->>'reason';
    IF p_event.entity_id IS NULL OR p_event.entity_kind <> 'resource' THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'event_not_resource_scoped');
    END IF;
    BEGIN
      PERFORM public.unlock_fund(p_event.entity_id, COALESCE(v_reason, 'Desbloqueado por regla'), NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', p_event.entity_id);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.update_resource_value' THEN
    v_amount := NULLIF(v_fields->>'value','')::numeric;
    v_unit := COALESCE(v_fields->>'unit', 'MXN');
    v_basis := v_fields->>'basis';
    IF p_event.entity_id IS NULL OR p_event.entity_kind <> 'resource' THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'event_not_resource_scoped');
    END IF;
    IF v_amount IS NULL OR v_amount < 0 THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'value_required');
    END IF;
    BEGIN
      PERFORM public.update_resource_value(p_event.entity_id, v_amount, v_unit, v_basis);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', p_event.entity_id,
                                'value', v_amount, 'unit', v_unit);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.transfer_resource' THEN
    v_to_membership := NULLIF(v_fields->>'to_membership_id','')::uuid;
    v_reason := v_fields->>'reason';
    IF p_event.entity_id IS NULL OR p_event.entity_kind <> 'resource' THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'event_not_resource_scoped');
    END IF;
    IF v_to_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'to_membership_required');
    END IF;
    BEGIN
      PERFORM public.transfer_right(p_event.entity_id, v_to_membership,
                                    COALESCE(v_reason, 'Transferido por regla'), NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', p_event.entity_id,
                                'to_membership_id', v_to_membership);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSE
    RETURN jsonb_build_object('kind', COALESCE(v_kind,'<null>'),
                              'execution', 'unknown',
                              'status', 'skipped', 'error', 'unknown_consequence_kind');
  END IF;
END;
$$;
