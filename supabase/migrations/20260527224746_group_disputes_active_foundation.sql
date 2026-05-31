-- 20260527090000 — group_disputes Foundation (Primitiva 14).
--
-- Disputes backend ya ships 5 RPCs (open_dispute, dispute_sanction,
-- append_dispute_event, escalate_dispute_to_vote, record_dispute_resolution).
-- Lo único que falta para Foundation iOS es una superficie de lectura
-- pre-joined: estado actual + display names + subject context.

CREATE OR REPLACE FUNCTION public.group_disputes_active(
  p_group_id uuid,
  p_limit    int DEFAULT 50
)
RETURNS TABLE (
  dispute_id              uuid,
  group_id                uuid,
  opened_by_membership_id uuid,
  opened_by_display_name  text,
  respondent_membership_id uuid,
  respondent_display_name  text,
  subject_kind            text,
  subject_id              uuid,
  title                   text,
  description             text,
  status                  text,
  mediator_membership_id  uuid,
  mediator_display_name   text,
  resolution_method       text,
  resolution              text,
  opened_at               timestamptz,
  resolved_at             timestamptz
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
    d.id                                                   AS dispute_id,
    d.group_id                                             AS group_id,
    d.opened_by_membership_id                              AS opened_by_membership_id,
    COALESCE(NULLIF(op.display_name, ''), NULL)            AS opened_by_display_name,
    d.respondent_membership_id                             AS respondent_membership_id,
    COALESCE(NULLIF(rp.display_name, ''), NULL)            AS respondent_display_name,
    d.subject_kind                                         AS subject_kind,
    d.subject_id                                           AS subject_id,
    d.title                                                AS title,
    d.description                                          AS description,
    d.status                                               AS status,
    d.mediator_membership_id                               AS mediator_membership_id,
    COALESCE(NULLIF(mp.display_name, ''), NULL)            AS mediator_display_name,
    d.resolution_method                                    AS resolution_method,
    d.resolution                                           AS resolution,
    d.opened_at                                            AS opened_at,
    d.resolved_at                                          AS resolved_at
  FROM public.group_disputes d
  LEFT JOIN public.group_memberships om ON om.id = d.opened_by_membership_id
  LEFT JOIN public.profiles op        ON op.id = om.user_id
  LEFT JOIN public.group_memberships rm ON rm.id = d.respondent_membership_id
  LEFT JOIN public.profiles rp        ON rp.id = rm.user_id
  LEFT JOIN public.group_memberships mm ON mm.id = d.mediator_membership_id
  LEFT JOIN public.profiles mp        ON mp.id = mm.user_id
  WHERE d.group_id = p_group_id
    AND d.status IN ('open', 'in_review', 'mediation', 'escalated')
  ORDER BY d.opened_at DESC
  LIMIT GREATEST(1, COALESCE(p_limit, 50));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_disputes_active(uuid, int) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_disputes_active(uuid, int) TO authenticated;

COMMENT ON FUNCTION public.group_disputes_active(uuid, int) IS
  'Primitiva 14 Foundation (mig 20260527090000): open disputes for a group, pre-joined with display names. Excludes resolved/dismissed/closed. SECURITY INVOKER + active-member gate.';
