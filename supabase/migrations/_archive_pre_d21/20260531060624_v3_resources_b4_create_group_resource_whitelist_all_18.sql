-- Hot-fix detected during Fase B.4 smoke: create_group_resource validates
-- p_resource_type against a 10-element whitelist while the CHECK on
-- group_resources.resource_type allows 18. Sync the RPC to the canonical
-- 18-element whitelist + expand ownership_kind whitelist from 3 to 5.

CREATE OR REPLACE FUNCTION public.create_group_resource(
  p_group_id uuid,
  p_resource_type text,
  p_name text,
  p_description text DEFAULT NULL,
  p_visibility text DEFAULT 'members',
  p_ownership_kind text DEFAULT 'group',
  p_owner_membership_id uuid DEFAULT NULL,
  p_custodian_membership_id uuid DEFAULT NULL
) RETURNS group_resources
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_type text; v_name text; v_description text; v_visibility text; v_ownership text;
  v_metadata jsonb := '{}'::jsonb;
  v_row public.group_resources;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'must be authenticated' USING errcode = '42501'; END IF;
  v_type := COALESCE(NULLIF(btrim(coalesce(p_resource_type, '')), ''), '');
  IF v_type NOT IN (
    'event','fund','slot','space','asset','right',
    'money','time','points',
    'document','data','access','other',
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
  IF v_ownership NOT IN ('group','individual','shared','custodial','external') THEN
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
$$;

COMMENT ON FUNCTION public.create_group_resource(uuid, text, text, text, text, text, uuid, uuid) IS
'Creates an envelope group_resources row. Validates resource_type vs the canonical 18-type whitelist + ownership_kind vs the 5-value whitelist. Emits resource.created.';
