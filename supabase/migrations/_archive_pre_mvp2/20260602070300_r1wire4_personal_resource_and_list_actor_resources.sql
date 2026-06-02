-- R.1-WIRE.4 — create_personal_resource + list_actor_resources
--
-- Audit PR #131 gaps 4 y 7:
--   - No había forma de crear un recurso personal (sin grupo): create_resource /
--     create_group_resource exigen group_id + has_group_permission.
--   - No había RPC para listar recursos relevantes de un actor por rights
--     (había que parsear my_world_summary completo).
--
-- create_personal_resource:
--   group_id = NULL, canonical_owner_actor_id = auth.uid(), OWN 100% automático
--   (vía trigger R.1-WIRE.2). No requiere has_group_permission — respeta
--   resources.create para person actor: has_actor_authority(auth.uid(), ...) = self.
--
-- list_actor_resources:
--   recursos relevantes por OWN/MANAGE/USE/VIEW/BENEFICIARY/LIEN/PLEDGE/LEASE/GOVERN.
--   Gated: p_actor_id = auth.uid() OR has_actor_authority(p_actor_id, 'resources.view').

-- ============================================================
-- 1. create_personal_resource
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_personal_resource(
  p_resource_type text,
  p_name text,
  p_description text DEFAULT NULL,
  p_visibility text DEFAULT 'private',
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_client_id text DEFAULT NULL
)
RETURNS public.resources
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller   uuid := auth.uid();
  v_existing public.resources%ROWTYPE;
  v_row      public.resources%ROWTYPE;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  -- Doctrina R.1: resources.create para person actor = auth.uid() es el actor
  IF NOT public.has_actor_authority(v_caller, 'resources.create') THEN
    RAISE EXCEPTION 'not authorized to create personal resources' USING errcode = '42501';
  END IF;

  IF p_name IS NULL OR length(btrim(p_name)) = 0 THEN
    RAISE EXCEPTION 'name required' USING errcode = '22023';
  END IF;

  IF p_resource_type NOT IN (
      'event','fund','slot','space','asset','right','money','time','points',
      'document','data','access','other','vehicle','tool','inventory',
      'real_estate','intellectual_property'
  ) THEN
    RAISE EXCEPTION 'invalid resource_type: %', p_resource_type USING errcode = '22023';
  END IF;

  IF p_visibility NOT IN ('private','members','public') THEN
    RAISE EXCEPTION 'invalid visibility: %', p_visibility USING errcode = '22023';
  END IF;

  -- Idempotencia por client_id (scoped al caller, recursos personales)
  IF p_client_id IS NOT NULL THEN
    SELECT * INTO v_existing FROM public.resources
     WHERE group_id IS NULL
       AND created_by = v_caller
       AND client_id = p_client_id
     LIMIT 1;
    IF v_existing.id IS NOT NULL THEN
      RETURN v_existing;
    END IF;
  END IF;

  PERFORM set_config('ruul.resource_create_intent', 'create_personal_resource', true);

  INSERT INTO public.resources (
    group_id, resource_type, name, description, status, visibility,
    ownership_kind, ownership_metadata, metadata, client_id,
    created_by, canonical_owner_actor_id
  ) VALUES (
    NULL, p_resource_type, btrim(p_name), p_description, 'active', p_visibility,
    'individual', '{}'::jsonb, COALESCE(p_metadata, '{}'::jsonb), p_client_id,
    v_caller, v_caller
  )
  RETURNING * INTO v_row;

  -- El OWN 100% lo crea el trigger R.1-WIRE.2 (_resources_auto_grant_own_right).
  -- Defensa adicional por si el trigger se deshabilita:
  IF NOT public.actor_has_right(v_caller, v_row.id, 'OWN') THEN
    INSERT INTO public.resource_rights (resource_id, holder_actor_id, right_kind, percent, metadata)
    VALUES (v_row.id, v_caller, 'OWN', 100,
            jsonb_build_object('source', 'create_personal_resource_fallback'));
  END IF;

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public.create_personal_resource(text, text, text, text, jsonb, text) IS
  'R.1-WIRE.4: crea un resource personal (group_id NULL) con canonical_owner = caller y OWN 100% en resource_rights. Idempotente por client_id.';

REVOKE ALL ON FUNCTION public.create_personal_resource(text, text, text, text, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_personal_resource(text, text, text, text, jsonb, text) TO authenticated, service_role;

-- ============================================================
-- 2. list_actor_resources
-- ============================================================
CREATE OR REPLACE FUNCTION public.list_actor_resources(p_actor_id uuid)
RETURNS TABLE(
  resource_id uuid,
  name text,
  resource_type text,
  status text,
  group_id uuid,
  canonical_owner_actor_id uuid,
  right_id uuid,
  right_kind text,
  percent numeric,
  scope text,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'actor_id required' USING errcode = '22023';
  END IF;

  -- Gating R.1: self o has_actor_authority(actor, resources.view)
  IF p_actor_id <> v_caller
     AND NOT public.has_actor_authority(p_actor_id, 'resources.view') THEN
    RAISE EXCEPTION 'not authorized to list resources of actor %', p_actor_id
      USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT r.id            AS resource_id,
         r.name,
         r.resource_type,
         r.status,
         r.group_id,
         r.canonical_owner_actor_id,
         rr.id           AS right_id,
         rr.right_kind,
         rr.percent,
         rr.scope,
         rr.starts_at,
         rr.ends_at
    FROM public.resource_rights rr
    JOIN public.resources r ON r.id = rr.resource_id
   WHERE rr.holder_actor_id = p_actor_id
     AND rr.right_kind IN ('OWN','MANAGE','USE','VIEW','BENEFICIARY','LIEN','PLEDGE','LEASE','GOVERN')
     AND rr.revoked_at IS NULL
     AND rr.expired_at IS NULL
     AND (rr.starts_at IS NULL OR rr.starts_at <= now())
     AND (rr.ends_at IS NULL OR rr.ends_at > now())
     AND r.archived_at IS NULL
   ORDER BY rr.right_kind, r.created_at DESC;
END;
$$;

COMMENT ON FUNCTION public.list_actor_resources(uuid) IS
  'R.1-WIRE.4: recursos relevantes para un actor explicados por right_kind (OWN/MANAGE/USE/VIEW/BENEFICIARY/LIEN/PLEDGE/LEASE/GOVERN). Gated: self o has_actor_authority(actor, resources.view).';

REVOKE ALL ON FUNCTION public.list_actor_resources(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_actor_resources(uuid) TO authenticated, service_role;
