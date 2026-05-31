-- V3 FASE D.15 — Mig B (part 2): dispatcher enriched (target_kind everywhere,
-- recipient_user_ids[] for notif, new create_obligation branch),
-- evaluator emits rule.consequence.executed after eval insert.

BEGIN;

-- =============================================================================
-- B5: _rule_eval_dispatch — adds target_kind to every return + recipient_user_ids[]
--     for send_notification + new consequence.create_obligation branch.
-- =============================================================================
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
  v_actor_membership uuid;
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
  v_recipients uuid[] := ARRAY[]::uuid[];
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
  -- create_obligation
  v_counterparty text;
  v_counterparty_membership uuid;
BEGIN
  v_target_user_id := COALESCE(
    NULLIF(p_event.payload->>'target_user_id','')::uuid,
    p_event.actor_user_id);
  SELECT id INTO v_target_membership FROM public.group_memberships
   WHERE group_id = p_event.group_id AND user_id = v_target_user_id;
  -- Actor's own membership (used by create_obligation as owed_by)
  SELECT id INTO v_actor_membership FROM public.group_memberships
   WHERE group_id = p_event.group_id AND user_id = p_event.actor_user_id;

  IF v_kind = 'consequence.issue_sanction' THEN
    v_severity := COALESCE((v_fields->>'severity')::int, 1);
    v_reason := COALESCE(v_fields->>'reason', 'Regla con engine');
    IF v_target_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'target_membership_not_found',
                                'target_kind', 'sanction');
    END IF;
    BEGIN
      v_sanction_id := public.issue_sanction(
        p_group_id => p_event.group_id, p_target_membership_id => v_target_membership,
        p_sanction_kind => 'warning', p_reason => v_reason,
        p_amount => NULL, p_unit => NULL, p_ends_at => NULL,
        p_rule_version_id => p_rule_version_id, p_source_event_id => p_event.uuid_id,
        p_client_id => NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted',
                                'target_kind', 'sanction',
                                'target_id', v_sanction_id,
                                'severity', v_severity);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error,
                                'target_kind', 'sanction');
    END;

  ELSIF v_kind = 'consequence.set_membership_state' THEN
    v_new_state := v_fields->>'new_state';
    v_reason := v_fields->>'reason';
    IF v_target_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'target_membership_not_found',
                                'target_kind', 'membership');
    END IF;
    BEGIN
      PERFORM public.set_membership_state(v_target_membership, v_new_state, v_reason, NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted',
                                'target_kind', 'membership',
                                'target_id', v_target_membership,
                                'new_state', v_new_state);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error,
                                'target_kind', 'membership');
    END;

  ELSIF v_kind = 'consequence.send_notification' THEN
    v_message := COALESCE(v_fields->>'message', 'Regla disparada');
    v_audience := COALESCE(v_fields->>'audience', 'admins');
    v_notified := 0;
    v_recipients := ARRAY[]::uuid[];
    BEGIN
      IF v_audience = 'actor' AND p_event.actor_user_id IS NOT NULL THEN
        WITH ins AS (
          INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
          VALUES (p_event.group_id, p_event.actor_user_id, 'rule_consequence',
                  jsonb_build_object('rule_version_id', p_rule_version_id,
                                     'message', v_message,
                                     'source_event_id', p_event.uuid_id))
          RETURNING recipient_user_id)
        SELECT COALESCE(array_agg(recipient_user_id), ARRAY[]::uuid[]) INTO v_recipients FROM ins;
        v_notified := array_length(v_recipients, 1);
      ELSIF v_audience = 'target' AND v_target_user_id IS NOT NULL THEN
        WITH ins AS (
          INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
          VALUES (p_event.group_id, v_target_user_id, 'rule_consequence',
                  jsonb_build_object('rule_version_id', p_rule_version_id,
                                     'message', v_message,
                                     'source_event_id', p_event.uuid_id))
          RETURNING recipient_user_id)
        SELECT COALESCE(array_agg(recipient_user_id), ARRAY[]::uuid[]) INTO v_recipients FROM ins;
        v_notified := array_length(v_recipients, 1);
      ELSIF v_audience = 'owner' THEN
        SELECT gm.user_id INTO v_owner_user
          FROM public.group_resources r
          JOIN public.group_memberships gm ON gm.id = r.owner_membership_id
         WHERE r.id = p_event.entity_id;
        IF v_owner_user IS NOT NULL THEN
          WITH ins AS (
            INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
            VALUES (p_event.group_id, v_owner_user, 'rule_consequence',
                    jsonb_build_object('rule_version_id', p_rule_version_id,
                                       'message', v_message,
                                       'source_event_id', p_event.uuid_id))
            RETURNING recipient_user_id)
          SELECT COALESCE(array_agg(recipient_user_id), ARRAY[]::uuid[]) INTO v_recipients FROM ins;
          v_notified := array_length(v_recipients, 1);
        END IF;
      ELSIF v_audience = 'custodian' THEN
        SELECT gm.user_id INTO v_custodian_user
          FROM public.group_resource_assets a
          JOIN public.group_memberships gm ON gm.id = a.custodian_membership_id
         WHERE a.resource_id = p_event.entity_id;
        IF v_custodian_user IS NOT NULL THEN
          WITH ins AS (
            INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
            VALUES (p_event.group_id, v_custodian_user, 'rule_consequence',
                    jsonb_build_object('rule_version_id', p_rule_version_id,
                                       'message', v_message,
                                       'source_event_id', p_event.uuid_id))
            RETURNING recipient_user_id)
          SELECT COALESCE(array_agg(recipient_user_id), ARRAY[]::uuid[]) INTO v_recipients FROM ins;
          v_notified := array_length(v_recipients, 1);
        END IF;
      ELSIF v_audience = 'holder' THEN
        SELECT gm.user_id INTO v_holder_user
          FROM public.group_resource_rights rr
          JOIN public.group_memberships gm ON gm.id = rr.holder_membership_id
         WHERE rr.resource_id = p_event.entity_id;
        IF v_holder_user IS NOT NULL THEN
          WITH ins AS (
            INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
            VALUES (p_event.group_id, v_holder_user, 'rule_consequence',
                    jsonb_build_object('rule_version_id', p_rule_version_id,
                                       'message', v_message,
                                       'source_event_id', p_event.uuid_id))
            RETURNING recipient_user_id)
          SELECT COALESCE(array_agg(recipient_user_id), ARRAY[]::uuid[]) INTO v_recipients FROM ins;
          v_notified := array_length(v_recipients, 1);
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
          RETURNING recipient_user_id)
        SELECT COALESCE(array_agg(recipient_user_id), ARRAY[]::uuid[]) INTO v_recipients FROM ins;
        v_notified := COALESCE(array_length(v_recipients,1), 0);
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
          RETURNING recipient_user_id)
        SELECT COALESCE(array_agg(recipient_user_id), ARRAY[]::uuid[]) INTO v_recipients FROM ins;
        v_notified := COALESCE(array_length(v_recipients,1), 0);
      END IF;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'async',
                                'status', 'emitted',
                                'target_kind', 'notification',
                                'audience', v_audience,
                                'recipients', COALESCE(v_notified,0),
                                'recipient_user_ids', to_jsonb(v_recipients));
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'async',
                                'status', 'failed', 'error', v_error,
                                'target_kind', 'notification');
    END;

  ELSIF v_kind = 'consequence.create_pool_charge' THEN
    v_amount := NULLIF(v_fields->>'amount','')::numeric;
    v_currency := COALESCE(v_fields->>'currency', 'MXN');
    v_charge_kind := v_fields->>'charge_kind';
    v_reason := v_fields->>'reason';
    IF v_target_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'target_membership_not_found',
                                'target_kind', 'obligation');
    END IF;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'amount_required',
                                'target_kind', 'obligation');
    END IF;
    IF v_charge_kind NOT IN ('quota','buy_in','fee') THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'invalid_charge_kind',
                                'target_kind', 'obligation');
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
                                'status', 'emitted',
                                'target_kind', 'obligation',
                                'target_id', v_obligation_id,
                                'amount', v_amount, 'currency', v_currency,
                                'charge_kind', v_charge_kind);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error,
                                'target_kind', 'obligation');
    END;

  ELSIF v_kind = 'consequence.start_vote' THEN
    v_title := COALESCE(v_fields->>'title', 'Decisión generada por regla');
    v_decision_type := COALESCE(v_fields->>'decision_type', 'proposal');
    v_method := COALESCE(v_fields->>'method', 'majority');
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
                                'status', 'emitted',
                                'target_kind', 'decision',
                                'target_id', v_decision_id,
                                'decision_type', v_decision_type, 'method', v_method,
                                'reference_kind', v_ref_kind);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error,
                                'target_kind', 'decision');
    END;

  ELSIF v_kind = 'consequence.lock_resource' THEN
    v_reason := v_fields->>'reason';
    IF p_event.entity_id IS NULL OR p_event.entity_kind <> 'resource' THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'event_not_resource_scoped',
                                'target_kind', 'resource');
    END IF;
    BEGIN
      PERFORM public.lock_fund(p_event.entity_id, COALESCE(v_reason, 'Bloqueado por regla'), NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted',
                                'target_kind', 'resource',
                                'target_id', p_event.entity_id);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error,
                                'target_kind', 'resource');
    END;

  ELSIF v_kind = 'consequence.unlock_resource' THEN
    v_reason := v_fields->>'reason';
    IF p_event.entity_id IS NULL OR p_event.entity_kind <> 'resource' THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'event_not_resource_scoped',
                                'target_kind', 'resource');
    END IF;
    BEGIN
      PERFORM public.unlock_fund(p_event.entity_id, COALESCE(v_reason, 'Desbloqueado por regla'), NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted',
                                'target_kind', 'resource',
                                'target_id', p_event.entity_id);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error,
                                'target_kind', 'resource');
    END;

  ELSIF v_kind = 'consequence.update_resource_value' THEN
    v_amount := NULLIF(v_fields->>'value','')::numeric;
    v_unit := COALESCE(v_fields->>'unit', 'MXN');
    v_basis := v_fields->>'basis';
    IF p_event.entity_id IS NULL OR p_event.entity_kind <> 'resource' THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'event_not_resource_scoped',
                                'target_kind', 'resource');
    END IF;
    IF v_amount IS NULL OR v_amount < 0 THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'value_required',
                                'target_kind', 'resource');
    END IF;
    BEGIN
      PERFORM public.update_resource_value(p_event.entity_id, v_amount, v_unit, v_basis);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted',
                                'target_kind', 'resource',
                                'target_id', p_event.entity_id,
                                'value', v_amount, 'unit', v_unit);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error,
                                'target_kind', 'resource');
    END;

  ELSIF v_kind = 'consequence.transfer_resource' THEN
    v_to_membership := NULLIF(v_fields->>'to_membership_id','')::uuid;
    v_reason := v_fields->>'reason';
    IF p_event.entity_id IS NULL OR p_event.entity_kind <> 'resource' THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'event_not_resource_scoped',
                                'target_kind', 'resource');
    END IF;
    IF v_to_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'to_membership_required',
                                'target_kind', 'resource');
    END IF;
    BEGIN
      PERFORM public.transfer_right(p_event.entity_id, v_to_membership,
                                    COALESCE(v_reason, 'Transferido por regla'), NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted',
                                'target_kind', 'resource',
                                'target_id', p_event.entity_id,
                                'to_membership_id', v_to_membership);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error,
                                'target_kind', 'resource');
    END;

  -- =========================================================================
  -- NEW: consequence.create_obligation (peer-to-peer, non-punitive)
  -- =========================================================================
  ELSIF v_kind = 'consequence.create_obligation' THEN
    v_counterparty := v_fields->>'counterparty';
    v_amount       := NULLIF(v_fields->>'amount','')::numeric;
    v_currency     := COALESCE(v_fields->>'currency', 'MXN');
    v_reason       := v_fields->>'reason';
    IF v_counterparty IS NULL OR v_counterparty NOT IN ('target','owner','custodian','holder') THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'invalid_counterparty',
                                'target_kind', 'obligation');
    END IF;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'amount_required',
                                'target_kind', 'obligation');
    END IF;
    IF v_actor_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'actor_membership_not_found',
                                'target_kind', 'obligation');
    END IF;

    -- Resolve counterparty
    v_counterparty_membership := NULL;
    IF v_counterparty = 'target' THEN
      -- Explicit target only — do NOT fall back to actor (would be self-debt)
      IF p_event.payload->>'target_user_id' IS NULL AND p_event.payload->>'target' IS NULL THEN
        RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                  'status', 'failed', 'error', 'target_not_in_event_payload',
                                  'target_kind', 'obligation');
      END IF;
      v_target_user_id := COALESCE(
        NULLIF(p_event.payload->>'target_user_id','')::uuid,
        NULLIF(p_event.payload->>'target','')::uuid);
      SELECT id INTO v_counterparty_membership FROM public.group_memberships
       WHERE group_id = p_event.group_id AND user_id = v_target_user_id;
      IF v_counterparty_membership IS NULL THEN
        -- target may already be a membership_id
        SELECT id INTO v_counterparty_membership FROM public.group_memberships
         WHERE group_id = p_event.group_id AND id = v_target_user_id;
      END IF;
    ELSIF v_counterparty = 'owner' THEN
      IF p_event.entity_id IS NULL OR p_event.entity_kind <> 'resource' THEN
        RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                  'status', 'failed', 'error', 'event_not_resource_scoped',
                                  'target_kind', 'obligation');
      END IF;
      SELECT owner_membership_id INTO v_counterparty_membership
        FROM public.group_resources WHERE id = p_event.entity_id;
    ELSIF v_counterparty = 'custodian' THEN
      IF p_event.entity_id IS NULL OR p_event.entity_kind <> 'resource' THEN
        RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                  'status', 'failed', 'error', 'event_not_resource_scoped',
                                  'target_kind', 'obligation');
      END IF;
      SELECT custodian_membership_id INTO v_counterparty_membership
        FROM public.group_resource_assets WHERE resource_id = p_event.entity_id;
    ELSIF v_counterparty = 'holder' THEN
      IF p_event.entity_id IS NULL OR p_event.entity_kind <> 'resource' THEN
        RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                  'status', 'failed', 'error', 'event_not_resource_scoped',
                                  'target_kind', 'obligation');
      END IF;
      SELECT holder_membership_id INTO v_counterparty_membership
        FROM public.group_resource_rights WHERE resource_id = p_event.entity_id;
    END IF;

    IF v_counterparty_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed',
                                'error', 'counterparty_not_resolvable',
                                'counterparty', v_counterparty,
                                'target_kind', 'obligation');
    END IF;
    IF v_counterparty_membership = v_actor_membership THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed',
                                'error', 'self_debt_not_allowed',
                                'counterparty', v_counterparty,
                                'target_kind', 'obligation');
    END IF;

    BEGIN
      v_obligation_id := public.record_peer_obligation(
        p_group_id => p_event.group_id,
        p_owed_by_membership_id => v_actor_membership,
        p_owed_to_membership_id => v_counterparty_membership,
        p_amount => v_amount,
        p_unit => v_currency,
        p_reason => COALESCE(v_reason, 'Generado por regla con engine'),
        p_source_resource_id => CASE WHEN p_event.entity_kind='resource'
                                     THEN p_event.entity_id ELSE NULL END,
        p_rule_version_id => p_rule_version_id,
        p_source_event_id => p_event.uuid_id,
        p_client_id => NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted',
                                'target_kind', 'obligation',
                                'target_id', v_obligation_id,
                                'counterparty', v_counterparty,
                                'counterparty_membership_id', v_counterparty_membership,
                                'amount', v_amount,
                                'currency', v_currency);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error,
                                'target_kind', 'obligation');
    END;

  ELSE
    RETURN jsonb_build_object('kind', COALESCE(v_kind,'<null>'),
                              'execution', 'unknown',
                              'status', 'skipped', 'error', 'unknown_consequence_kind',
                              'target_kind', NULL);
  END IF;
