-- Fase D follow-up: server-side filter por entity_kind+entity_id para
-- el activity feed del resource detail. Reemplaza el filter client-side
-- que perdia eventos viejos cuando el grupo emite >100 antes del scope
-- del recurso.

CREATE OR REPLACE FUNCTION public.group_events_for_entity(
  p_group_id    uuid,
  p_entity_kind text,
  p_entity_id   uuid,
  p_limit       int DEFAULT 50,
  p_before      timestamptz DEFAULT NULL
) RETURNS TABLE(
  event_uuid uuid,
  group_id uuid,
  actor_user_id uuid,
  actor_display_name text,
  event_type text,
  entity_kind text,
  entity_id uuid,
  summary text,
  payload jsonb,
  occurred_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id AND gm.user_id = v_uid AND gm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'not a member' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT ge.uuid_id, ge.group_id, ge.actor_user_id,
         COALESCE(pr.display_name, ''),
         ge.event_type, ge.entity_kind, ge.entity_id,
         ge.summary, ge.payload, ge.occurred_at
    FROM public.group_events ge
    LEFT JOIN public.profiles pr ON pr.id = ge.actor_user_id
   WHERE ge.group_id    = p_group_id
     AND ge.entity_kind = p_entity_kind
     AND ge.entity_id   = p_entity_id
     AND (p_before IS NULL OR ge.occurred_at < p_before)
   ORDER BY ge.occurred_at DESC, ge.id DESC
   LIMIT GREATEST(p_limit, 1);
END;
$$;

REVOKE ALL ON FUNCTION public.group_events_for_entity(uuid, text, uuid, int, timestamptz) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.group_events_for_entity(uuid, text, uuid, int, timestamptz) TO authenticated;

COMMENT ON FUNCTION public.group_events_for_entity(uuid, text, uuid, int, timestamptz) IS
'Returns events filtered by entity_kind+entity_id. Active-member gate. Used by the resource detail activity feed to avoid client-side filter losing events when the group has high event throughput.';
