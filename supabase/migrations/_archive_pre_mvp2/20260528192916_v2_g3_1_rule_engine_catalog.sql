-- V2-G3.1: rule engine catalog + dry-run validator + engine create wrapper.
-- Seeds 9 catalog atoms (3 trigger, 3 condition, 3 consequence). Adds:
--   list_rule_shapes()          : typed read of the catalog for iOS.
--   validate_rule_shape(jsonb)  : dry-run validator for preview UX.
--   create_engine_rule(...)     : atomic propose+publish wrapper.
--   group_rules_engine(uuid)    : list active engine rules for a group.
-- All idempotent: ON CONFLICT seed, CREATE OR REPLACE RPCs.

INSERT INTO public.rule_shapes_catalog
  (shape_key, category, display_name, description, schema, resource_types, metadata)
VALUES
  ('trigger.money.expense_recorded', 'trigger',
   'Cuando alguien registra un gasto',
   'Se dispara cuando un miembro guarda un nuevo gasto monetario en el grupo.',
   jsonb_build_object(
     'event_type', 'money.expense_recorded',
     'payload_keys', jsonb_build_array('amount','currency','resource_id','actor_user_id'),
     'compatible_conditions', jsonb_build_array('condition.actor_role_in','condition.amount_above'),
     'compatible_consequences', jsonb_build_array('consequence.issue_sanction','consequence.send_notification')
   ),
   ARRAY[]::text[],
   jsonb_build_object('icon','dollarsign.bank.building')),

  ('trigger.member.state_changed', 'trigger',
   'Cuando cambia el estado de un miembro',
   'Se dispara cuando alguien se une, sale, es suspendido, etc.',
   jsonb_build_object(
     'event_type', 'member.state_changed',
     'payload_keys', jsonb_build_array('new_state','old_state','target_user_id','actor_user_id'),
     'compatible_conditions', jsonb_build_array('condition.actor_role_in','condition.target_self'),
     'compatible_consequences', jsonb_build_array('consequence.send_notification','consequence.set_membership_state')
   ),
   ARRAY[]::text[],
   jsonb_build_object('icon','person.crop.circle.badge.exclamationmark')),

  ('trigger.decision.finalized', 'trigger',
   'Cuando cierra una decisión',
   'Se dispara cuando una decisión del grupo se finaliza con resultado.',
   jsonb_build_object(
     'event_type', 'decision.finalized',
     'payload_keys', jsonb_build_array('outcome','decision_id','method'),
     'compatible_conditions', jsonb_build_array('condition.actor_role_in'),
     'compatible_consequences', jsonb_build_array('consequence.send_notification')
   ),
   ARRAY[]::text[],
   jsonb_build_object('icon','checklist')),

  ('condition.actor_role_in', 'condition',
   'El actor tiene cierto rol',
   'Solo dispara cuando el actor del evento tiene uno de los roles indicados.',
   jsonb_build_object(
     'kind', 'actor_role_in',
     'fields', jsonb_build_array(
       jsonb_build_object('key','roles','type','string_array','required',true,'label','Roles que califican')
     )
   ),
   ARRAY[]::text[],
   '{}'::jsonb),

  ('condition.amount_above', 'condition',
   'El monto supera un umbral',
   'Solo dispara cuando el monto del evento supera el valor configurado.',
   jsonb_build_object(
     'kind', 'amount_above',
     'fields', jsonb_build_array(
       jsonb_build_object('key','amount','type','number','required',true,'min',0,'label','Monto'),
       jsonb_build_object('key','currency','type','string','required',true,'default','MXN','label','Moneda')
     )
   ),
   ARRAY[]::text[],
   '{}'::jsonb),

  ('condition.target_self', 'condition',
   'El afectado es el mismo actor',
   'Solo dispara cuando el actor del evento es también el afectado.',
   jsonb_build_object(
     'kind', 'target_self',
     'fields', jsonb_build_array(
       jsonb_build_object('key','only_self','type','boolean','required',true,'default',true,'label','Solo cuando actor = afectado')
     )
   ),
   ARRAY[]::text[],
   '{}'::jsonb),

  ('consequence.issue_sanction', 'consequence',
   'Emitir sanción al actor',
   'Genera una sanción contra el actor del evento.',
   jsonb_build_object(
     'action', 'issue_sanction',
     'fields', jsonb_build_array(
       jsonb_build_object('key','severity','type','integer','required',true,'min',1,'max',5,'label','Severidad (1-5)'),
       jsonb_build_object('key','reason','type','string','required',true,'label','Razón')
     )
   ),
   ARRAY[]::text[],
   '{}'::jsonb),

  ('consequence.send_notification', 'consequence',
   'Enviar notificación',
   'Encola una notificación al canal elegido.',
   jsonb_build_object(
     'action', 'send_notification',
     'fields', jsonb_build_array(
       jsonb_build_object('key','message','type','string','required',true,'label','Mensaje'),
       jsonb_build_object('key','audience','type','enum','required',false,'default','admins',
                         'enum', jsonb_build_array('actor','admins','group'),
                         'label','Audiencia')
     )
   ),
   ARRAY[]::text[],
   '{}'::jsonb),

  ('consequence.set_membership_state', 'consequence',
   'Cambiar estado de membresía',
   'Mueve al actor a otro estado de membresía.',
   jsonb_build_object(
     'action', 'set_membership_state',
     'fields', jsonb_build_array(
       jsonb_build_object('key','new_state','type','enum','required',true,
                         'enum', jsonb_build_array('active','suspended','left','banned'),
                         'label','Nuevo estado'),
       jsonb_build_object('key','reason','type','string','required',false,'label','Razón')
     )
   ),
   ARRAY[]::text[],
   '{}'::jsonb)
