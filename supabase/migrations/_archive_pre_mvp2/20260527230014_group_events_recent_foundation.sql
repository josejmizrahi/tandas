-- 20260527100000 — group_events_recent Foundation (Primitiva 13 Memoria).
--
-- system_events ya es el feed canónico (append-only universal). record_system_event
-- escribe ahí desde sanciones, disputas, decisiones, propósito, recursos, reglas.
-- Lo único que falta para Foundation iOS es la superficie de lectura:
-- timeline neutral, newest-first, paginable por cursor.

CREATE OR REPLACE FUNCTION public.group_events_recent(
  p_group_id uuid,
  p_limit    int DEFAULT 100,
  p_before   timestamptz DEFAULT NULL
)
RETURNS TABLE (
  event_uuid          uuid,
  group_id            uuid,
  actor_user_id       uuid,
  actor_display_name  text,
  event_type          text,
  entity_kind         text,
  entity_id           uuid,
  summary             text,
  payload             jsonb,
  occurred_at         timestamptz
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
    e.uuid_id                                            AS event_uuid,
    e.group_id                                           AS group_id,
    e.actor_user_id                                      AS actor_user_id,
    COALESCE(NULLIF(p.display_name, ''), NULL)           AS actor_display_name,
    e.event_type                                         AS event_type,
    e.entity_kind                                        AS entity_kind,
    e.entity_id                                          AS entity_id,
    e.summary                                            AS summary,
    e.payload                                            AS payload,
    e.occurred_at                                        AS occurred_at
  FROM public.group_events e
  LEFT JOIN public.profiles p ON p.id = e.actor_user_id
  WHERE e.group_id = p_group_id
    AND (p_before IS NULL OR e.occurred_at < p_before)
  ORDER BY e.occurred_at DESC
  LIMIT GREATEST(1, COALESCE(p_limit, 100));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_events_recent(uuid, int, timestamptz) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_events_recent(uuid, int, timestamptz) TO authenticated;

COMMENT ON FUNCTION public.group_events_recent(uuid, int, timestamptz) IS
  'Primitiva 13 Foundation (mig 20260527100000): chronological feed of system_events for a group, newest first. p_before cursor for pagination. Pre-joined with actor display_name. SECURITY INVOKER + active-member gate.';
