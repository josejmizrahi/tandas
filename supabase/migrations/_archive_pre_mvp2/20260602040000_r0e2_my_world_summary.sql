-- R.0E.2 — my_world_summary() jsonb
--
-- Founder scope:
--   - Resolve auth.uid() → actor (D2: actors.id = profiles.id = auth.users.id for person)
--   - Consume actor_net_worth (NO recalc)
--   - 10 secciones: actor, net_worth, owned/managed/used/beneficiary_resources,
--     groups, controlled_entities, obligations, recent_activity, pending_decisions
--   - LIMIT 20 por sección
--   - Empty arrays si no hay datos
--   - NO crear tablas
--   - NO tocar iOS
--   - NO tocar money

CREATE OR REPLACE FUNCTION public.my_world_summary()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_uid uuid;
  v_actor_id uuid;
  v_actor jsonb;
  v_net_worth jsonb;
  v_owned jsonb;
  v_managed jsonb;
  v_used jsonb;
  v_beneficiary jsonb;
  v_groups jsonb;
  v_controlled jsonb;
  v_obligations jsonb;
  v_recent_activity jsonb;
  v_pending_decisions jsonb;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  v_actor_id := v_uid;

  IF NOT EXISTS (SELECT 1 FROM public.actors WHERE id = v_actor_id) THEN
    RAISE EXCEPTION 'actor not found for current user' USING errcode = '42501';
  END IF;

  -- actor
  SELECT jsonb_build_object(
    'id', a.id,
    'actor_kind', a.actor_kind,
    'display_name', a.display_name,
    'metadata', a.metadata
  ) INTO v_actor
    FROM public.actors a WHERE a.id = v_actor_id;

  -- net_worth (consume)
  v_net_worth := public.actor_net_worth(v_actor_id);

  -- owned_resources
  WITH owned AS (
    SELECT r.id, r.name, r.resource_type, r.group_id,
           rr.percent,
           COALESCE(r.metadata->>'currency', 'unknown') AS currency,
           COALESCE((r.metadata->>'estimated_value')::numeric, 0) AS estimated_value
      FROM public.resource_rights rr
      JOIN public.resources r ON r.id = rr.resource_id
     WHERE rr.holder_actor_id = v_actor_id
       AND rr.right_kind = 'OWN'
       AND rr.revoked_at IS NULL AND rr.expired_at IS NULL
       AND (rr.starts_at IS NULL OR rr.starts_at <= now())
       AND (rr.ends_at IS NULL OR rr.ends_at > now())
       AND r.archived_at IS NULL
     ORDER BY r.created_at DESC
     LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'resource_id', id, 'name', name, 'resource_type', resource_type,
    'group_id', group_id, 'percent', percent,
    'currency', currency, 'estimated_value', estimated_value
  )), '[]'::jsonb) INTO v_owned FROM owned;

  -- managed_resources
  WITH managed AS (
    SELECT r.id, r.name, r.resource_type, r.group_id
      FROM public.resource_rights rr
      JOIN public.resources r ON r.id = rr.resource_id
     WHERE rr.holder_actor_id = v_actor_id
       AND rr.right_kind = 'MANAGE'
       AND rr.revoked_at IS NULL AND rr.expired_at IS NULL
       AND (rr.starts_at IS NULL OR rr.starts_at <= now())
       AND (rr.ends_at IS NULL OR rr.ends_at > now())
       AND r.archived_at IS NULL
     ORDER BY r.created_at DESC
     LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'resource_id', id, 'name', name, 'resource_type', resource_type, 'group_id', group_id
  )), '[]'::jsonb) INTO v_managed FROM managed;

  -- used_resources
  WITH used AS (
    SELECT r.id, r.name, r.resource_type, r.group_id
      FROM public.resource_rights rr
      JOIN public.resources r ON r.id = rr.resource_id
     WHERE rr.holder_actor_id = v_actor_id
       AND rr.right_kind = 'USE'
       AND rr.revoked_at IS NULL AND rr.expired_at IS NULL
       AND (rr.starts_at IS NULL OR rr.starts_at <= now())
       AND (rr.ends_at IS NULL OR rr.ends_at > now())
       AND r.archived_at IS NULL
     ORDER BY r.created_at DESC
     LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'resource_id', id, 'name', name, 'resource_type', resource_type, 'group_id', group_id
  )), '[]'::jsonb) INTO v_used FROM used;

  -- beneficiary_resources
  WITH benef AS (
    SELECT r.id, r.name, r.resource_type, r.group_id,
           rr.percent,
           COALESCE(r.metadata->>'currency', 'unknown') AS currency,
           COALESCE((r.metadata->>'estimated_value')::numeric, 0) AS estimated_value
      FROM public.resource_rights rr
      JOIN public.resources r ON r.id = rr.resource_id
     WHERE rr.holder_actor_id = v_actor_id
       AND rr.right_kind = 'BENEFICIARY'
       AND rr.revoked_at IS NULL AND rr.expired_at IS NULL
       AND (rr.starts_at IS NULL OR rr.starts_at <= now())
       AND (rr.ends_at IS NULL OR rr.ends_at > now())
       AND r.archived_at IS NULL
     ORDER BY r.created_at DESC
     LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'resource_id', id, 'name', name, 'resource_type', resource_type,
    'group_id', group_id, 'percent', percent,
    'currency', currency, 'estimated_value', estimated_value
  )), '[]'::jsonb) INTO v_beneficiary FROM benef;

  -- groups
  WITH gs AS (
    SELECT g.id, g.name, gm.membership_type, gm.joined_via
      FROM public.group_memberships gm
      JOIN public.groups g ON g.id = gm.group_id
     WHERE gm.user_id = v_uid
       AND gm.status = 'active'
       AND g.archived_at IS NULL
     ORDER BY gm.created_at DESC
     LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'group_id', id, 'name', name,
    'membership_type', membership_type, 'joined_via', joined_via
  )), '[]'::jsonb) INTO v_groups FROM gs;

  -- controlled_entities
  WITH ctrl AS (
    SELECT a.id AS actor_id, a.display_name, a.actor_kind,
           ar.relationship_type, ar.metadata
      FROM public.actor_relationships ar
      JOIN public.actors a ON a.id = ar.object_actor_id
     WHERE ar.subject_actor_id = v_actor_id
       AND ar.relationship_type IN ('controls','shareholder_of','trustee_of','admin_of')
       AND ar.object_actor_id IS NOT NULL
       AND (ar.starts_at IS NULL OR ar.starts_at <= now())
       AND (ar.ends_at IS NULL OR ar.ends_at > now())
     ORDER BY ar.created_at DESC
     LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'actor_id', actor_id, 'display_name', display_name, 'actor_kind', actor_kind,
    'relationship_type', relationship_type, 'metadata', metadata
  )), '[]'::jsonb) INTO v_controlled FROM ctrl;

  -- obligations
  WITH oblig AS (
    SELECT ar.id, ar.relationship_type,
           ar.subject_actor_id, ar.object_actor_id, ar.object_resource_id,
           ar.metadata, ar.starts_at, ar.ends_at,
           CASE WHEN ar.subject_actor_id = v_actor_id THEN 'out' ELSE 'in' END AS direction
      FROM public.actor_relationships ar
     WHERE (ar.subject_actor_id = v_actor_id OR ar.object_actor_id = v_actor_id)
       AND ar.relationship_type IN ('debtor_to','creditor_of','guarantor_of')
       AND (ar.starts_at IS NULL OR ar.starts_at <= now())
       AND (ar.ends_at IS NULL OR ar.ends_at > now())
     ORDER BY ar.created_at DESC
     LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'relationship_id', id, 'relationship_type', relationship_type, 'direction', direction,
    'subject_actor_id', subject_actor_id,
    'object_actor_id', object_actor_id, 'object_resource_id', object_resource_id,
    'metadata', metadata
  )), '[]'::jsonb) INTO v_obligations FROM oblig;

  -- recent_activity
  WITH activity AS (
    SELECT ge.uuid_id, ge.event_type, ge.group_id, ge.entity_kind, ge.entity_id,
           ge.payload, ge.created_at
      FROM public.group_events ge
     WHERE ge.actor_user_id = v_uid
     ORDER BY ge.created_at DESC
     LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'event_id', uuid_id, 'event_type', event_type,
    'group_id', group_id, 'entity_kind', entity_kind, 'entity_id', entity_id,
    'payload', payload, 'created_at', created_at
  )), '[]'::jsonb) INTO v_recent_activity FROM activity;

  -- pending_decisions
  WITH pending AS (
    SELECT gd.id, gd.title, gd.group_id, gd.status, gd.created_at
      FROM public.group_decisions gd
      JOIN public.group_memberships gm
        ON gm.group_id = gd.group_id
       AND gm.user_id = v_uid
       AND gm.status = 'active'
     WHERE gd.status = 'open'
     ORDER BY gd.created_at DESC
     LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'decision_id', id, 'title', title, 'group_id', group_id,
    'status', status, 'created_at', created_at
  )), '[]'::jsonb) INTO v_pending_decisions FROM pending;

  RETURN jsonb_build_object(
    'actor', v_actor,
    'as_of', now(),
    'net_worth', v_net_worth,
    'owned_resources', v_owned,
    'managed_resources', v_managed,
    'used_resources', v_used,
    'beneficiary_resources', v_beneficiary,
    'groups', v_groups,
    'controlled_entities', v_controlled,
    'obligations', v_obligations,
    'recent_activity', v_recent_activity,
    'pending_decisions', v_pending_decisions,
    'notes', jsonb_build_object(
      'limit_per_section', 20,
      'value_source', 'resources.metadata->>estimated_value (vía actor_net_worth)',
      'money_section', 'NOT included in R.0E.2 — obligations limited to actor_relationships only'
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.my_world_summary() TO authenticated;

COMMENT ON FUNCTION public.my_world_summary() IS
  'R.0E.2. Auth-scoped summary del usuario. Resuelve auth.uid() → actor. Consume actor_net_worth(actor_id) sin recalcular. 10 secciones (actor, net_worth, owned/managed/used/beneficiary resources, groups, controlled_entities, obligations, recent_activity, pending_decisions). LIMIT 20 por sección. NO money table. NO iOS.';
