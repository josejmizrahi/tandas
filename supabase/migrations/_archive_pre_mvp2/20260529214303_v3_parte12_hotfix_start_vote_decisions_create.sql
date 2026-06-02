-- PARTE 12 hot-fix: start_vote exigía `decisions.propose` que NO está registrado
-- en `permissions` ni concedido a ningún rol. Resultado: voting roto en dev.
-- Founder decisión 2026-05-29: rename a `decisions.create` (la permission viva
-- que founder + member ya tienen). 'propose' era un misnomer; el authority right
-- canónico es 'crear decisión'.

CREATE OR REPLACE FUNCTION public.start_vote(
  p_group_id uuid, p_title text, p_body text, p_decision_type text, p_method text,
  p_legitimacy_source text DEFAULT 'majority'::text,
  p_opens_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_closes_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_threshold_pct numeric DEFAULT NULL::numeric,
  p_quorum_pct numeric DEFAULT NULL::numeric,
  p_committee_only boolean DEFAULT false,
  p_reference_kind text DEFAULT NULL::text,
  p_reference_id uuid DEFAULT NULL::uuid,
  p_options jsonb DEFAULT NULL::jsonb,
  p_metadata jsonb DEFAULT NULL::jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid       uuid := auth.uid();
  v_decision_id uuid;
  v_option    jsonb;
  v_sort      integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  PERFORM public.assert_permission(p_group_id, 'decisions.create');
  INSERT INTO public.group_decisions (
    group_id, title, body, decision_type, method, legitimacy_source,
    status, opens_at, closes_at, threshold_pct, quorum_pct,
    committee_only, reference_kind, reference_id, metadata, created_by
  ) VALUES (
    p_group_id, p_title, p_body, p_decision_type, p_method, p_legitimacy_source,
    'open', p_opens_at, p_closes_at, p_threshold_pct, p_quorum_pct,
    COALESCE(p_committee_only, false), p_reference_kind, p_reference_id,
    COALESCE(p_metadata, '{}'::jsonb), v_uid
  )
  RETURNING id INTO v_decision_id;
  IF p_options IS NOT NULL AND jsonb_typeof(p_options) = 'array' THEN
    FOR v_option IN SELECT * FROM jsonb_array_elements(p_options)
    LOOP
      INSERT INTO public.group_decision_options (
        decision_id, label, body, sort_order
      ) VALUES (
        v_decision_id,
        COALESCE(v_option->>'label', ''),
        v_option->>'body',
        v_sort
      );
      v_sort := v_sort + 1;
    END LOOP;
  END IF;
  PERFORM public.record_system_event(
    p_group_id, 'decision.proposed', 'decision', v_decision_id,
    p_title,
    jsonb_build_object(
      'decision_type', p_decision_type,
      'method',        p_method,
      'reference_kind', p_reference_kind
    )
  );
  RETURN v_decision_id;
END;
$function$;

-- PARTE 8b posture: revoke anon + grant authenticated.
REVOKE ALL ON FUNCTION public.start_vote(uuid,text,text,text,text,text,timestamptz,timestamptz,numeric,numeric,boolean,text,uuid,jsonb,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_vote(uuid,text,text,text,text,text,timestamptz,timestamptz,numeric,numeric,boolean,text,uuid,jsonb,jsonb) TO authenticated, service_role;
