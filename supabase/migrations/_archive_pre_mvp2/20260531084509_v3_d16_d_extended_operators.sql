-- V3 FASE D.16 — Mig D: extend condition.resource_compare with
--   contains (text substring), in (comma-split), is_null, is_not_null.
-- Shape: value becomes required=false. Dispatcher requires value only when op needs it.

BEGIN;

-- =============================================================================
-- D1: Update condition.resource_compare shape — value optional, ops extended
-- =============================================================================
UPDATE public.rule_shapes_catalog
SET schema = jsonb_build_object(
  'kind','resource_compare',
  'fields', jsonb_build_array(
    jsonb_build_object('key','atom','type','string','label','Atom (resource.*)','required',true),
    jsonb_build_object('key','op','type','enum','label','Operador',
                       'enum', jsonb_build_array(
                         '=','!=','>','<','>=','<=',
                         'contains','in','is_null','is_not_null'),
                       'required',true),
    jsonb_build_object('key','value','type','string',
                       'label','Valor (ignorado para is_null/is_not_null; comma-separated para in)',
                       'required',false))),
    metadata = jsonb_build_object(
      'supports_ops', jsonb_build_array(
        '=','!=','>','<','>=','<=',
        'contains','in','is_null','is_not_null'),
      'contains_semantics','text_substring_only',
      'in_semantics','comma_separated_string_split',
      'is_null_semantics','atom_resolves_to_null_or_jsonb_null')
WHERE shape_key = 'condition.resource_compare';

-- =============================================================================
-- D2: _rule_eval_predicate — extend resource_compare branch with 4 new ops
-- =============================================================================
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
  v_csv_list text[];
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

  ELSIF v_kind = 'condition.resource_compare' THEN
    v_atom_key      := v_fields->>'atom';
    v_op            := v_fields->>'op';
    v_compare_value := v_fields->'value';
    IF v_atom_key IS NULL OR v_op IS NULL THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'missing_atom_or_op', 'kind', v_kind);
    END IF;
    IF v_op NOT IN ('=','!=','>','<','>=','<=','contains','in','is_null','is_not_null') THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'unsupported_op', 'kind', v_kind);
    END IF;
    IF p_event.entity_id IS NULL OR p_event.entity_kind <> 'resource' THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'event_not_resource_scoped', 'kind', v_kind);
    END IF;
    v_atom_value := public._rule_atom_resolve(p_event.entity_id, v_atom_key);

    -- D.16 ops that ignore value
    IF v_op = 'is_null' THEN
      v_match := (v_atom_value IS NULL OR v_atom_value = 'null'::jsonb);
      RETURN jsonb_build_object('passed', v_match,
        'reason', CASE WHEN v_match THEN 'atom_is_null' ELSE 'atom_not_null' END,
        'kind', v_kind,
        'evaluated_value', jsonb_build_object('atom', v_atom_key, 'atom_value', v_atom_value, 'op', v_op));
    ELSIF v_op = 'is_not_null' THEN
      v_match := (v_atom_value IS NOT NULL AND v_atom_value <> 'null'::jsonb);
      RETURN jsonb_build_object('passed', v_match,
        'reason', CASE WHEN v_match THEN 'atom_not_null' ELSE 'atom_is_null' END,
        'kind', v_kind,
        'evaluated_value', jsonb_build_object('atom', v_atom_key, 'atom_value', v_atom_value, 'op', v_op));
    END IF;

    -- All other ops require a value
    IF v_compare_value IS NULL OR v_compare_value = 'null'::jsonb THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'value_required', 'kind', v_kind);
    END IF;
    IF v_atom_value IS NULL OR v_atom_value = 'null'::jsonb THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'atom_null', 'kind', v_kind);
    END IF;

    v_a_type := jsonb_typeof(v_atom_value);
    v_c_type := jsonb_typeof(v_compare_value);

    IF v_op = 'contains' THEN
      IF v_a_type <> 'string' THEN
        RETURN jsonb_build_object('passed', false, 'reason', 'contains_requires_text', 'kind', v_kind,
          'evaluated_value', jsonb_build_object('atom', v_atom_key, 'atom_value', v_atom_value, 'op', v_op));
      END IF;
      v_a_text := v_atom_value   #>> '{}';
      v_c_text := v_compare_value #>> '{}';
      v_match := position(v_c_text IN v_a_text) > 0;
      RETURN jsonb_build_object('passed', v_match,
        'reason', CASE WHEN v_match THEN 'contains' ELSE 'not_contains' END,
        'kind', v_kind,
        'evaluated_value', jsonb_build_object('atom', v_atom_key, 'atom_value', v_atom_value,
                                              'op', v_op, 'compare_value', v_compare_value));
    ELSIF v_op = 'in' THEN
      v_c_text := v_compare_value #>> '{}';
      v_csv_list := string_to_array(v_c_text, ',');
      -- Trim whitespace on each element
      v_csv_list := ARRAY(SELECT btrim(x) FROM unnest(v_csv_list) x);
      v_a_text := v_atom_value #>> '{}';
      v_match := v_a_text = ANY(v_csv_list);
      RETURN jsonb_build_object('passed', v_match,
        'reason', CASE WHEN v_match THEN 'in_set' ELSE 'not_in_set' END,
        'kind', v_kind,
        'evaluated_value', jsonb_build_object('atom', v_atom_key, 'atom_value', v_atom_value,
                                              'op', v_op, 'compare_value', v_compare_value,
                                              'in_set', to_jsonb(v_csv_list)));
    END IF;

    -- Existing ops: = != > < >= <=
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

COMMIT;
