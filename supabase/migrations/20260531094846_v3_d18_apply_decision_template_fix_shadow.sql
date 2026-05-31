-- V3-D.18 hot-fix — el OUT column template_key shadowea p_template_key
-- en el SELECT WHERE template_key = p_template_key dentro de la función.
-- Resolución PG: nombre OUT gana sobre PARAM. Qualifico la tabla.

CREATE OR REPLACE FUNCTION public.apply_decision_template(
  p_decision_id uuid,
  p_template_key text
)
RETURNS TABLE (
  decision_id   uuid,
  template_key  text,
  execution_mode text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_d   public.group_decisions%ROWTYPE;
  v_t   public.decision_templates_catalog%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  IF p_decision_id IS NULL OR p_template_key IS NULL THEN
    RAISE EXCEPTION 'p_decision_id and p_template_key are required' USING errcode = '22023';
  END IF;

  SELECT * INTO v_d FROM public.group_decisions WHERE id = p_decision_id FOR UPDATE;
  IF v_d.id IS NULL THEN
    RAISE EXCEPTION 'decision % not found', p_decision_id USING errcode = 'P0002';
  END IF;

  IF v_d.status <> 'open' THEN
    RAISE EXCEPTION 'cannot apply template to non-open decision (status=%)', v_d.status
      USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_d.group_id, 'decisions.create');

  SELECT * INTO v_t FROM public.decision_templates_catalog c WHERE c.template_key = p_template_key;
  IF v_t.template_key IS NULL THEN
    RAISE EXCEPTION 'template % not found', p_template_key USING errcode = 'P0002';
  END IF;

  UPDATE public.group_decisions
     SET template_key   = v_t.template_key,
         execution_mode = v_t.execution_mode,
         metadata       = COALESCE(metadata, '{}'::jsonb) || COALESCE(v_t.metadata, '{}'::jsonb)
   WHERE id = p_decision_id;

  decision_id    := p_decision_id;
  template_key   := v_t.template_key;
  execution_mode := v_t.execution_mode;
  RETURN NEXT;
END;
$$;
