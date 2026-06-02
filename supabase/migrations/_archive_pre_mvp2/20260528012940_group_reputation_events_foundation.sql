CREATE OR REPLACE FUNCTION public.group_reputation_events(
  p_group_id uuid,
  p_limit    int DEFAULT 100
)
RETURNS TABLE (
  event_id              uuid,
  group_id              uuid,
  subject_membership_id uuid,
  subject_display_name  text,
  actor_membership_id   uuid,
  actor_display_name    text,
  reputation_type       text,
  reason                text,
  evidence_entity_kind  text,
  evidence_entity_id    uuid,
  visibility            text,
  status                text,
  occurred_at           timestamptz,
  created_at            timestamptz
)
LANGUAGE plpgsql
STABLE SECURITY INVOKER
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
    e.id                                  AS event_id,
    e.group_id                            AS group_id,
    e.subject_membership_id               AS subject_membership_id,
    NULLIF(p_sub.display_name, '')        AS subject_display_name,
    e.actor_membership_id                 AS actor_membership_id,
    NULLIF(p_act.display_name, '')        AS actor_display_name,
    e.reputation_type                     AS reputation_type,
    e.reason                              AS reason,
    e.evidence_entity_kind                AS evidence_entity_kind,
    e.evidence_entity_id                  AS evidence_entity_id,
    e.visibility                          AS visibility,
    e.status                              AS status,
    e.occurred_at                         AS occurred_at,
    e.created_at                          AS created_at
  FROM public.group_reputation_events e
  LEFT JOIN public.group_memberships gm_sub ON gm_sub.id = e.subject_membership_id
  LEFT JOIN public.profiles          p_sub  ON p_sub.id  = gm_sub.user_id
  LEFT JOIN public.group_memberships gm_act ON gm_act.id = e.actor_membership_id
  LEFT JOIN public.profiles          p_act  ON p_act.id  = gm_act.user_id
  WHERE e.group_id = p_group_id
    AND e.status   = 'active'
    AND e.visibility <> 'private'
  ORDER BY e.occurred_at DESC, e.created_at DESC
  LIMIT GREATEST(1, COALESCE(p_limit, 100));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_reputation_events(uuid, int) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_reputation_events(uuid, int) TO authenticated;

COMMENT ON FUNCTION public.group_reputation_events(uuid, int) IS
  'Primitiva 12 Foundation (mig 20260527150000): group-wide reputation feed (active, not private). Pre-joined with subject + actor display names. Newest first by occurred_at. SECURITY INVOKER + active-member gate. NO score/ranking/badges — neutral facts only.';
