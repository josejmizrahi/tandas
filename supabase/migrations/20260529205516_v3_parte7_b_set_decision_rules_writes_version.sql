-- V3 PARTE 7b — set_decision_rules writes group_governance_versions
--
-- Cambios sobre ambas overloads (legacy 4-arg + modern 6-arg):
-- 1. Antes del UPDATE de groups.decision_rules: cerrar versión activa
--    actual (UPDATE ... SET effective_until=now() WHERE group_id=$ AND
--    effective_until IS NULL).
-- 2. Después del UPDATE: insertar nueva fila en group_governance_versions
--    con snapshot = v_rules.
-- 3. record_system_event payload gana version_id para reverse-link.

-- ---------------------------------------------------------------------
-- Modern 6-arg overload (canonical)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_decision_rules(
  p_group_id uuid,
  p_default_style text,
  p_quorum_min integer DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_default_method text DEFAULT NULL,
  p_default_legitimacy_source text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid        uuid := auth.uid();
  v_style      text;
  v_method     text;
  v_legitimacy text;
  v_notes      text;
  v_rules      jsonb;
  v_version_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  v_method := COALESCE(NULLIF(btrim(p_default_method), ''), NULL);
  IF v_method IS NULL THEN
    v_style := COALESCE(NULLIF(btrim(p_default_style), ''), '');
    v_method := CASE v_style
      WHEN 'admin_only'    THEN 'admin'
      WHEN 'majority'      THEN 'majority'
      WHEN 'supermajority' THEN 'supermajority'
      WHEN 'unanimity'     THEN 'consensus'
      WHEN 'consensus'     THEN 'consent'
      ELSE ''
    END;
  END IF;
  IF v_method NOT IN (
    'admin', 'majority', 'supermajority', 'consensus', 'consent',
    'ranked_choice', 'weighted', 'veto'
  ) THEN
    RAISE EXCEPTION 'invalid decision method: %', v_method USING errcode = '22023';
  END IF;

  v_style := CASE v_method
    WHEN 'admin'         THEN 'admin_only'
    WHEN 'majority'      THEN 'majority'
    WHEN 'supermajority' THEN 'supermajority'
    WHEN 'consensus'     THEN 'unanimity'
    WHEN 'consent'       THEN 'consensus'
    WHEN 'ranked_choice' THEN 'majority'
    WHEN 'weighted'      THEN 'majority'
    WHEN 'veto'          THEN 'consensus'
  END;

  v_legitimacy := COALESCE(NULLIF(btrim(p_default_legitimacy_source), ''), NULL);
  IF v_legitimacy IS NULL THEN
    v_legitimacy := CASE v_method
      WHEN 'admin'         THEN 'founder'
      WHEN 'majority'      THEN 'majority'
      WHEN 'supermajority' THEN 'supermajority'
      WHEN 'consensus'     THEN 'unanimity'
      WHEN 'consent'       THEN 'committee'
      WHEN 'ranked_choice' THEN 'election'
      WHEN 'weighted'      THEN 'expert'
      WHEN 'veto'          THEN 'committee'
    END;
  END IF;
  IF v_legitimacy NOT IN (
    'founder', 'election', 'majority', 'supermajority', 'committee',
    'unanimity', 'expert', 'external_contract', 'tradition', 'emergency'
  ) THEN
    RAISE EXCEPTION 'invalid legitimacy source: %', v_legitimacy USING errcode = '22023';
  END IF;

  IF p_quorum_min IS NOT NULL AND p_quorum_min < 1 THEN
    RAISE EXCEPTION 'quorum_min must be >= 1' USING errcode = '22023';
  END IF;

  v_notes := NULLIF(btrim(COALESCE(p_notes, '')), '');

  PERFORM public.assert_permission(p_group_id, 'group.update');

  v_rules := jsonb_strip_nulls(jsonb_build_object(
    'default_style',             v_style,
    'default_method',            v_method,
    'default_legitimacy_source', v_legitimacy,
    'quorum_min',                p_quorum_min,
    'notes',                     v_notes
  ));

  UPDATE public.groups
     SET decision_rules = v_rules,
         updated_at     = now()
   WHERE id = p_group_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'group not found: %', p_group_id USING errcode = 'P0002';
  END IF;

  -- Close the previous active version (idempotent: NULL row may not exist on first set)
  UPDATE public.group_governance_versions
     SET effective_until = now()
   WHERE group_id = p_group_id AND effective_until IS NULL;

  -- Insert new active version
  INSERT INTO public.group_governance_versions (group_id, snapshot, set_by, source_decision_id)
  VALUES (p_group_id, v_rules, v_uid, NULL)
  RETURNING id INTO v_version_id;

  PERFORM public.record_system_event(
    p_group_id, 'decision_rules.set', 'group', p_group_id,
    'Reglas de decisión actualizadas',
    jsonb_build_object(
      'default_style',             v_style,
      'default_method',            v_method,
      'default_legitimacy_source', v_legitimacy,
      'quorum_min',                p_quorum_min,
      'has_notes',                 v_notes IS NOT NULL,
      'version_id',                v_version_id
    )
  );

  RETURN jsonb_build_object(
    'group_id',                  p_group_id,
    'default_style',             v_style,
    'default_method',            v_method,
    'default_legitimacy_source', v_legitimacy,
    'quorum_min',                p_quorum_min,
    'notes',                     v_notes,
    'version_id',                v_version_id,
    'is_default',                false
  );
END;
$function$;

-- ---------------------------------------------------------------------
-- Legacy 4-arg overload (kept for callers not yet migrated)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_decision_rules(
  p_group_id uuid,
  p_default_style text,
  p_quorum_min integer DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid        uuid := auth.uid();
  v_style      text;
  v_notes      text;
  v_rules      jsonb;
  v_version_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  v_style := COALESCE(NULLIF(btrim(p_default_style), ''), '');
  IF v_style NOT IN ('admin_only', 'majority', 'supermajority', 'unanimity', 'consensus') THEN
    RAISE EXCEPTION 'invalid decision style' USING errcode = '22023';
  END IF;

  IF p_quorum_min IS NOT NULL AND p_quorum_min < 1 THEN
    RAISE EXCEPTION 'quorum_min must be >= 1' USING errcode = '22023';
  END IF;

  v_notes := NULLIF(btrim(COALESCE(p_notes, '')), '');

  PERFORM public.assert_permission(p_group_id, 'group.update');

  v_rules := jsonb_strip_nulls(jsonb_build_object(
    'default_style', v_style,
    'quorum_min',    p_quorum_min,
    'notes',         v_notes
  ));

  UPDATE public.groups
     SET decision_rules = v_rules,
         updated_at     = now()
   WHERE id = p_group_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'group not found: %', p_group_id USING errcode = 'P0002';
  END IF;

  UPDATE public.group_governance_versions
     SET effective_until = now()
   WHERE group_id = p_group_id AND effective_until IS NULL;

  INSERT INTO public.group_governance_versions (group_id, snapshot, set_by, source_decision_id)
  VALUES (p_group_id, v_rules, v_uid, NULL)
  RETURNING id INTO v_version_id;

  PERFORM public.record_system_event(
    p_group_id, 'decision_rules.set', 'group', p_group_id,
    'Reglas de decisión actualizadas',
    jsonb_build_object(
      'default_style', v_style,
      'quorum_min',    p_quorum_min,
      'has_notes',     v_notes IS NOT NULL,
      'version_id',    v_version_id
    )
  );

  RETURN jsonb_build_object(
    'group_id',      p_group_id,
    'default_style', v_style,
    'quorum_min',    p_quorum_min,
    'notes',         v_notes,
    'version_id',    v_version_id,
    'is_default',    false
  );
END;
$function$;
