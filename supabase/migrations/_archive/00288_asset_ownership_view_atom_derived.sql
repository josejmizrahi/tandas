-- 00288_asset_ownership_view_atom_derived.sql
--
-- Closes ConsistencyAudit_2026-05-17 finding F9 (last transitional debt).
--
-- Same pattern as Sprint 2.4 + 2.5 (right_state_view + atom-only right
-- RPCs): the ownership lifecycle of an asset is derived from the
-- assetTransferred atom chain, not from a mutable resources.metadata.owner_id.
--
-- This migration:
-- - Creates asset_ownership_view ordered by system_events.seq DESC.
--   Asset starts ownerless (create_asset doesn't set one); each
--   assetTransferred atom updates the holder to its payload.to_member_id
--   (null = transferred back to group, no individual owner).
-- - Rewrites transfer_asset to be atom-only. Drops the UPDATE on
--   resources.metadata (no more owner_id / ownership_changed_at writes).
--   Previous owner for the atom payload comes from asset_ownership_view
--   (derived from prior atoms in the same transaction).
-- - Production state at apply time: 1 asset row, 1 assetTransferred atom.
--   View derives the current owner from the existing atom; no backfill
--   needed. resources.metadata.owner_id values on existing rows become
--   stale / informational only — readers should consume the view.

-- =============================================================================
-- 1) asset_ownership_view — atom-derived
-- =============================================================================
CREATE OR REPLACE VIEW public.asset_ownership_view
WITH (security_invoker = on) AS
WITH owner_chain AS (
  SELECT DISTINCT ON (se.resource_id)
    se.resource_id                              AS asset_id,
    NULLIF(se.payload->>'to_member_id','')::uuid AS owner_member_id,
    se.occurred_at                              AS owner_since,
    se.id                                       AS source_atom_id
  FROM public.system_events se
  JOIN public.resources r
    ON r.id = se.resource_id
   AND r.resource_type = 'asset'
  WHERE se.event_type = 'assetTransferred'
  ORDER BY se.resource_id, se.seq DESC
)
SELECT
  r.id                                          AS asset_id,
  r.group_id,
  oc.owner_member_id,
  gm.user_id                                    AS owner_user_id,
  oc.owner_since,
  oc.source_atom_id,
  r.created_at                                  AS asset_created_at,
  r.archived_at
FROM public.resources r
LEFT JOIN owner_chain oc ON oc.asset_id = r.id
LEFT JOIN public.group_members gm ON gm.id = oc.owner_member_id
WHERE r.resource_type = 'asset';

COMMENT ON VIEW public.asset_ownership_view IS
  'F9 (mig 00288) per ConsistencyAudit. Atom-derived asset ownership. Owner = latest assetTransferred.payload.to_member_id per asset, ordered by system_events.seq DESC. NULL owner = group-owned (post-creation or transferred back). resources.metadata.owner_id is now informational cache only.';

-- =============================================================================
-- 2) Rewrite transfer_asset — atom-only
-- =============================================================================
CREATE OR REPLACE FUNCTION public.transfer_asset(
  p_asset_id      uuid,
  p_to_member_id  uuid,
  p_notes         text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
  v_prev_owner_id uuid;
  v_target_active boolean;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT group_id, resource_type INTO v_group_id, v_resource_type
    FROM public.resources WHERE id = p_asset_id;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'asset not found' USING errcode = '02000';
  END IF;
  IF v_resource_type <> 'asset' THEN
    RAISE EXCEPTION 'resource is not an asset' USING errcode = '22023';
  END IF;
  IF NOT public.is_group_member(v_group_id, v_caller_id) THEN
    RAISE EXCEPTION 'not a member of this group' USING errcode = '42501';
  END IF;

  -- Previous owner derived from asset_ownership_view (atom-driven). Within
  -- the same transaction the new atom hasn't been inserted yet, so the
  -- view returns the prior holder (NULL if asset was group-owned).
  SELECT owner_member_id INTO v_prev_owner_id
    FROM public.asset_ownership_view
   WHERE asset_id = p_asset_id;

  IF p_to_member_id IS NOT NULL THEN
    SELECT active INTO v_target_active
      FROM public.group_members
     WHERE id = p_to_member_id AND group_id = v_group_id;
    IF v_target_active IS NULL THEN
      RAISE EXCEPTION 'target member not in this group' USING errcode = '02000';
    END IF;
    IF NOT v_target_active THEN
      RAISE EXCEPTION 'target member not active' USING errcode = '22023';
    END IF;
  END IF;

  -- Idempotency: if the prior owner already matches the requested owner
  -- (both null = no-change-to-group; both same uuid = no-change), skip
  -- the atom emission. Prevents redundant chain entries on retry.
  IF v_prev_owner_id IS NOT DISTINCT FROM p_to_member_id THEN
    RETURN;
  END IF;

  -- Atom-only. NO UPDATE of resources.metadata.owner_id.
  PERFORM public.record_system_event(
    v_group_id,
    'assetTransferred',
    p_asset_id,
    p_to_member_id,
    jsonb_build_object(
      'transferred_by', v_caller_id,
      'from_member_id', v_prev_owner_id,
      'to_member_id',   p_to_member_id,
      'notes',          p_notes
    )
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.transfer_asset(uuid, uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.transfer_asset(uuid, uuid, text) TO authenticated;

COMMENT ON FUNCTION public.transfer_asset(uuid, uuid, text) IS
  'F9 (mig 00288). Atom-only. Drops UPDATE of resources.metadata.owner_id; ownership truth derives from asset_ownership_view. Idempotent: no-op when target equals current owner per view.';
