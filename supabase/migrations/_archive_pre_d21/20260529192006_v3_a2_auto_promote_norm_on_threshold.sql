-- 20260529192006 — V3-A2: auto-promote cultural_norm → rule on endorsement threshold.
--
-- Cierra §C.4 + §C.18: "cultural_norm.endorsed (≥ N) → opcional promote a regla".
--
-- Threshold opt-in vía groups.settings->>'cultural_norm_auto_promote_threshold'
-- (int). NULL o ≤0 ⇒ promoción solo manual (comportamiento previo).
--
-- Funciones internas siguen patrón existente `public._*` (no hay schema ruul).
-- public._auto_promote_norm_internal — core, sin assert_permission. El umbral
-- ES la legitimidad (el grupo decidió en settings cuántos respaldos bastan).
-- created_by/published_by NULL = marca acción de sistema. record_system_event
-- lleva 'legitimacy_source':'cultural_norm_threshold_reached' en payload.

CREATE OR REPLACE FUNCTION public._auto_promote_norm_internal(p_norm_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $function$
DECLARE
  v_group_id    uuid;
  v_norm_title  text;
  v_norm_body   text;
  v_norm_status text;
  v_rule_id     uuid;
  v_version_id  uuid;
BEGIN
  SELECT n.group_id, n.title, n.body, n.status
    INTO v_group_id, v_norm_title, v_norm_body, v_norm_status
    FROM public.group_cultural_norms n
   WHERE n.id = p_norm_id
   FOR UPDATE;

  IF v_group_id IS NULL THEN
    RETURN NULL;
  END IF;
  IF v_norm_status NOT IN ('proposed','endorsed') THEN
    -- Idempotent re-fire: norm ya retired/promoted.
    RETURN NULL;
  END IF;

  v_norm_body := COALESCE(NULLIF(btrim(coalesce(v_norm_body,'')),''), v_norm_title);

  INSERT INTO public.group_rules (
    group_id, title, rule_type, severity, status, created_by
  ) VALUES (
    v_group_id, v_norm_title, 'norm', 1, 'active', NULL
  )
  RETURNING id INTO v_rule_id;

  INSERT INTO public.group_rule_versions (
    rule_id, version, execution_mode, body, effective_from, published_by
  ) VALUES (
    v_rule_id, 1, 'text', v_norm_body, now(), NULL
  )
  RETURNING id INTO v_version_id;

  UPDATE public.group_rules
     SET current_version_id = v_version_id,
         updated_at         = now()
   WHERE id = v_rule_id;

  UPDATE public.group_cultural_norms
     SET status     = 'retired',
         updated_at = now()
   WHERE id = p_norm_id;

  PERFORM public.record_system_event(
    v_group_id, 'rule.created', 'rule', v_rule_id,
    'Regla creada (promoción automática por umbral de respaldos)',
    jsonb_build_object(
      'rule_type',         'norm',
      'severity',          1,
      'execution_mode',    'text',
      'source',            'cultural_norm_threshold_auto',
      'source_norm_id',    p_norm_id,
      'legitimacy_source', 'cultural_norm_threshold_reached'
    )
  );
  PERFORM public.record_system_event(
    v_group_id, 'cultural_norm.promoted_to_rule', 'cultural_norm', p_norm_id,
    'Norma promovida a regla automáticamente',
    jsonb_build_object(
      'rule_id', v_rule_id,
      'source',  'threshold_auto'
    )
  );

  RETURN v_rule_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public._auto_promote_norm_internal(uuid) FROM public, anon, authenticated;

COMMENT ON FUNCTION public._auto_promote_norm_internal(uuid) IS
  'V3-A2 (mig 20260529192006): promoción interna de cultural_norm → rule, sin permission check. Llamada exclusivamente desde trigger public._check_norm_promotion_threshold cuando endorsed_count >= groups.settings.cultural_norm_auto_promote_threshold. created_by/published_by NULL = legitimidad por umbral, no por actor. Idempotent: no-op si la norma ya está retired.';

-- Trigger function: detecta cruce de umbral.
CREATE OR REPLACE FUNCTION public._check_norm_promotion_threshold()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $function$
DECLARE
  v_threshold int;
  v_settings  jsonb;
  v_raw       text;
BEGIN
  IF NEW.status NOT IN ('proposed','endorsed') THEN
    RETURN NEW;
  END IF;
  IF NEW.endorsed_count IS NULL OR NEW.endorsed_count <= COALESCE(OLD.endorsed_count, 0) THEN
    RETURN NEW;
  END IF;

  SELECT settings INTO v_settings FROM public.groups WHERE id = NEW.group_id;
  v_raw := v_settings->>'cultural_norm_auto_promote_threshold';
  BEGIN
    v_threshold := NULLIF(v_raw,'')::int;
  EXCEPTION WHEN others THEN
    v_threshold := NULL;
  END;

  -- Opt-in: NULL/≤0/parse-error ⇒ promoción solo manual.
  IF v_threshold IS NULL OR v_threshold <= 0 THEN
    RETURN NEW;
  END IF;
  IF NEW.endorsed_count < v_threshold THEN
    RETURN NEW;
  END IF;

  PERFORM public._auto_promote_norm_internal(NEW.id);
  RETURN NEW;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public._check_norm_promotion_threshold() FROM public, anon, authenticated;

COMMENT ON FUNCTION public._check_norm_promotion_threshold() IS
  'V3-A2 (mig 20260529192006): trigger AFTER UPDATE OF endorsed_count en group_cultural_norms. Lee groups.settings->>cultural_norm_auto_promote_threshold (int opt-in). Si endorsed_count >= threshold y status sigue proposed/endorsed → invoca public._auto_promote_norm_internal. NULL/≤0/parse-error ⇒ no-op.';

DROP TRIGGER IF EXISTS group_cultural_norms_auto_promote_on_threshold ON public.group_cultural_norms;

CREATE TRIGGER group_cultural_norms_auto_promote_on_threshold
AFTER UPDATE OF endorsed_count ON public.group_cultural_norms
FOR EACH ROW
EXECUTE FUNCTION public._check_norm_promotion_threshold();
