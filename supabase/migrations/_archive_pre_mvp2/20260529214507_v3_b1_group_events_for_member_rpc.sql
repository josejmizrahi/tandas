-- V3 Batch B-1 — group_events_for_member read RPC
--
-- MemberDetailView quiere mostrar la timeline de actividad afectando
-- a un miembro específico (Universal Detail bloque 5).
-- group_events_recent es group-wide; necesitamos filtrar por:
--   (a) entity_kind='membership' AND entity_id = membership_id
--       → member.joined / member.state_changed / role.granted / role.revoked
--   (b) actor_user_id = resolved user_id
--       → cosas que ESTA persona hizo (voted, contributed, etc.)
--
-- Active-member gate igual que group_events_recent.

CREATE OR REPLACE FUNCTION public.group_events_for_member(
  p_group_id uuid,
  p_membership_id uuid,
  p_limit int DEFAULT 20
) RETURNS TABLE(
  id bigint,
  uuid_id uuid,
  group_id uuid,
  actor_user_id uuid,
  event_type text,
  entity_kind text,
  entity_id uuid,
  summary text,
  payload jsonb,
  occurred_at timestamptz,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_target_uid uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id
       AND gm.user_id = v_uid
       AND gm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  SELECT user_id INTO v_target_uid
    FROM public.group_memberships
   WHERE id = p_membership_id AND group_id = p_group_id;

  RETURN QUERY
  SELECT ge.id, ge.uuid_id, ge.group_id, ge.actor_user_id, ge.event_type,
         ge.entity_kind, ge.entity_id, ge.summary, ge.payload,
         ge.occurred_at, ge.created_at
    FROM public.group_events ge
   WHERE ge.group_id = p_group_id
     AND (
       (ge.entity_kind = 'membership' AND ge.entity_id = p_membership_id)
       OR (v_target_uid IS NOT NULL AND ge.actor_user_id = v_target_uid)
     )
   ORDER BY ge.created_at DESC
   LIMIT GREATEST(p_limit, 1);
END;
$function$;

REVOKE ALL ON FUNCTION public.group_events_for_member(uuid, uuid, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.group_events_for_member(uuid, uuid, int) TO authenticated;

COMMENT ON FUNCTION public.group_events_for_member(uuid, uuid, int) IS
  'V3 Batch B-1: timeline events for a member — entity-side (membership mutations) + actor-side (things they did). Active-member gate.';