END;
$$;

-- =============================================================================
-- B6: evaluate_rules_for_event — emit rule.consequence.executed after eval insert
-- =============================================================================
CREATE OR REPLACE FUNCTION public.evaluate_rules_for_event(
  p_event_uuid_id uuid,
  p_mode text DEFAULT 'sync',
  p_parent_evaluation_id uuid DEFAULT NULL
) RETURNS SETOF uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_depth         int := 0;
  v_parent_depth  int;
  v_parent_chain  uuid[] := ARRAY[]::uuid[];
  v_max_depth     constant int := 5;
  v_event         public.group_events%rowtype;
  v_rv            public.group_rule_versions%rowtype;
  v_eval_id       uuid;
  v_idem          text;
  v_cycle         boolean;
  v_predicate_outcome jsonb;
  v_actions_emitted jsonb := '[]'::jsonb;
  v_conseq jsonb;
  v_action_result jsonb;
  v_event_resource_type text;
  v_has_match boolean;
  v_emitted_item jsonb;
BEGIN
  IF p_parent_evaluation_id IS NOT NULL THEN
    SELECT depth INTO v_parent_depth
      FROM public.group_rule_evaluations
     WHERE id = p_parent_evaluation_id;
    v_depth := COALESCE(v_parent_depth, 0) + 1;
    WITH RECURSIVE chain AS (
      SELECT id, rule_version_id, parent_evaluation_id
        FROM public.group_rule_evaluations
       WHERE id = p_parent_evaluation_id
       UNION ALL
      SELECT e.id, e.rule_version_id, e.parent_evaluation_id
        FROM public.group_rule_evaluations e
        JOIN chain c ON c.parent_evaluation_id = e.id
    )
    SELECT COALESCE(array_agg(rule_version_id), ARRAY[]::uuid[])
      INTO v_parent_chain
      FROM chain;
  ELSE
    v_depth := COALESCE(nullif(current_setting('ruul.rule_eval_depth', true), '')::int, 0);
  END IF;

  IF v_depth >= v_max_depth THEN
    RAISE EXCEPTION 'rule evaluation depth % exceeds max % for event %',
      v_depth, v_max_depth, p_event_uuid_id;
  END IF;

  IF p_mode NOT IN ('sync','async') THEN
    RAISE EXCEPTION 'invalid mode %', p_mode;
  END IF;

  SELECT * INTO v_event FROM public.group_events WHERE uuid_id = p_event_uuid_id;
  IF v_event.id IS NULL THEN
    RAISE EXCEPTION 'event % not found', p_event_uuid_id;
  END IF;

  IF v_event.entity_kind = 'resource' AND v_event.entity_id IS NOT NULL THEN
    SELECT resource_type INTO v_event_resource_type
      FROM public.group_resources WHERE id = v_event.entity_id;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.group_rule_versions rv
    JOIN public.group_rules r ON r.current_version_id = rv.id
    WHERE r.group_id = v_event.group_id
      AND r.status = 'active'
      AND rv.execution_mode = 'engine'
      AND rv.trigger_event_type = v_event.event_type
      AND (r.scope_resource_type IS NULL OR r.scope_resource_type = v_event_resource_type)
      AND (r.scope_resource_id IS NULL OR r.scope_resource_id = v_event.entity_id)
  ) INTO v_has_match;

  IF NOT v_has_match THEN
    IF p_mode = 'async' THEN
      INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
      SELECT v_event.group_id, v_event.actor_user_id, 'rule_evaluated',
             jsonb_build_object('event_uuid_id', p_event_uuid_id, 'event_type', v_event.event_type)
      WHERE v_event.actor_user_id IS NOT NULL;
    END IF;
    RETURN;
  END IF;

  PERFORM set_config('ruul.rule_eval_depth', (v_depth + 1)::text, true);

  FOR v_rv IN
    SELECT rv.* FROM public.group_rule_versions rv
    JOIN public.group_rules r ON r.current_version_id = rv.id
    WHERE r.group_id = v_event.group_id
      AND r.status = 'active'
      AND rv.execution_mode = 'engine'
      AND rv.trigger_event_type = v_event.event_type
      AND (r.scope_resource_type IS NULL OR r.scope_resource_type = v_event_resource_type)
      AND (r.scope_resource_id IS NULL OR r.scope_resource_id = v_event.entity_id)
  LOOP
    v_idem := p_event_uuid_id::text || '|' || v_rv.id::text;
    v_cycle := v_rv.id = ANY(v_parent_chain);

    v_predicate_outcome := public._rule_eval_predicate(v_rv.condition_tree, v_event);
    v_actions_emitted := '[]'::jsonb;

    IF NOT v_cycle AND (v_predicate_outcome->>'passed')::boolean THEN
      FOR v_conseq IN SELECT jsonb_array_elements(COALESCE(v_rv.consequences,'[]'::jsonb)) LOOP
        v_action_result := public._rule_eval_dispatch(v_conseq, v_event, v_rv.id);
        v_actions_emitted := v_actions_emitted || jsonb_build_array(v_action_result);
      END LOOP;
    END IF;

    INSERT INTO public.group_rule_evaluations (
      rule_version_id, group_id, source_event_id, matched,
      consequences_emitted, idempotency_key,
      parent_evaluation_id, depth, matched_predicate, cycle_detected,
      actions_emitted
    ) VALUES (
      v_rv.id, v_event.group_id, p_event_uuid_id,
      (v_predicate_outcome->>'passed')::boolean,
      COALESCE(v_rv.consequences, '[]'::jsonb), v_idem,
      p_parent_evaluation_id, v_depth,
      v_predicate_outcome, v_cycle,
      v_actions_emitted
    )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING id INTO v_eval_id;

    -- D.15 lineage: emit rule.consequence.executed per emitted/failed action,
    -- carrying target_kind/target_id/status/rule_version_id for audit trail.
    IF v_eval_id IS NOT NULL THEN
      FOR v_emitted_item IN SELECT jsonb_array_elements(v_actions_emitted) LOOP
        IF (v_emitted_item->>'status') IN ('emitted','failed') THEN
          INSERT INTO public.group_events (
            group_id, actor_user_id, event_type, entity_kind, entity_id, summary, payload
          ) VALUES (
            v_event.group_id, v_event.actor_user_id,
            'rule.consequence.executed', 'rule_consequence', v_eval_id,
            format('Engine ejecutó %s [%s]',
                   v_emitted_item->>'kind',
                   v_emitted_item->>'status'),
            jsonb_build_object(
              'consequence_kind', v_emitted_item->>'kind',
              'target_kind',      v_emitted_item->>'target_kind',
              'target_id',        v_emitted_item->>'target_id',
              'status',           v_emitted_item->>'status',
              'rule_version_id',  v_rv.id,
              'source_event_uuid_id', p_event_uuid_id,
              'recipient_user_ids', v_emitted_item->'recipient_user_ids')
          );
        END IF;
      END LOOP;

      RETURN NEXT v_eval_id;
    END IF;
  END LOOP;

  IF p_mode = 'async' THEN
    INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
    SELECT v_event.group_id, v_event.actor_user_id, 'rule_evaluated',
           jsonb_build_object('event_uuid_id', p_event_uuid_id, 'event_type', v_event.event_type)
    WHERE v_event.actor_user_id IS NOT NULL;
  END IF;

  RETURN;
END;
$$;

COMMIT;