ON CONFLICT (shape_key) DO UPDATE
  SET category       = EXCLUDED.category,
      display_name   = EXCLUDED.display_name,
      description    = EXCLUDED.description,
      schema         = EXCLUDED.schema,
      resource_types = EXCLUDED.resource_types,
      metadata       = EXCLUDED.metadata;

-- list_rule_shapes(): typed read of the entire atom catalog.
CREATE OR REPLACE FUNCTION public.list_rule_shapes()
RETURNS TABLE(
  shape_key text,
  category text,
  display_name text,
  description text,
  schema jsonb,
  resource_types text[],
  metadata jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT shape_key, category, display_name, description, schema, resource_types, metadata
    FROM public.rule_shapes_catalog
   ORDER BY category, display_name;
$$;
GRANT EXECUTE ON FUNCTION public.list_rule_shapes() TO authenticated;

-- validate_rule_shape(p_shape jsonb): dry-run validator for preview UX.
-- p_shape = { shape_key, condition_tree, consequences }
-- Returns { valid, errors[], shape_key, trigger_event_type }.
CREATE OR REPLACE FUNCTION public.validate_rule_shape(p_shape jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
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

  -- condition_tree (optional)
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

  -- consequences (required: at least one).
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
GRANT EXECUTE ON FUNCTION public.validate_rule_shape(jsonb) TO authenticated;

-- create_engine_rule(...): atomic propose+publish wrapper for engine rules.
-- Requires rules.publish (same as publish_rule_version).
CREATE OR REPLACE FUNCTION public.create_engine_rule(
  p_group_id uuid,
  p_title text,
  p_shape_key text,
  p_condition_tree jsonb,
  p_consequences jsonb,
  p_rule_type text DEFAULT 'norm',
  p_severity integer DEFAULT 1
)
RETURNS TABLE(rule_id uuid, version_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_title text;
  v_validation jsonb;
  v_trigger text;
  v_rule_id uuid;
  v_version_id uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'must be authenticated' USING errcode='42501'; END IF;
  v_title := NULLIF(btrim(coalesce(p_title,'')), '');
  IF v_title IS NULL THEN RAISE EXCEPTION 'rule title required' USING errcode='22023'; END IF;
  IF p_rule_type NOT IN ('norm','requirement','prohibition','process','principle') THEN
    RAISE EXCEPTION 'invalid rule type' USING errcode='22023';
  END IF;
  IF p_severity < 0 OR p_severity > 5 THEN
    RAISE EXCEPTION 'invalid rule severity' USING errcode='22023';
  END IF;

  v_validation := public.validate_rule_shape(jsonb_build_object(
    'shape_key', p_shape_key,
    'condition_tree', p_condition_tree,
    'consequences', p_consequences
  ));
  IF NOT (v_validation->>'valid')::boolean THEN
    RAISE EXCEPTION 'invalid rule shape: %', v_validation->'errors' USING errcode='22023';
  END IF;
  v_trigger := v_validation->>'trigger_event_type';

  PERFORM public.assert_permission(p_group_id, 'rules.publish');

  INSERT INTO public.group_rules (group_id, title, rule_type, severity, status, created_by)
  VALUES (p_group_id, v_title, p_rule_type, p_severity, 'active', v_uid)
  RETURNING id INTO v_rule_id;

  INSERT INTO public.group_rule_versions (
    rule_id, version, execution_mode, trigger_event_type,
    condition_tree, consequences, shape_key, effective_from, published_by
  )
  VALUES (
    v_rule_id, 1, 'engine', v_trigger,
    p_condition_tree, p_consequences, p_shape_key, now(), v_uid
  )
  RETURNING id INTO v_version_id;

  UPDATE public.group_rules
     SET current_version_id = v_version_id, updated_at = now()
   WHERE id = v_rule_id;

  PERFORM public.record_system_event(
    p_group_id, 'rule.created', 'rule', v_rule_id,
    'Regla con engine creada',
    jsonb_build_object(
      'rule_type', p_rule_type,
      'severity', p_severity,
      'execution_mode', 'engine',
      'shape_key', p_shape_key,
      'trigger_event_type', v_trigger
    )
  );

  rule_id := v_rule_id;
  version_id := v_version_id;
  RETURN NEXT;
END;
$$;
GRANT EXECUTE ON FUNCTION public.create_engine_rule(uuid, text, text, jsonb, jsonb, text, integer) TO authenticated;

-- group_rules_engine(p_group_id): active engine rules for a group.
CREATE OR REPLACE FUNCTION public.group_rules_engine(p_group_id uuid)
RETURNS TABLE(
  rule_id uuid,
  current_version_id uuid,
  group_id uuid,
  title text,
  rule_type text,
  severity integer,
  status text,
  created_by uuid,
  effective_from timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  shape_key text,
  trigger_event_type text,
  condition_tree jsonb,
  consequences jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
#variable_conflict use_column
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
    WHERE gm.group_id = p_group_id AND gm.user_id = v_uid AND gm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id USING errcode = '42501';
  END IF;
  RETURN QUERY
  SELECT gr.id, gr.current_version_id, gr.group_id, gr.title, gr.rule_type, gr.severity,
         gr.status, gr.created_by, grv.effective_from, gr.created_at, gr.updated_at,
         grv.shape_key, grv.trigger_event_type, grv.condition_tree, grv.consequences
    FROM public.group_rules gr
    JOIN public.group_rule_versions grv ON grv.id = gr.current_version_id
   WHERE gr.group_id = p_group_id
     AND gr.status = 'active'
     AND grv.execution_mode = 'engine'
     AND grv.effective_until IS NULL
   ORDER BY gr.severity DESC, grv.effective_from DESC NULLS LAST, gr.created_at DESC;
END;
$$;
GRANT EXECUTE ON FUNCTION public.group_rules_engine(uuid) TO authenticated;
