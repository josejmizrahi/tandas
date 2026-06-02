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
#variable_conflict use_column
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

  SELECT gm.user_id INTO v_target_uid
    FROM public.group_memberships gm
   WHERE gm.id = p_membership_id AND gm.group_id = p_group_id;

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
