-- PARTE 12 — fix operativo: group_events_recent ORDER BY ahora incluye tie-break
-- secundario `id DESC` (bigint cursor monotónico). Sin este tie-break la
-- pagination era no-determinística cuando múltiples eventos compartían
-- occurred_at (caso real: RPCs que emiten varios eventos en la misma tx).
--
-- iOS-facing API unchanged: la RPC sigue retornando el mismo set de columnas
-- y aceptando `p_before timestamptz`. El cambio es interno al ORDER BY.

CREATE OR REPLACE FUNCTION public.group_events_recent(
  p_group_id uuid,
  p_limit integer DEFAULT 100,
  p_before timestamp with time zone DEFAULT NULL::timestamp with time zone
)
RETURNS TABLE(
  event_uuid uuid, group_id uuid, actor_user_id uuid, actor_display_name text,
  event_type text, entity_kind text, entity_id uuid, summary text,
  payload jsonb, occurred_at timestamp with time zone
)
LANGUAGE plpgsql STABLE
SET search_path TO 'public', 'pg_catalog'
AS $function$
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
  ORDER BY e.occurred_at DESC, e.id DESC
  LIMIT GREATEST(1, COALESCE(p_limit, 100));
END;
$function$;

-- PARTE 8b posture
REVOKE ALL ON FUNCTION public.group_events_recent(uuid,integer,timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.group_events_recent(uuid,integer,timestamptz) TO authenticated, service_role;
