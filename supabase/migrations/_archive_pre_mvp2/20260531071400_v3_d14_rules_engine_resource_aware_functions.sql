-- V3 FASE D.14 — Mig A part 2: atom resolver + predicate/dispatch patches + scope filter
BEGIN;

-- ============================================================================
-- A) Atom resolver (single switch — keeps SQL static, no dynamic SQL)
-- ============================================================================
CREATE OR REPLACE FUNCTION public._rule_atom_resolve(
  p_resource_id uuid,
  p_atom_key    text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_r   public.group_resources%ROWTYPE;
  v_val jsonb;
BEGIN
  IF p_resource_id IS NULL OR p_atom_key IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id;
  IF v_r.id IS NULL THEN RETURN NULL; END IF;

  CASE p_atom_key
    WHEN 'resource.id'                  THEN RETURN to_jsonb(v_r.id::text);
    WHEN 'resource.type'                THEN RETURN to_jsonb(v_r.resource_type);
    WHEN 'resource.name'                THEN RETURN to_jsonb(v_r.name);
    WHEN 'resource.status'              THEN RETURN to_jsonb(v_r.status);
    WHEN 'resource.lifecycle_state'     THEN RETURN to_jsonb(v_r.status);
    WHEN 'resource.unit'                THEN RETURN CASE WHEN v_r.unit IS NULL THEN NULL ELSE to_jsonb(v_r.unit) END;
    WHEN 'resource.archived_at'         THEN RETURN CASE WHEN v_r.archived_at IS NULL THEN NULL ELSE to_jsonb(v_r.archived_at::text) END;
    WHEN 'resource.owner_membership_id' THEN RETURN CASE WHEN v_r.owner_membership_id IS NULL THEN NULL ELSE to_jsonb(v_r.owner_membership_id::text) END;
    WHEN 'resource.value' THEN
      SELECT to_jsonb(current_value) INTO v_val FROM public.group_resource_assets WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.condition' THEN
      SELECT to_jsonb(condition)     INTO v_val FROM public.group_resource_assets WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.custodian_membership_id' THEN
      SELECT CASE WHEN custodian_membership_id IS NULL THEN NULL ELSE to_jsonb(custodian_membership_id::text) END
        INTO v_val FROM public.group_resource_assets WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.holder_membership_id' THEN
      SELECT CASE WHEN holder_membership_id IS NULL THEN NULL ELSE to_jsonb(holder_membership_id::text) END
        INTO v_val FROM public.group_resource_rights WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.is_transferable' THEN
      SELECT to_jsonb(transferable) INTO v_val FROM public.group_resource_rights WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.slot_assignee' THEN
      SELECT CASE WHEN assigned_membership_id IS NULL THEN NULL ELSE to_jsonb(assigned_membership_id::text) END
        INTO v_val FROM public.group_resource_slots WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.threshold' THEN
      SELECT to_jsonb(threshold_target) INTO v_val FROM public.group_resource_funds WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.is_locked' THEN
      SELECT to_jsonb(locked_at IS NOT NULL) INTO v_val FROM public.group_resource_funds WHERE resource_id = p_resource_id;
      RETURN v_val;
    ELSE
      RETURN NULL;
  END CASE;
END;
$$;

REVOKE ALL ON FUNCTION public._rule_atom_resolve(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._rule_atom_resolve(uuid, text) TO authenticated, service_role;

-- ============================================================================
-- B) Predicate dispatcher — add condition.resource_compare branch
-- ============================================================================
CREATE OR REPLACE FUNCTION public._rule_eval_predicate(
  p_condition_tree jsonb,
  p_event public.group_events
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_kind text;
  v_fields jsonb;
  v_actor_membership uuid;
  v_target_user_id uuid;
  v_target_membership uuid;
  v_actor_roles text[];
  v_target_roles text[];
  v_required_roles jsonb;
  v_role text;
  v_match boolean := false;
  v_event_amount numeric;
  v_threshold numeric;
  v_amount_min numeric;
  v_amount_max numeric;
  v_target uuid;
  v_only_self boolean;
  v_lookback int;
  v_prior_count int;
  -- resource_compare
  v_atom_key text;
  v_op text;
  v_compare_value jsonb;
  v_atom_value jsonb;
  v_a_type text;
  v_c_type text;
  v_a_num numeric;
  v_c_num numeric;
  v_a_text text;
  v_c_text text;
  v_reason_text text;
BEGIN
  IF p_condition_tree IS NULL OR p_condition_tree = '{}'::jsonb OR p_condition_tree = 'null'::jsonb THEN
    RETURN jsonb_build_object('passed', true, 'reason', 'no_predicate');
  END IF;
  v_kind := p_condition_tree->>'kind';
  v_fields := COALESCE(p_condition_tree->'fields', '{}'::jsonb);

  IF v_kind = 'condition.actor_role_in' THEN
    v_required_roles := v_fields->'roles';
    IF v_required_roles IS NULL OR jsonb_typeof(v_required_roles) <> 'array' THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'missing_roles', 'kind', v_kind);
    END IF;
    SELECT id INTO v_actor_membership FROM public.group_memberships
     WHERE group_id = p_event.group_id AND user_id = p_event.actor_user_id;
    IF v_actor_membership IS NULL THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'actor_not_member', 'kind', v_kind);
    END IF;
    SELECT COALESCE(array_agg(r.key), ARRAY[]::text[]) INTO v_actor_roles
      FROM public.group_member_roles mr
      JOIN public.group_roles r ON r.id = mr.role_id
     WHERE mr.membership_id = v_actor_membership;
    FOR v_role IN SELECT jsonb_array_elements_text(v_required_roles) LOOP
      IF v_role = ANY(v_actor_roles) THEN v_match := true; EXIT; END IF;
    END LOOP;
    RETURN jsonb_build_object('passed', v_match,
      'reason', CASE WHEN v_match THEN 'role_match' ELSE 'no_role_match' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object('actor_roles', to_jsonb(v_actor_roles)));

  ELSIF v_kind = 'condition.target_role_in' THEN
    v_required_roles := v_fields->'roles';
    IF v_required_roles IS NULL OR jsonb_typeof(v_required_roles) <> 'array' THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'missing_roles', 'kind', v_kind);
    END IF;
    v_target_user_id := NULLIF(p_event.payload->>'target_user_id','')::uuid;
    IF v_target_user_id IS NULL THEN
      v_target_user_id := NULLIF(p_event.payload->>'target','')::uuid;
    END IF;
    IF v_target_user_id IS NULL THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'no_target_in_payload', 'kind', v_kind);
    END IF;
    SELECT id INTO v_target_membership FROM public.group_memberships
     WHERE group_id = p_event.group_id AND user_id = v_target_user_id;
    IF v_target_membership IS NULL THEN
      SELECT id INTO v_target_membership FROM public.group_memberships
       WHERE group_id = p_event.group_id AND id = v_target_user_id;
    END IF;
    IF v_target_membership IS NULL THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'target_not_member', 'kind', v_kind);
    END IF;
    SELECT COALESCE(array_agg(r.key), ARRAY[]::text[]) INTO v_target_roles
      FROM public.group_member_roles mr
      JOIN public.group_roles r ON r.id = mr.role_id
     WHERE mr.membership_id = v_target_membership;
    FOR v_role IN SELECT jsonb_array_elements_text(v_required_roles) LOOP
      IF v_role = ANY(v_target_roles) THEN v_match := true; EXIT; END IF;
    END LOOP;
    RETURN jsonb_build_object('passed', v_match,
      'reason', CASE WHEN v_match THEN 'target_role_match' ELSE 'no_target_role_match' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object('target_roles', to_jsonb(v_target_roles)));

  ELSIF v_kind = 'condition.amount_above' THEN
    v_threshold := COALESCE((v_fields->>'amount')::numeric, 0);
    v_event_amount := COALESCE((p_event.payload->>'amount')::numeric, 0);
    v_match := v_event_amount > v_threshold;
    RETURN jsonb_build_object('passed', v_match,
      'reason', CASE WHEN v_match THEN 'above_threshold' ELSE 'below_threshold' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object('event_amount', v_event_amount, 'threshold', v_threshold));

  ELSIF v_kind = 'condition.amount_between' THEN
    v_amount_min := COALESCE((v_fields->>'amount_min')::numeric, 0);
    v_amount_max := COALESCE((v_fields->>'amount_max')::numeric, 0);
    v_event_amount := COALESCE((p_event.payload->>'amount')::numeric, 0);
    v_match := v_event_amount >= v_amount_min AND v_event_amount <= v_amount_max;
    RETURN jsonb_build_object('passed', v_match,
      'reason', CASE WHEN v_match THEN 'within_range' ELSE 'out_of_range' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object(
        'event_amount', v_event_amount,
        'amount_min', v_amount_min,
        'amount_max', v_amount_max));

  ELSIF v_kind = 'condition.target_self' THEN
    v_only_self := COALESCE((v_fields->>'only_self')::boolean, true);
    v_target := NULLIF(p_event.payload->>'target_user_id','')::uuid;
    IF NOT v_only_self THEN
      RETURN jsonb_build_object('passed', true, 'reason', 'self_check_disabled', 'kind', v_kind);
    END IF;
    v_match := (v_target IS NOT DISTINCT FROM p_event.actor_user_id);
    RETURN jsonb_build_object('passed', v_match,
      'reason', CASE WHEN v_match THEN 'actor_is_target' ELSE 'actor_not_target' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object('actor', p_event.actor_user_id, 'target', v_target));

  ELSIF v_kind = 'condition.is_first_offense' THEN
    v_lookback := COALESCE((v_fields->>'lookback_days')::int, 30);
    SELECT count(*) INTO v_prior_count
      FROM public.group_sanctions s
      JOIN public.group_memberships m ON m.id = s.target_membership_id
     WHERE m.user_id = p_event.actor_user_id
       AND s.group_id = p_event.group_id
       AND s.created_at > now() - (v_lookback || ' days')::interval;
    v_match := v_prior_count = 0;
    RETURN jsonb_build_object('passed', v_match,
      'reason', CASE WHEN v_match THEN 'no_prior_sanctions' ELSE 'has_prior_sanctions' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object(
        'prior_count', v_prior_count,
        'lookback_days', v_lookback));

  -- ============================================================================
  -- NEW: condition.resource_compare (mini-AST)
  -- ============================================================================
  ELSIF v_kind = 'condition.resource_compare' THEN
    v_atom_key := v_fields->>'atom';
    v_op := v_fields->>'op';
    v_compare_value := v_fields->'value';
    IF v_atom_key IS NULL OR v_op IS NULL THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'missing_atom_or_op', 'kind', v_kind);
    END IF;
    IF v_op NOT IN ('=','!=','>','<','>=','<=') THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'unsupported_op', 'kind', v_kind);
    END IF;
    IF p_event.entity_id IS NULL OR p_event.entity_kind <> 'resource' THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'event_not_resource_scoped', 'kind', v_kind);
    END IF;
    v_atom_value := public._rule_atom_resolve(p_event.entity_id, v_atom_key);
    IF v_atom_value IS NULL OR v_atom_value = 'null'::jsonb THEN
      v_match := false;
      v_reason_text := 'atom_null';
    ELSE
      v_a_type := jsonb_typeof(v_atom_value);
      v_c_type := jsonb_typeof(v_compare_value);
      -- numeric coercion: if atom is numeric OR compare is numeric AND atom string parses as number
      IF v_a_type = 'number' OR v_c_type = 'number' THEN
        BEGIN
          v_a_num := CASE v_a_type WHEN 'number' THEN (v_atom_value)::text::numeric
                                   WHEN 'string' THEN (v_atom_value #>> '{}')::numeric
                                   ELSE NULL END;
          v_c_num := CASE v_c_type WHEN 'number' THEN (v_compare_value)::text::numeric
                                   WHEN 'string' THEN (v_compare_value #>> '{}')::numeric
                                   ELSE NULL END;
        EXCEPTION WHEN OTHERS THEN
          v_a_num := NULL; v_c_num := NULL;
        END;
        IF v_a_num IS NULL OR v_c_num IS NULL THEN
          v_match := false;
          v_reason_text := 'numeric_coercion_failed';
        ELSE
          v_match := CASE v_op
                       WHEN '='  THEN v_a_num =  v_c_num
                       WHEN '!=' THEN v_a_num <> v_c_num
                       WHEN '>'  THEN v_a_num >  v_c_num
                       WHEN '<'  THEN v_a_num <  v_c_num
                       WHEN '>=' THEN v_a_num >= v_c_num
                       WHEN '<=' THEN v_a_num <= v_c_num
                     END;
          v_reason_text := CASE WHEN v_match THEN 'matched' ELSE 'not_matched' END;
        END IF;
      ELSIF v_a_type = 'boolean' OR v_c_type = 'boolean' THEN
        -- boolean: only = and != make sense
        IF v_op NOT IN ('=','!=') THEN
          v_match := false;
          v_reason_text := 'boolean_op_unsupported';
        ELSE
          v_match := CASE v_op
                       WHEN '='  THEN v_atom_value =  v_compare_value
                       WHEN '!=' THEN v_atom_value <> v_compare_value
                     END;
          v_reason_text := CASE WHEN v_match THEN 'matched' ELSE 'not_matched' END;
        END IF;
      ELSE
        v_a_text := v_atom_value   #>> '{}';
        v_c_text := v_compare_value #>> '{}';
        v_match := CASE v_op
                     WHEN '='  THEN v_a_text =  v_c_text
                     WHEN '!=' THEN v_a_text <> v_c_text
                     WHEN '>'  THEN v_a_text >  v_c_text
                     WHEN '<'  THEN v_a_text <  v_c_text
                     WHEN '>=' THEN v_a_text >= v_c_text
                     WHEN '<=' THEN v_a_text <= v_c_text
                   END;
        v_reason_text := CASE WHEN v_match THEN 'matched' ELSE 'not_matched' END;
      END IF;
    END IF;
    RETURN jsonb_build_object('passed', v_match,
      'reason', v_reason_text,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object(
        'atom', v_atom_key, 'atom_value', v_atom_value,
        'op', v_op, 'compare_value', v_compare_value));

  ELSE
    RETURN jsonb_build_object('passed', false, 'reason', 'unknown_predicate_kind',
                              'kind', COALESCE(v_kind,'<null>'));
  END IF;
END;
$$;

-- ============================================================================
-- C) Action dispatcher — extend with 4 new resource consequences + extended audiences
-- ============================================================================
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
  v_closes_at timestamptz;
  v_use_entity boolean;
  v_ref_kind text;
  v_ref_id uuid;
  -- new
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
        p_legitimacy_source => NULL,
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

  -- =========================================================================
  -- NEW: consequence.lock_resource
  -- =========================================================================
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

  -- =========================================================================
  -- NEW: consequence.unlock_resource
  -- =========================================================================
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

  -- =========================================================================
  -- NEW: consequence.update_resource_value
  -- =========================================================================
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

  -- =========================================================================
  -- NEW: consequence.transfer_resource (rights only)
  -- =========================================================================
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

-- ============================================================================
-- D) evaluate_rules_for_event — enforce scope_resource_type / scope_resource_id
-- ============================================================================
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
  PERFORM set_config('ruul.rule_eval_depth', (v_depth + 1)::text, true);

  IF p_mode NOT IN ('sync','async') THEN
    RAISE EXCEPTION 'invalid mode %', p_mode;
  END IF;

  SELECT * INTO v_event FROM public.group_events WHERE uuid_id = p_event_uuid_id;
  IF v_event.id IS NULL THEN
    RAISE EXCEPTION 'event % not found', p_event_uuid_id;
  END IF;

  -- For scope filter: only look up resource type when the event is resource-scoped.
  IF v_event.entity_kind = 'resource' AND v_event.entity_id IS NOT NULL THEN
    SELECT resource_type INTO v_event_resource_type
      FROM public.group_resources WHERE id = v_event.entity_id;
  END IF;

  FOR v_rv IN
    SELECT rv.* FROM public.group_rule_versions rv
    JOIN public.group_rules r ON r.current_version_id = rv.id
    WHERE r.group_id = v_event.group_id
      AND r.status = 'active'
      AND rv.execution_mode = 'engine'
      AND rv.trigger_event_type = v_event.event_type
      -- Scope filter (NEW): rule's declared resource type must match (or be null = wildcard)
      AND (r.scope_resource_type IS NULL
           OR r.scope_resource_type = v_event_resource_type)
      AND (r.scope_resource_id IS NULL
           OR r.scope_resource_id = v_event.entity_id)
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
    IF v_eval_id IS NOT NULL THEN
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
