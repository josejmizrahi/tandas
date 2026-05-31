-- 20260527040000 — group_resources Foundation (Primitiva 5).
--
-- Primitiva 5 answers "¿qué cosas, fondos, espacios, documentos o
-- activos tiene este grupo?". Foundation only ships the envelope
-- (`group_resources`) — no bookings, RSVP, transactions, asset
-- valuations, or any subtype-specific UI. The five types iOS
-- exposes today are:
--   - fund      (envelope only; subtype `group_resource_funds` not
--                written here — see the legacy `create_resource(...)`
--                if/when the full fund flow lands)
--   - space
--   - asset     (envelope only; custodian_membership_id stays as a
--                follow-up on the asset subtype slice)
--   - document
--   - other
--
-- Engine-level types (event/slot/right/money/time/points/data/access)
-- stay supported at the table level but are filtered out by the read
-- RPC so the Foundation UI doesn't accidentally render them.
--
-- archive_resource(p_resource_id, p_reason) ALREADY EXISTS and does
-- exactly what we need (assert_permission('resources.archive') + open
-- obligations guard + emit `resource.archived`). Reused as-is from
-- iOS via the same param shape.
--
-- The existing `create_resource(...)` RPC accepts p_subtype_payload
-- and inserts subtype rows for event/fund/slot/space/asset/right.
-- Foundation calls a new, simpler `create_group_resource(...)` that
-- only writes the envelope — keeps the surface area small and avoids
-- creating half-formed subtype rows we'd need to backfill later.

-- ===========================================================================
-- 1. RPC: group_resources_active
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.group_resources_active(p_group_id uuid)
RETURNS TABLE (
  resource_id              uuid,
  group_id                 uuid,
  resource_type            text,
  name                     text,
  description              text,
  status                   text,
  visibility               text,
  ownership_kind           text,
  owner_membership_id      uuid,
  custodian_membership_id  uuid,
  created_by               uuid,
  created_at               timestamptz,
  updated_at               timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
#variable_conflict use_column
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    gr.id                                                   AS resource_id,
    gr.group_id                                             AS group_id,
    gr.resource_type                                        AS resource_type,
    gr.name                                                 AS name,
    gr.description                                          AS description,
    gr.status                                               AS status,
    gr.visibility                                           AS visibility,
    gr.ownership_kind                                       AS ownership_kind,
    gr.owner_membership_id                                  AS owner_membership_id,
    -- custodian_membership_id is asset-subtype only today. Surface
    -- as null on the envelope so iOS can render a uniform column.
    NULL::uuid                                              AS custodian_membership_id,
    gr.created_by                                           AS created_by,
    gr.created_at                                           AS created_at,
    gr.updated_at                                           AS updated_at
  FROM public.group_resources gr
  WHERE gr.group_id = p_group_id
    AND gr.status   = 'active'
    AND gr.resource_type IN ('fund','space','asset','document','other')
  ORDER BY
    CASE gr.resource_type
      WHEN 'fund'     THEN 0
      WHEN 'space'    THEN 1
      WHEN 'asset'    THEN 2
      WHEN 'document' THEN 3
      WHEN 'other'    THEN 4
      ELSE 9
    END,
    gr.name ASC,
    gr.created_at DESC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_resources_active(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_resources_active(uuid) TO authenticated;

COMMENT ON FUNCTION public.group_resources_active(uuid) IS
  'Primitiva 5 Foundation (mig 20260527040000): active resources for a group, filtered to Foundation types (fund/space/asset/document/other). Caller must be an active member.';

-- ===========================================================================
-- 2. RPC: create_group_resource
-- ===========================================================================
-- Envelope-only insert. Does NOT touch subtype tables — fund/space/
-- asset/document/other use defaults until a later slice wires the
-- subtype-specific flows. Returns the new public.group_resources row.

CREATE OR REPLACE FUNCTION public.create_group_resource(
  p_group_id                 uuid,
  p_resource_type            text,
  p_name                     text,
  p_description              text DEFAULT NULL,
  p_visibility               text DEFAULT 'members',
  p_ownership_kind           text DEFAULT 'group',
  p_owner_membership_id      uuid DEFAULT NULL,
  p_custodian_membership_id  uuid DEFAULT NULL
)
RETURNS public.group_resources
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid           uuid := auth.uid();
  v_type          text;
  v_name          text;
  v_description   text;
  v_visibility    text;
  v_ownership     text;
  v_metadata      jsonb := '{}'::jsonb;
  v_row           public.group_resources;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  v_type := COALESCE(NULLIF(btrim(coalesce(p_resource_type, '')), ''), '');
  IF v_type NOT IN ('fund', 'space', 'asset', 'document', 'other') THEN
    RAISE EXCEPTION 'invalid resource type' USING errcode = '22023';
  END IF;

  v_name := NULLIF(btrim(coalesce(p_name, '')), '');
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'resource name required' USING errcode = '22023';
  END IF;

  v_description := NULLIF(btrim(coalesce(p_description, '')), '');

  v_visibility := COALESCE(NULLIF(btrim(coalesce(p_visibility, '')), ''), 'members');
  IF v_visibility NOT IN ('private', 'members', 'public') THEN
    RAISE EXCEPTION 'invalid resource visibility' USING errcode = '22023';
  END IF;

  -- Foundation iOS exposes ownership kinds {group, individual, external}
  -- (the wire token `individual` maps to "member-owned" in iOS).
  v_ownership := COALESCE(NULLIF(btrim(coalesce(p_ownership_kind, '')), ''), 'group');
  IF v_ownership NOT IN ('group', 'individual', 'external') THEN
    RAISE EXCEPTION 'invalid ownership kind' USING errcode = '22023';
  END IF;

  -- Validate owner membership ↔ group when provided.
  IF p_owner_membership_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.group_memberships
       WHERE id = p_owner_membership_id AND group_id = p_group_id
    ) THEN
      RAISE EXCEPTION 'owner membership not in group %', p_group_id
        USING errcode = '22023';
    END IF;
  END IF;

  -- Validate custodian membership ↔ group when provided. The envelope
  -- doesn't have a column for it yet; stash it in metadata so a later
  -- asset slice can promote it to group_resource_assets.custodian.
  IF p_custodian_membership_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.group_memberships
       WHERE id = p_custodian_membership_id AND group_id = p_group_id
    ) THEN
      RAISE EXCEPTION 'custodian membership not in group %', p_group_id
        USING errcode = '22023';
    END IF;
    v_metadata := v_metadata || jsonb_build_object(
      'foundation_custodian_membership_id', p_custodian_membership_id::text
    );
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
    p_group_id, 'resource.created', 'resource', v_row.id,
    v_name,
    jsonb_build_object(
      'resource_type',  v_type,
      'visibility',     v_visibility,
      'ownership_kind', v_ownership
    )
  );

  RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_group_resource(uuid, text, text, text, text, text, uuid, uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.create_group_resource(uuid, text, text, text, text, text, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.create_group_resource(uuid, text, text, text, text, text, uuid, uuid) IS
  'Primitiva 5 Foundation (mig 20260527040000): envelope-only create for a group_resources row (no subtype writes). Foundation allowed types: fund/space/asset/document/other. Requires permission resources.create. Custodian id (for asset subtype) is stashed in metadata.foundation_custodian_membership_id pending a later subtype slice. archive_resource(rule_id) handles the inverse.';
