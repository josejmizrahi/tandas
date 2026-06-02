-- V3 FASE D.15 — Mig A: compat enforcement in validate_rule_shape
-- + rule_shape_compatibility(shape_key) returning full shapes.
-- Founder doctrine: hard-reject, not soft-warn. Legacy rules already persisted
-- with incompatible combos keep working (their current_version_id is intact);
-- only NEW create_engine_rule calls are gated.

BEGIN;

-- =============================================================================
-- A1: validate_rule_shape — extend with compat checks
-- =============================================================================
CREATE OR REPLACE FUNCTION public.validate_rule_shape(p_shape jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_shape_key text := p_shape->>'shape_key';
  v_cond jsonb     := p_shape->'condition_tree';
  v_conseqs jsonb  := p_shape->'consequences';
  v_trigger_row public.rule_shapes_catalog%rowtype;
  v_cond_row public.rule_shapes_catalog%rowtype;
  v_conseq_row public.rule_shapes_catalog%rowtype;
  v_errors jsonb := '[]'::jsonb;
  v_cond_kind text;
  v_action_kind text;
  v_action_item jsonb;
  v_action_idx int := 0;
  v_field jsonb;
  v_field_key text;
  v_field_type text;
  v_field_required boolean;
  v_field_value jsonb;
  v_holder jsonb;
  v_holder_label text;
  v_compat_conditions jsonb;
  v_compat_consequences jsonb;
BEGIN
  IF v_shape_key IS NULL OR length(v_shape_key) = 0 THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'path','shape_key','code','required','message','shape_key requerido'));
    RETURN jsonb_build_object('valid', false, 'errors', v_errors);
  END IF;
  SELECT * INTO v_trigger_row FROM public.rule_shapes_catalog WHERE shape_key = v_shape_key;
  IF NOT FOUND THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'path','shape_key','code','unknown',
      'message', format('shape %s no existe', v_shape_key)));
    RETURN jsonb_build_object('valid', false, 'errors', v_errors);
  END IF;
  IF v_trigger_row.category <> 'trigger' THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'path','shape_key','code','wrong_category',
      'message', format('shape %s no es un trigger (es %s)', v_shape_key, v_trigger_row.category)));
    RETURN jsonb_build_object('valid', false, 'errors', v_errors);
  END IF;

  v_compat_conditions   := COALESCE(v_trigger_row.schema->'compatible_conditions',   '[]'::jsonb);
  v_compat_consequences := COALESCE(v_trigger_row.schema->'compatible_consequences', '[]'::jsonb);

  -- condition_tree
  IF v_cond IS NOT NULL AND v_cond <> 'null'::jsonb THEN
    IF jsonb_typeof(v_cond) <> 'object' THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'path','condition_tree','code','type','message','condition_tree debe ser objeto'));
    ELSE
      v_cond_kind := v_cond->>'kind';
      IF v_cond_kind IS NULL THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'path','condition_tree.kind','code','required','message','kind requerido'));
      ELSE
        SELECT * INTO v_cond_row FROM public.rule_shapes_catalog WHERE shape_key = v_cond_kind;
        IF NOT FOUND OR v_cond_row.category <> 'condition' THEN
          v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'path','condition_tree.kind','code','unknown',
            'message', format('condition %s no existe', v_cond_kind)));
        ELSE
          -- D.15 compat check: condition kind must be in trigger's compatible_conditions
          IF NOT (v_compat_conditions @> to_jsonb(v_cond_kind)) THEN
            v_errors := v_errors || jsonb_build_array(jsonb_build_object(
              'path','condition_tree.kind','code','not_compatible',
              'message', format('condition %s no es compatible con trigger %s', v_cond_kind, v_shape_key),
              'allowed', v_compat_conditions));
          END IF;
          -- type/required/enum checks on condition fields
          v_holder := v_cond->'fields';
          IF v_holder IS NULL OR jsonb_typeof(v_holder) <> 'object' THEN
            v_holder := '{}'::jsonb;
          END IF;
          FOR v_field IN SELECT jsonb_array_elements(v_cond_row.schema->'fields') LOOP
            v_field_key      := v_field->>'key';
            v_field_type     := coalesce(v_field->>'type','string');
            v_field_required := coalesce((v_field->>'required')::boolean, false);
            v_field_value    := v_holder->v_field_key;
            v_holder_label   := format('condition_tree.fields.%s', v_field_key);
            IF v_field_required AND (v_field_value IS NULL OR v_field_value = 'null'::jsonb) THEN
              v_errors := v_errors || jsonb_build_array(jsonb_build_object(
                'path', v_holder_label, 'code','required',
                'message', format('%s requerido', v_field_key)));
              CONTINUE;
            END IF;
            IF v_field_value IS NULL THEN CONTINUE; END IF;
            IF v_field_type IN ('number','integer') AND jsonb_typeof(v_field_value) <> 'number' THEN
              v_errors := v_errors || jsonb_build_array(jsonb_build_object(
                'path', v_holder_label, 'code','type',
                'message', format('%s debe ser número', v_field_key)));
            ELSIF v_field_type = 'boolean' AND jsonb_typeof(v_field_value) <> 'boolean' THEN
              v_errors := v_errors || jsonb_build_array(jsonb_build_object(
                'path', v_holder_label, 'code','type',
                'message', format('%s debe ser booleano', v_field_key)));
            ELSIF v_field_type IN ('string','enum') AND jsonb_typeof(v_field_value) <> 'string' THEN
              v_errors := v_errors || jsonb_build_array(jsonb_build_object(
                'path', v_holder_label, 'code','type',
                'message', format('%s debe ser texto', v_field_key)));
            ELSIF v_field_type = 'string_array' AND jsonb_typeof(v_field_value) <> 'array' THEN
              v_errors := v_errors || jsonb_build_array(jsonb_build_object(
                'path', v_holder_label, 'code','type',
                'message', format('%s debe ser arreglo', v_field_key)));
            END IF;
            IF v_field_type = 'enum' AND (v_field ? 'enum')
               AND jsonb_typeof(v_field_value) = 'string'
               AND NOT (v_field->'enum' @> to_jsonb(v_field_value #>> '{}')) THEN
              v_errors := v_errors || jsonb_build_array(jsonb_build_object(
                'path', v_holder_label, 'code','enum',
                'message', format('%s fuera del set permitido', v_field_key)));
            END IF;
          END LOOP;
        END IF;
      END IF;
    END IF;
  END IF;

  -- consequences
  IF v_conseqs IS NULL OR jsonb_typeof(v_conseqs) <> 'array' THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'path','consequences','code','required',
      'message','consequences debe ser arreglo de al menos un elemento'));
  ELSIF jsonb_array_length(v_conseqs) = 0 THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'path','consequences','code','required',
      'message','consequences debe tener al menos un elemento'));
  ELSE
    FOR v_action_item IN SELECT jsonb_array_elements(v_conseqs) LOOP
      v_action_idx := v_action_idx + 1;
      IF jsonb_typeof(v_action_item) <> 'object' THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'path', format('consequences[%s]', v_action_idx - 1),
          'code','type','message','elemento debe ser objeto'));
        CONTINUE;
      END IF;
      v_action_kind := v_action_item->>'kind';
      IF v_action_kind IS NULL THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'path', format('consequences[%s].kind', v_action_idx - 1),
          'code','required','message','kind requerido'));
        CONTINUE;
      END IF;
      SELECT * INTO v_conseq_row FROM public.rule_shapes_catalog WHERE shape_key = v_action_kind;
      IF NOT FOUND OR v_conseq_row.category <> 'consequence' THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'path', format('consequences[%s].kind', v_action_idx - 1),
          'code','unknown',
          'message', format('consequence %s no existe', v_action_kind)));
        CONTINUE;
      END IF;
      -- D.15 compat check
      IF NOT (v_compat_consequences @> to_jsonb(v_action_kind)) THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'path', format('consequences[%s].kind', v_action_idx - 1),
          'code','not_compatible',
          'message', format('consequence %s no es compatible con trigger %s', v_action_kind, v_shape_key),
          'allowed', v_compat_consequences));
      END IF;
      v_holder := v_action_item->'fields';
      IF v_holder IS NULL OR jsonb_typeof(v_holder) <> 'object' THEN
        v_holder := '{}'::jsonb;
      END IF;
      FOR v_field IN SELECT jsonb_array_elements(v_conseq_row.schema->'fields') LOOP
        v_field_key      := v_field->>'key';
        v_field_type     := coalesce(v_field->>'type','string');
        v_field_required := coalesce((v_field->>'required')::boolean, false);
        v_field_value    := v_holder->v_field_key;
        v_holder_label   := format('consequences[%s].fields.%s', v_action_idx - 1, v_field_key);
        IF v_field_required AND (v_field_value IS NULL OR v_field_value = 'null'::jsonb) THEN
          v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'path', v_holder_label, 'code','required',
            'message', format('%s requerido', v_field_key)));
          CONTINUE;
        END IF;
        IF v_field_value IS NULL THEN CONTINUE; END IF;
        IF v_field_type IN ('number','integer') AND jsonb_typeof(v_field_value) <> 'number' THEN
          v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'path', v_holder_label, 'code','type',
            'message', format('%s debe ser número', v_field_key)));
        ELSIF v_field_type = 'boolean' AND jsonb_typeof(v_field_value) <> 'boolean' THEN
          v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'path', v_holder_label, 'code','type',
            'message', format('%s debe ser booleano', v_field_key)));
        ELSIF v_field_type IN ('string','enum') AND jsonb_typeof(v_field_value) <> 'string' THEN
          v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'path', v_holder_label, 'code','type',
            'message', format('%s debe ser texto', v_field_key)));
        ELSIF v_field_type = 'string_array' AND jsonb_typeof(v_field_value) <> 'array' THEN
          v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'path', v_holder_label, 'code','type',
            'message', format('%s debe ser arreglo', v_field_key)));
        END IF;
        IF v_field_type = 'enum' AND (v_field ? 'enum')
           AND jsonb_typeof(v_field_value) = 'string'
           AND NOT (v_field->'enum' @> to_jsonb(v_field_value #>> '{}')) THEN
          v_errors := v_errors || jsonb_build_array(jsonb_build_object(
            'path', v_holder_label, 'code','enum',
            'message', format('%s fuera del set permitido', v_field_key)));
        END IF;
      END LOOP;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'valid', jsonb_array_length(v_errors) = 0,
    'errors', v_errors,
    'shape_key', v_shape_key,
    'trigger_event_type', v_trigger_row.schema->>'event_type'
  );
END;
$$;

-- =============================================================================
-- A2: rule_shape_compatibility(shape_key) — returns full shapes, not just keys
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rule_shape_compatibility(p_shape_key text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_trigger public.rule_shapes_catalog%rowtype;
  v_compat_conditions jsonb;
  v_compat_consequences jsonb;
  v_condition_shapes jsonb;
  v_consequence_shapes jsonb;
BEGIN
  SELECT * INTO v_trigger FROM public.rule_shapes_catalog WHERE shape_key = p_shape_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'shape % not found', p_shape_key USING errcode = '22023';
  END IF;
  IF v_trigger.category <> 'trigger' THEN
    RAISE EXCEPTION 'shape % is not a trigger (is %)', p_shape_key, v_trigger.category USING errcode = '22023';
  END IF;

  v_compat_conditions   := COALESCE(v_trigger.schema->'compatible_conditions',   '[]'::jsonb);
  v_compat_consequences := COALESCE(v_trigger.schema->'compatible_consequences', '[]'::jsonb);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'shape_key', s.shape_key,
      'category', s.category,
      'display_name', s.display_name,
      'description', s.description,
      'schema', s.schema,
      'resource_types', s.resource_types,
      'metadata', s.metadata
    ) ORDER BY s.shape_key), '[]'::jsonb)
  INTO v_condition_shapes
  FROM public.rule_shapes_catalog s
  WHERE s.category = 'condition'
    AND v_compat_conditions @> to_jsonb(s.shape_key);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'shape_key', s.shape_key,
      'category', s.category,
      'display_name', s.display_name,
      'description', s.description,
      'schema', s.schema,
      'resource_types', s.resource_types,
      'metadata', s.metadata
    ) ORDER BY s.shape_key), '[]'::jsonb)
  INTO v_consequence_shapes
  FROM public.rule_shapes_catalog s
  WHERE s.category = 'consequence'
    AND v_compat_consequences @> to_jsonb(s.shape_key);

  RETURN jsonb_build_object(
    'trigger_shape', jsonb_build_object(
      'shape_key', v_trigger.shape_key,
      'category', v_trigger.category,
      'display_name', v_trigger.display_name,
      'description', v_trigger.description,
      'schema', v_trigger.schema,
      'resource_types', v_trigger.resource_types,
      'metadata', v_trigger.metadata),
    'condition_shapes', v_condition_shapes,
    'consequence_shapes', v_consequence_shapes
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rule_shape_compatibility(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rule_shape_compatibility(text) TO authenticated, service_role;

COMMIT;
