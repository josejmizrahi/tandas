-- R.0A MIG 3 — legal_entities table + create/update RPCs.
-- legal_entities.id REFERENCES actors(id) — comparte UUID, 1:1.
-- RPCs son SECDEF y mantienen consistencia actors ↔ legal_entities.
-- Out of scope R.0A: ownership/governance gating (eso es R.0C+).

CREATE TABLE public.legal_entities (
  id            uuid PRIMARY KEY REFERENCES public.actors(id) ON DELETE CASCADE,
  entity_type   text NOT NULL,
  tax_id        text,
  jurisdiction  text,
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_legal_entities_entity_type ON public.legal_entities(entity_type);
CREATE INDEX idx_legal_entities_jurisdiction ON public.legal_entities(jurisdiction);

CREATE OR REPLACE FUNCTION public._legal_entities_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_legal_entities_touch_updated_at
  BEFORE UPDATE ON public.legal_entities
  FOR EACH ROW
  EXECUTE FUNCTION public._legal_entities_touch_updated_at();

ALTER TABLE public.legal_entities ENABLE ROW LEVEL SECURITY;

CREATE POLICY legal_entities_select_authenticated
  ON public.legal_entities
  FOR SELECT
  TO authenticated
  USING (true);

COMMENT ON TABLE public.legal_entities IS
  'R.0A. 1:1 con actors (id = actors.id, actor_kind=legal_entity). Ownership/governance gating diferido a R.0C+.';

-- RPC: create_legal_entity
-- Atomicamente inserta actor + legal_entity con UUID compartido.
CREATE OR REPLACE FUNCTION public.create_legal_entity(
  p_display_name text,
  p_entity_type  text,
  p_tax_id       text DEFAULT NULL,
  p_jurisdiction text DEFAULT NULL,
  p_metadata     jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_id uuid := gen_random_uuid();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  IF p_display_name IS NULL OR length(trim(p_display_name)) = 0 THEN
    RAISE EXCEPTION 'display_name required' USING errcode = '22023';
  END IF;

  IF p_entity_type IS NULL OR length(trim(p_entity_type)) = 0 THEN
    RAISE EXCEPTION 'entity_type required' USING errcode = '22023';
  END IF;

  INSERT INTO public.actors (id, actor_kind, display_name, metadata)
  VALUES (
    v_id,
    'legal_entity',
    p_display_name,
    jsonb_build_object('created_by_uid', auth.uid()) || COALESCE(p_metadata, '{}'::jsonb)
  );

  INSERT INTO public.legal_entities (id, entity_type, tax_id, jurisdiction, metadata)
  VALUES (v_id, p_entity_type, p_tax_id, p_jurisdiction, COALESCE(p_metadata, '{}'::jsonb));

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_legal_entity(text, text, text, text, jsonb) TO authenticated;

-- RPC: update_legal_entity
-- Actualiza campos no nulos. Mantiene actors.display_name en sync si se pasa p_display_name.
-- Ownership gating diferido a R.0C+.
CREATE OR REPLACE FUNCTION public.update_legal_entity(
  p_id           uuid,
  p_display_name text DEFAULT NULL,
  p_entity_type  text DEFAULT NULL,
  p_tax_id       text DEFAULT NULL,
  p_jurisdiction text DEFAULT NULL,
  p_metadata     jsonb DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_exists boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.legal_entities WHERE id = p_id) INTO v_exists;
  IF NOT v_exists THEN
    RAISE EXCEPTION 'legal_entity not found: %', p_id USING errcode = 'P0002';
  END IF;

  UPDATE public.actors
     SET display_name = COALESCE(p_display_name, display_name),
         metadata     = CASE WHEN p_metadata IS NOT NULL THEN metadata || p_metadata ELSE metadata END
   WHERE id = p_id;

  UPDATE public.legal_entities
     SET entity_type  = COALESCE(p_entity_type, entity_type),
         tax_id       = COALESCE(p_tax_id, tax_id),
         jurisdiction = COALESCE(p_jurisdiction, jurisdiction),
         metadata     = CASE WHEN p_metadata IS NOT NULL THEN metadata || p_metadata ELSE metadata END
   WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_legal_entity(uuid, text, text, text, text, jsonb) TO authenticated;
