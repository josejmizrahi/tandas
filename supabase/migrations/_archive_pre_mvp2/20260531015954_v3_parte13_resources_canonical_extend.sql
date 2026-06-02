-- V3 PARTE 13: Resources canonical extend
-- =========================================
-- Doctrine: respetar group_resources envelope existente. No multi-role.
-- Sólo extender CHECK resource_type, añadir 2 permissions, ampliar
-- create_group_resource type whitelist, y crear 3 RPCs nuevas que
-- llenan huecos (detail/value/lifecycle). Audit log via group_events
-- (record_system_event) — NO crear group_resource_events audit log
-- (esa tabla existe pero es subtipo de calendar event).

-- ---------------------------------------------------------------------
-- A. Extender CHECK resource_type
-- ---------------------------------------------------------------------
ALTER TABLE public.group_resources
  DROP CONSTRAINT IF EXISTS group_resources_resource_type_check;

ALTER TABLE public.group_resources
  ADD CONSTRAINT group_resources_resource_type_check
  CHECK (resource_type = ANY (ARRAY[
    'event','fund','slot','space','asset','right','money','time','points',
    'document','data','access','other',
    -- V3 PARTE 13: envelope-only types nuevos
    'vehicle','tool','inventory','real_estate','intellectual_property'
  ]));

-- ---------------------------------------------------------------------
-- B. Permissions nuevas (categoria 'resources' ya existe)
-- ---------------------------------------------------------------------
INSERT INTO public.permissions (key, description, category) VALUES
  ('resources.update_value', 'Actualizar valor de un recurso',    'resources'),
  ('resources.record_event', 'Registrar evento de ciclo de vida', 'resources')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- C. Ampliar create_group_resource para aceptar los 5 tipos nuevos
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_group_resource(
  p_group_id uuid,
  p_resource_type text,
  p_name text,
  p_description text DEFAULT NULL::text,
  p_visibility text DEFAULT 'members'::text,
  p_ownership_kind text DEFAULT 'group'::text,
  p_owner_membership_id uuid DEFAULT NULL::uuid,
  p_custodian_membership_id uuid DEFAULT NULL::uuid
)
RETURNS public.group_resources
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_type text; v_name text; v_description text; v_visibility text; v_ownership text;
  v_metadata jsonb := '{}'::jsonb;
  v_row public.group_resources;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'must be authenticated' USING errcode = '42501'; END IF;
  v_type := COALESCE(NULLIF(btrim(coalesce(p_resource_type, '')), ''), '');
  -- V3 PARTE 13: incluir 5 envelope-only types nuevos
  IF v_type NOT IN (
    'fund','space','asset','document','other',
    'vehicle','tool','inventory','real_estate','intellectual_property'
  ) THEN
    RAISE EXCEPTION 'invalid resource type' USING errcode = '22023';
  END IF;
  v_name := NULLIF(btrim(coalesce(p_name, '')), '');
  IF v_name IS NULL THEN RAISE EXCEPTION 'resource name required' USING errcode = '22023'; END IF;
  v_description := NULLIF(btrim(coalesce(p_description, '')), '');
  v_visibility := COALESCE(NULLIF(btrim(coalesce(p_visibility, '')), ''), 'members');
  IF v_visibility NOT IN ('private','members','public') THEN
    RAISE EXCEPTION 'invalid resource visibility' USING errcode = '22023';
  END IF;
  v_ownership := COALESCE(NULLIF(btrim(coalesce(p_ownership_kind, '')), ''), 'group');
  IF v_ownership NOT IN ('group','individual','external') THEN
    RAISE EXCEPTION 'invalid ownership kind' USING errcode = '22023';
  END IF;
  IF p_owner_membership_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.group_memberships WHERE id = p_owner_membership_id AND group_id = p_group_id) THEN
      RAISE EXCEPTION 'owner membership not in group %', p_group_id USING errcode = '22023';
    END IF;
  END IF;
  IF p_custodian_membership_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.group_memberships WHERE id = p_custodian_membership_id AND group_id = p_group_id) THEN
      RAISE EXCEPTION 'custodian membership not in group %', p_group_id USING errcode = '22023';
    END IF;
    v_metadata := v_metadata || jsonb_build_object(
      'foundation_custodian_membership_id', p_custodian_membership_id::text);
  END IF;

  PERFORM public.assert_permission(p_group_id, 'resources.create');

  INSERT INTO public.group_resources (
    group_id, resource_type, name, description, status, visibility,
    ownership_kind, owner_membership_id, metadata, created_by
  ) VALUES (
    p_group_id, v_type, v_name, v_description, 'active', v_visibility,
    v_ownership, p_owner_membership_id, v_metadata, v_uid
  )
  RETURNING * INTO v_row;

  PERFORM public.record_system_event(
    p_group_id, 'resource.created', 'resource', v_row.id, v_name,
    jsonb_build_object('resource_type', v_type, 'visibility', v_visibility, 'ownership_kind', v_ownership)
  );

  RETURN v_row;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.create_group_resource(uuid, text, text, text, text, text, uuid, uuid) FROM anon, public;
