-- R.0F — Group/Entity Backend Views (analógico a R.0E.2)
--
-- Founder scope locked:
--   - Consume actor_net_worth (group también es actor por R.0A doctrine)
--   - LIMIT 20 por sección, empty arrays si vacío
--   - NO money, NO new tables, NO iOS
--   - legal_entity_world_summary.recent_activity = empty array (no actor-event model claro)

-- ============================================================
-- group_world_summary
-- ============================================================
CREATE OR REPLACE FUNCTION public.group_world_summary(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_group jsonb;
  v_net_worth jsonb;
  v_members jsonb;
  v_resources_owned jsonb;
  v_resources_managed jsonb;
  v_resources_used jsonb;
  v_governance jsonb;
  v_rules jsonb;
  v_recent_activity jsonb;
BEGIN
  IF p_group_id IS NULL THEN
    RAISE EXCEPTION 'group_id required' USING errcode = '22023';
  END IF;

  SELECT jsonb_build_object(
    'id', g.id, 'name', g.name, 'slug', g.slug,
    'status', g.status, 'visibility', g.visibility,
    'actor_kind', a.actor_kind, 'metadata', g.settings
  ) INTO v_group
    FROM public.groups g
    LEFT JOIN public.actors a ON a.id = g.id
   WHERE g.id = p_group_id;

  IF v_group IS NULL THEN
    RAISE EXCEPTION 'group not found' USING errcode = 'P0002';
  END IF;

  v_net_worth := public.actor_net_worth(p_group_id);

  WITH ms AS (
    SELECT gm.id AS membership_id, gm.user_id, gm.membership_type,
           gm.status, gm.joined_via, gm.created_at, a.display_name
      FROM public.group_memberships gm
      LEFT JOIN public.actors a ON a.id = gm.user_id
     WHERE gm.group_id = p_group_id AND gm.status = 'active'
     ORDER BY gm.created_at DESC LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'membership_id', membership_id, 'user_id', user_id,
    'display_name', display_name,
    'membership_type', membership_type, 'status', status,
    'joined_via', joined_via, 'joined_at', created_at
  )), '[]'::jsonb) INTO v_members FROM ms;

  WITH ro AS (
    SELECT r.id, r.name, r.resource_type, rr.percent,
           COALESCE(r.metadata->>'currency','unknown') AS currency,
           COALESCE((r.metadata->>'estimated_value')::numeric, 0) AS estimated_value
      FROM public.resource_rights rr
      JOIN public.resources r ON r.id = rr.resource_id
     WHERE rr.holder_actor_id = p_group_id
       AND rr.right_kind = 'OWN'
       AND rr.revoked_at IS NULL AND rr.expired_at IS NULL
       AND (rr.starts_at IS NULL OR rr.starts_at <= now())
       AND (rr.ends_at IS NULL OR rr.ends_at > now())
       AND r.archived_at IS NULL
     ORDER BY r.created_at DESC LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'resource_id', id, 'name', name, 'resource_type', resource_type,
    'percent', percent, 'currency', currency, 'estimated_value', estimated_value
  )), '[]'::jsonb) INTO v_resources_owned FROM ro;

  WITH rm AS (
    SELECT r.id, r.name, r.resource_type
      FROM public.resource_rights rr
      JOIN public.resources r ON r.id = rr.resource_id
     WHERE rr.holder_actor_id = p_group_id
       AND rr.right_kind = 'MANAGE'
       AND rr.revoked_at IS NULL AND rr.expired_at IS NULL
       AND (rr.starts_at IS NULL OR rr.starts_at <= now())
       AND (rr.ends_at IS NULL OR rr.ends_at > now())
       AND r.archived_at IS NULL
     ORDER BY r.created_at DESC LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'resource_id', id, 'name', name, 'resource_type', resource_type
  )), '[]'::jsonb) INTO v_resources_managed FROM rm;

  WITH ru AS (
    SELECT r.id, r.name, r.resource_type
      FROM public.resource_rights rr
      JOIN public.resources r ON r.id = rr.resource_id
     WHERE rr.holder_actor_id = p_group_id
       AND rr.right_kind = 'USE'
       AND rr.revoked_at IS NULL AND rr.expired_at IS NULL
       AND (rr.starts_at IS NULL OR rr.starts_at <= now())
       AND (rr.ends_at IS NULL OR rr.ends_at > now())
       AND r.archived_at IS NULL
     ORDER BY r.created_at DESC LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'resource_id', id, 'name', name, 'resource_type', resource_type
  )), '[]'::jsonb) INTO v_resources_used FROM ru;

  WITH gv AS (
    SELECT gd.id, gd.title, gd.status, gd.created_at
      FROM public.group_decisions gd
     WHERE gd.group_id = p_group_id
       AND (gd.status = 'open' OR gd.created_at > now() - interval '30 days')
     ORDER BY CASE WHEN gd.status='open' THEN 0 ELSE 1 END, gd.created_at DESC
     LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'decision_id', id, 'title', title, 'status', status, 'created_at', created_at
  )), '[]'::jsonb) INTO v_governance FROM gv;

  WITH rls AS (
    SELECT id, title, created_at
      FROM public.group_rules
     WHERE group_id = p_group_id AND status = 'active'
     ORDER BY created_at DESC LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'rule_id', id, 'title', title, 'created_at', created_at
  )), '[]'::jsonb) INTO v_rules FROM rls;

  WITH activity AS (
    SELECT ge.uuid_id, ge.event_type, ge.entity_kind, ge.entity_id,
           ge.actor_user_id, ge.payload, ge.created_at
      FROM public.group_events ge
     WHERE ge.group_id = p_group_id
     ORDER BY ge.created_at DESC LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'event_id', uuid_id, 'event_type', event_type,
    'entity_kind', entity_kind, 'entity_id', entity_id,
    'actor_user_id', actor_user_id, 'payload', payload, 'created_at', created_at
  )), '[]'::jsonb) INTO v_recent_activity FROM activity;

  RETURN jsonb_build_object(
    'group', v_group,
    'as_of', now(),
    'net_worth', v_net_worth,
    'members', v_members,
    'resources_owned', v_resources_owned,
    'resources_managed', v_resources_managed,
    'resources_used', v_resources_used,
    'governance', v_governance,
    'rules', v_rules,
    'recent_activity', v_recent_activity,
    'notes', jsonb_build_object(
      'limit_per_section', 20,
      'net_worth_source', 'actor_net_worth(group_id) — group ES actor por R.0A'
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.group_world_summary(uuid) TO authenticated, anon;

COMMENT ON FUNCTION public.group_world_summary(uuid) IS
  'R.0F group view. Análogo a my_world_summary pero scoped a un grupo. Consume actor_net_worth(group_id) (group es actor por R.0A). LIMIT 20 por sección. No money table.';

-- ============================================================
-- legal_entity_world_summary
-- ============================================================
CREATE OR REPLACE FUNCTION public.legal_entity_world_summary(p_actor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_entity jsonb;
  v_net_worth jsonb;
  v_owned jsonb;
  v_controlled jsonb;
  v_shareholders jsonb;
  v_beneficiaries jsonb;
  v_controlling jsonb;
  v_obligations jsonb;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'actor_id required' USING errcode = '22023';
  END IF;

  SELECT jsonb_build_object(
    'id', a.id, 'display_name', a.display_name, 'actor_kind', a.actor_kind,
    'entity_type', le.entity_type, 'tax_id', le.tax_id,
    'jurisdiction', le.jurisdiction,
    'actor_metadata', a.metadata, 'entity_metadata', le.metadata
  ) INTO v_entity
    FROM public.actors a
    JOIN public.legal_entities le ON le.id = a.id
   WHERE a.id = p_actor_id AND a.actor_kind = 'legal_entity';

  IF v_entity IS NULL THEN
    RAISE EXCEPTION 'legal_entity not found for actor_id %', p_actor_id USING errcode = 'P0002';
  END IF;

  v_net_worth := public.actor_net_worth(p_actor_id);

  WITH o AS (
    SELECT r.id, r.name, r.resource_type, rr.percent,
           COALESCE(r.metadata->>'currency','unknown') AS currency,
           COALESCE((r.metadata->>'estimated_value')::numeric, 0) AS estimated_value
      FROM public.resource_rights rr
      JOIN public.resources r ON r.id = rr.resource_id
     WHERE rr.holder_actor_id = p_actor_id
       AND rr.right_kind = 'OWN'
       AND rr.revoked_at IS NULL AND rr.expired_at IS NULL
       AND (rr.starts_at IS NULL OR rr.starts_at <= now())
       AND (rr.ends_at IS NULL OR rr.ends_at > now())
       AND r.archived_at IS NULL
     ORDER BY r.created_at DESC LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'resource_id', id, 'name', name, 'resource_type', resource_type,
    'percent', percent, 'currency', currency, 'estimated_value', estimated_value
  )), '[]'::jsonb) INTO v_owned FROM o;

  WITH c AS (
    SELECT r.id, r.name, r.resource_type
      FROM public.resource_rights rr
      JOIN public.resources r ON r.id = rr.resource_id
     WHERE rr.holder_actor_id = p_actor_id
       AND rr.right_kind = 'MANAGE'
       AND rr.revoked_at IS NULL AND rr.expired_at IS NULL
       AND (rr.starts_at IS NULL OR rr.starts_at <= now())
       AND (rr.ends_at IS NULL OR rr.ends_at > now())
       AND r.archived_at IS NULL
     ORDER BY r.created_at DESC LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'resource_id', id, 'name', name, 'resource_type', resource_type
  )), '[]'::jsonb) INTO v_controlled FROM c;

  WITH sh AS (
    SELECT ar.subject_actor_id, a.display_name, a.actor_kind, ar.metadata
      FROM public.actor_relationships ar
      JOIN public.actors a ON a.id = ar.subject_actor_id
     WHERE ar.object_actor_id = p_actor_id
       AND ar.relationship_type = 'shareholder_of'
       AND (ar.starts_at IS NULL OR ar.starts_at <= now())
       AND (ar.ends_at IS NULL OR ar.ends_at > now())
     ORDER BY ar.created_at DESC LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'actor_id', subject_actor_id, 'display_name', display_name,
    'actor_kind', actor_kind, 'metadata', metadata
  )), '[]'::jsonb) INTO v_shareholders FROM sh;

  WITH bn AS (
    SELECT ar.subject_actor_id, a.display_name, a.actor_kind, ar.metadata
      FROM public.actor_relationships ar
      JOIN public.actors a ON a.id = ar.subject_actor_id
     WHERE ar.object_actor_id = p_actor_id
       AND ar.relationship_type = 'beneficiary_of'
       AND (ar.starts_at IS NULL OR ar.starts_at <= now())
       AND (ar.ends_at IS NULL OR ar.ends_at > now())
     ORDER BY ar.created_at DESC LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'actor_id', subject_actor_id, 'display_name', display_name,
    'actor_kind', actor_kind, 'metadata', metadata
  )), '[]'::jsonb) INTO v_beneficiaries FROM bn;

  WITH cs AS (
    SELECT ar.subject_actor_id, a.display_name, a.actor_kind,
           ar.relationship_type, ar.metadata
      FROM public.actor_relationships ar
      JOIN public.actors a ON a.id = ar.subject_actor_id
     WHERE ar.object_actor_id = p_actor_id
       AND ar.relationship_type IN ('controls','trustee_of')
       AND (ar.starts_at IS NULL OR ar.starts_at <= now())
       AND (ar.ends_at IS NULL OR ar.ends_at > now())
     ORDER BY ar.created_at DESC LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'actor_id', subject_actor_id, 'display_name', display_name,
    'actor_kind', actor_kind, 'relationship_type', relationship_type, 'metadata', metadata
  )), '[]'::jsonb) INTO v_controlling FROM cs;

  WITH ob AS (
    SELECT ar.id, ar.relationship_type,
           ar.subject_actor_id, ar.object_actor_id, ar.object_resource_id,
           ar.metadata,
           CASE WHEN ar.subject_actor_id = p_actor_id THEN 'out' ELSE 'in' END AS direction
      FROM public.actor_relationships ar
     WHERE (ar.subject_actor_id = p_actor_id OR ar.object_actor_id = p_actor_id)
       AND ar.relationship_type IN ('debtor_to','creditor_of','guarantor_of')
       AND (ar.starts_at IS NULL OR ar.starts_at <= now())
       AND (ar.ends_at IS NULL OR ar.ends_at > now())
     ORDER BY ar.created_at DESC LIMIT 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'relationship_id', id, 'relationship_type', relationship_type, 'direction', direction,
    'subject_actor_id', subject_actor_id,
    'object_actor_id', object_actor_id, 'object_resource_id', object_resource_id,
    'metadata', metadata
  )), '[]'::jsonb) INTO v_obligations FROM ob;

  RETURN jsonb_build_object(
    'entity', v_entity,
    'as_of', now(),
    'net_worth', v_net_worth,
    'owned_resources', v_owned,
    'controlled_resources', v_controlled,
    'shareholders', v_shareholders,
    'beneficiaries', v_beneficiaries,
    'controlling_actors', v_controlling,
    'obligations', v_obligations,
    'recent_activity', '[]'::jsonb,
    'notes', jsonb_build_object(
      'limit_per_section', 20,
      'recent_activity', 'EMPTY by design (R.0F) — no actor-event model for legal_entity. Future iteration when event model supports actor-scoped queries.'
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.legal_entity_world_summary(uuid) TO authenticated, anon;

COMMENT ON FUNCTION public.legal_entity_world_summary(uuid) IS
  'R.0F legal entity view. Análogo a group_world_summary pero scoped a legal entity. Consume actor_net_worth. recent_activity = empty (no actor-event model). LIMIT 20 por sección. No money.';
