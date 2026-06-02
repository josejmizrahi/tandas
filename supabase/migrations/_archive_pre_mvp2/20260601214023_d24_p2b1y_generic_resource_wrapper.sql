-- D.24 P2B-1.y — cerrar gaps de wrappers.
--
-- 1. Refactor create_group_resource para SOLO setear el GUC si está vacío.
--    Esto permite que wrappers padre (como el nuevo create_generic_resource)
--    impongan su propio intent_marker sin que el child lo overwriteee.
--
-- 2. Agregar create_generic_resource(...) para los 12 tipos sin subtype
--    table (document/other/vehicle/tool/inventory/real_estate/
--    intellectual_property/money/points/equity/time/seat). Setea
--    intent_marker='generic_resource_create' y delega a
--    create_group_resource. Valida que el tipo sea genérico (rechaza
--    los 6 con subtype: event/fund/space/asset/right/slot).

-- ============================================================
-- 1. create_group_resource — defensive GUC
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_group_resource(
    p_group_id uuid,
    p_resource_type text,
    p_name text,
    p_description text DEFAULT NULL::text,
    p_visibility text DEFAULT 'members'::text,
    p_ownership_kind text DEFAULT 'group'::text,
    p_owner_membership_id uuid DEFAULT NULL::uuid,
    p_custodian_membership_id uuid DEFAULT NULL::uuid,
    p_metadata jsonb DEFAULT '{}'::jsonb,
    p_client_id text DEFAULT NULL::text
)
RETURNS public.group_resources
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_existing public.group_resources%ROWTYPE;
    v_row      public.group_resources%ROWTYPE;
    v_existing_intent text;
BEGIN
    -- Defensive: only set the intent if a parent wrapper hasn't already
    -- declared a more specific one (e.g. create_generic_resource).
    v_existing_intent := current_setting('ruul.resource_create_intent', true);
    IF v_existing_intent IS NULL OR v_existing_intent = '' THEN
        PERFORM set_config('ruul.resource_create_intent', 'create_group_resource', true);
    END IF;

    PERFORM public.assert_permission(p_group_id, 'resources.create');

    IF p_client_id IS NOT NULL THEN
        SELECT * INTO v_existing FROM public.group_resources
        WHERE group_id = p_group_id AND client_id = p_client_id LIMIT 1;
        IF v_existing.id IS NOT NULL THEN RETURN v_existing; END IF;
    END IF;

    IF p_resource_type NOT IN (
        'event','fund','space','asset','document','other',
        'right','slot','vehicle','tool','inventory','real_estate',
        'intellectual_property','money','points','equity','time','seat'
    ) THEN
        RAISE EXCEPTION 'invalid resource_type: %', p_resource_type
            USING errcode = '22023';
    END IF;

    INSERT INTO public.group_resources (
        group_id, resource_type, name, description, status, visibility,
        ownership_kind, owner_membership_id, metadata, client_id, created_by
    ) VALUES (
        p_group_id, p_resource_type, btrim(p_name), p_description,
        'active', p_visibility, p_ownership_kind, p_owner_membership_id,
        COALESCE(p_metadata, '{}'::jsonb), p_client_id, auth.uid()
    )
    RETURNING * INTO v_row;

    PERFORM public.record_system_event(
        p_group_id, 'resource.created', 'resource', v_row.id,
        btrim(p_name),
        jsonb_build_object('resource_type', p_resource_type)
    );

    RETURN v_row;
END;
$function$;

-- ============================================================
-- 2. create_generic_resource — envelope-only for the 12 generic types
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_generic_resource(
    p_group_id uuid,
    p_resource_type text,
    p_name text,
    p_description text DEFAULT NULL::text,
    p_visibility text DEFAULT 'members'::text,
    p_ownership_kind text DEFAULT 'group'::text,
    p_owner_membership_id uuid DEFAULT NULL::uuid,
    p_metadata jsonb DEFAULT '{}'::jsonb,
    p_client_id text DEFAULT NULL::text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_row public.group_resources%ROWTYPE;
BEGIN
    -- Declare intent ANTES de delegar — create_group_resource respeta
    -- el marker porque ahora es defensive.
    PERFORM set_config('ruul.resource_create_intent', 'generic_resource_create', true);

    -- Sólo permite tipos sin subtype table (los 6 con subtype tienen sus
    -- propios wrappers atómicos en P2A).
    IF p_resource_type NOT IN (
        'document','other','vehicle','tool','inventory','real_estate',
        'intellectual_property','money','points','equity','time','seat'
    ) THEN
        RAISE EXCEPTION 'create_generic_resource: resource_type % has a subtype table — use the specific wrapper instead', p_resource_type
            USING errcode = '22023';
    END IF;

    SELECT * INTO v_row FROM public.create_group_resource(
        p_group_id              => p_group_id,
        p_resource_type         => p_resource_type,
        p_name                  => p_name,
        p_description           => p_description,
        p_visibility            => p_visibility,
        p_ownership_kind        => p_ownership_kind,
        p_owner_membership_id   => p_owner_membership_id,
        p_custodian_membership_id => NULL,
        p_metadata              => p_metadata,
        p_client_id             => p_client_id
    );

    RETURN v_row.id;
END;
$function$;