GRANT  EXECUTE ON FUNCTION public.create_group_resource(uuid, text, text, text, text, text, uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- D. group_resource_detail(p_resource_id)
-- ---------------------------------------------------------------------
-- Lectura de un recurso individual con su subtype payload embebido.
-- Respeta RLS via SELECT directo (no SECURITY DEFINER): si el caller no
-- puede ver el envelope, no recibe nada. Subtype payload por type.
DROP FUNCTION IF EXISTS public.group_resource_detail(uuid);

CREATE FUNCTION public.group_resource_detail(p_resource_id uuid)
RETURNS TABLE(
  id uuid,
  group_id uuid,
  resource_type text,
  name text,
  description text,
  status text,
  visibility text,
  ownership_kind text,
  owner_membership_id uuid,
  ownership_metadata jsonb,
  unit text,
  metadata jsonb,
  series_id uuid,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  archived_at timestamptz,
  subtype jsonb
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'must be authenticated' USING errcode = '42501'; END IF;
  RETURN QUERY
  SELECT
    r.id, r.group_id, r.resource_type, r.name, r.description, r.status, r.visibility,
    r.ownership_kind, r.owner_membership_id, r.ownership_metadata,
    r.unit, r.metadata, r.series_id, r.created_by,
    r.created_at, r.updated_at, r.archived_at,
    CASE r.resource_type
      WHEN 'asset' THEN (
        SELECT to_jsonb(a) FROM public.group_resource_assets a WHERE a.resource_id = r.id
      )
      WHEN 'fund' THEN (
        SELECT to_jsonb(f) FROM public.group_resource_funds f WHERE f.resource_id = r.id
      )
      WHEN 'space' THEN (
        SELECT to_jsonb(s) FROM public.group_resource_spaces s WHERE s.resource_id = r.id
      )
      WHEN 'right' THEN (
        SELECT to_jsonb(rt) FROM public.group_resource_rights rt WHERE rt.resource_id = r.id
      )
      WHEN 'slot' THEN (
        SELECT to_jsonb(sl) FROM public.group_resource_slots sl WHERE sl.resource_id = r.id
      )
      ELSE NULL
    END AS subtype
  FROM public.group_resources r
  WHERE r.id = p_resource_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.group_resource_detail(uuid) FROM anon, public;
GRANT  EXECUTE ON FUNCTION public.group_resource_detail(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- E. update_resource_value(p_resource_id, p_value, p_unit, p_basis)
-- ---------------------------------------------------------------------
-- Para 'asset': inserta en group_resource_asset_valuations + actualiza
-- group_resource_assets.current_value/current_value_unit (mantenemos
-- el campo current_value que ya existe).
-- Para otros types: graba el valor último en metadata.last_value y
-- emite el lifecycle event para que el histórico viva en group_events.
DROP FUNCTION IF EXISTS public.update_resource_value(uuid, numeric, text, text);

CREATE FUNCTION public.update_resource_value(
  p_resource_id uuid,
  p_value       numeric,
  p_unit        text,
  p_basis       text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_r   public.group_resources%ROWTYPE;
  v_unit text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'must be authenticated' USING errcode = '42501'; END IF;
  IF p_value IS NULL THEN RAISE EXCEPTION 'value required'      USING errcode = '22023'; END IF;
  v_unit := NULLIF(btrim(coalesce(p_unit, '')), '');
  IF v_unit IS NULL THEN RAISE EXCEPTION 'unit required'        USING errcode = '22023'; END IF;

  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id FOR UPDATE;
  IF v_r.id IS NULL THEN RAISE EXCEPTION 'resource not found'   USING errcode = '22023'; END IF;
  IF v_r.status = 'archived' THEN RAISE EXCEPTION 'resource archived' USING errcode = '22023'; END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update_value');

  IF v_r.resource_type = 'asset' THEN
    INSERT INTO public.group_resource_asset_valuations (
      resource_id, value, unit, basis, recorded_by, recorded_at
    ) VALUES (
      p_resource_id, p_value, v_unit,
      NULLIF(btrim(coalesce(p_basis, '')), ''),
      v_uid, now()
    );
    UPDATE public.group_resource_assets
       SET current_value = p_value,
           current_value_unit = v_unit,
           updated_at = now()
     WHERE resource_id = p_resource_id;
  ELSE
    UPDATE public.group_resources
       SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
             'last_value', p_value::text,
             'last_value_unit', v_unit,
             'last_value_basis', NULLIF(btrim(coalesce(p_basis, '')), ''),
             'last_value_at', to_jsonb(now())
           ),
           updated_at = now()
     WHERE id = p_resource_id;
  END IF;

  PERFORM public.record_system_event(
    v_r.group_id, 'resource.value_updated', 'resource', p_resource_id,
    'Valor de recurso actualizado',
    jsonb_build_object(
      'resource_type', v_r.resource_type,
      'value', p_value::text,
      'unit',  v_unit,
      'basis', NULLIF(btrim(coalesce(p_basis, '')), '')
    )
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.update_resource_value(uuid, numeric, text, text) FROM anon, public;
GRANT  EXECUTE ON FUNCTION public.update_resource_value(uuid, numeric, text, text) TO authenticated;

-- ---------------------------------------------------------------------
-- F. record_resource_lifecycle_event(p_resource_id, p_event_type, p_payload, p_client_id)
-- ---------------------------------------------------------------------
-- Whitelist event_types: status_changed, transferred, used, damaged,
-- repaired, assigned, returned. (value_updated tiene su RPC dedicada;
-- created/archived ya viven en flows propios; role_granted/revoked
-- quedan fuera porque NO multi-role en esta parte.)
-- Idempotente: si llega p_client_id repetido para (group, event_type,
-- entity_id) devuelve sin insertar.
DROP FUNCTION IF EXISTS public.record_resource_lifecycle_event(uuid, text, jsonb, text);

CREATE FUNCTION public.record_resource_lifecycle_event(
  p_resource_id uuid,
  p_event_type  text,
  p_payload     jsonb DEFAULT '{}'::jsonb,
  p_client_id   text  DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid    uuid := auth.uid();
  v_r      public.group_resources%ROWTYPE;
  v_etype  text;
  v_cid    text;
  v_dup    bigint;
  v_payld  jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'must be authenticated' USING errcode = '42501'; END IF;
  v_etype := NULLIF(btrim(coalesce(p_event_type, '')), '');
  IF v_etype NOT IN (
    'resource.status_changed',
    'resource.transferred',
    'resource.used',
    'resource.damaged',
    'resource.repaired',
    'resource.assigned',
    'resource.returned'
  ) THEN
    RAISE EXCEPTION 'invalid lifecycle event_type %', v_etype USING errcode = '22023';
  END IF;

  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id;
  IF v_r.id IS NULL THEN RAISE EXCEPTION 'resource not found' USING errcode = '22023'; END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.record_event');

  v_cid   := NULLIF(btrim(coalesce(p_client_id, '')), '');
  v_payld := COALESCE(p_payload, '{}'::jsonb);

  IF v_cid IS NOT NULL THEN
    SELECT id INTO v_dup FROM public.group_events
     WHERE group_id   = v_r.group_id
       AND event_type = v_etype
       AND entity_id  = p_resource_id
       AND payload->>'client_id' = v_cid
     LIMIT 1;
    IF v_dup IS NOT NULL THEN RETURN; END IF;
    v_payld := v_payld || jsonb_build_object('client_id', v_cid);
  END IF;

  PERFORM public.record_system_event(
    v_r.group_id, v_etype, 'resource', p_resource_id,
    'Evento de recurso',
    v_payld
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.record_resource_lifecycle_event(uuid, text, jsonb, text) FROM anon, public;
GRANT  EXECUTE ON FUNCTION public.record_resource_lifecycle_event(uuid, text, jsonb, text) TO authenticated;
