-- 20260527170000 — Disputes UI completion reads (Primitiva 14, C2).
--
-- Write surface already canonical: open_dispute / append_dispute_event /
-- record_dispute_resolution / escalate_dispute_to_vote / dispute_sanction.
-- This migration only adds the read side iOS needs to render the full
-- DisputeDetailView: a single dispute row pre-joined with display names,
-- and the append-only event timeline pre-joined with actor.

-- ===========================================================================
-- 1. READ: dispute_detail(p_dispute_id)
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.dispute_detail(p_dispute_id uuid)
RETURNS TABLE (
  dispute_id                 uuid,
  group_id                   uuid,
  opened_by_membership_id    uuid,
  opened_by_display_name     text,
  respondent_membership_id   uuid,
  respondent_display_name    text,
  mediator_membership_id     uuid,
  mediator_display_name      text,
  subject_kind               text,
  subject_id                 uuid,
  title                      text,
  description                text,
  status                     text,
  resolution_method          text,
  resolution                 text,
  escalated_decision_id      uuid,
  opened_at                  timestamptz,
  resolved_at                timestamptz,
  metadata                   jsonb,
  event_count                integer
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
#variable_conflict use_column
DECLARE
  v_uid uuid := auth.uid();
  v_gid uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT d.group_id INTO v_gid FROM public.group_disputes d WHERE d.id = p_dispute_id;
  IF v_gid IS NULL THEN
    RAISE EXCEPTION 'dispute not found' USING errcode = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = v_gid
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', v_gid
      USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    d.id                              AS dispute_id,
    d.group_id                        AS group_id,
    d.opened_by_membership_id         AS opened_by_membership_id,
    NULLIF(p_opener.display_name, '') AS opened_by_display_name,
    d.respondent_membership_id        AS respondent_membership_id,
    NULLIF(p_resp.display_name, '')   AS respondent_display_name,
    d.mediator_membership_id          AS mediator_membership_id,
    NULLIF(p_med.display_name, '')    AS mediator_display_name,
    d.subject_kind                    AS subject_kind,
    d.subject_id                      AS subject_id,
    d.title                           AS title,
    d.description                     AS description,
    d.status                          AS status,
    d.resolution_method               AS resolution_method,
    d.resolution                      AS resolution,
    d.escalated_decision_id           AS escalated_decision_id,
    d.opened_at                       AS opened_at,
    d.resolved_at                     AS resolved_at,
    d.metadata                        AS metadata,
    coalesce((SELECT count(*) FROM public.group_dispute_events e WHERE e.dispute_id = d.id), 0)::int AS event_count
  FROM public.group_disputes d
  LEFT JOIN public.group_memberships gm_o ON gm_o.id = d.opened_by_membership_id
  LEFT JOIN public.profiles          p_opener ON p_opener.id = gm_o.user_id
  LEFT JOIN public.group_memberships gm_r ON gm_r.id = d.respondent_membership_id
  LEFT JOIN public.profiles          p_resp ON p_resp.id = gm_r.user_id
  LEFT JOIN public.group_memberships gm_m ON gm_m.id = d.mediator_membership_id
  LEFT JOIN public.profiles          p_med ON p_med.id = gm_m.user_id
  WHERE d.id = p_dispute_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.dispute_detail(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.dispute_detail(uuid) TO authenticated;
COMMENT ON FUNCTION public.dispute_detail(uuid) IS
  'Primitiva 14 (mig 20260527170000): single dispute pre-joined with opener/respondent/mediator display names + event_count. Active-member gate.';

-- ===========================================================================
-- 2. READ: list_dispute_events(p_dispute_id, p_limit)
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.list_dispute_events(
  p_dispute_id uuid,
  p_limit      int DEFAULT 200
)
RETURNS TABLE (
  event_id              uuid,
  dispute_id            uuid,
  actor_membership_id   uuid,
  actor_display_name    text,
  event_type            text,
  body                  text,
  metadata              jsonb,
  created_at            timestamptz
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
#variable_conflict use_column
DECLARE
  v_uid uuid := auth.uid();
  v_gid uuid;
  v_limit int := least(greatest(coalesce(p_limit, 200), 1), 500);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT d.group_id INTO v_gid FROM public.group_disputes d WHERE d.id = p_dispute_id;
  IF v_gid IS NULL THEN
    RAISE EXCEPTION 'dispute not found' USING errcode = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = v_gid
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', v_gid
      USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    e.id                              AS event_id,
    e.dispute_id                      AS dispute_id,
    e.actor_membership_id             AS actor_membership_id,
    NULLIF(p.display_name, '')        AS actor_display_name,
    e.event_type                      AS event_type,
    e.body                            AS body,
    e.metadata                        AS metadata,
    e.created_at                      AS created_at
  FROM public.group_dispute_events e
  LEFT JOIN public.group_memberships gm ON gm.id = e.actor_membership_id
  LEFT JOIN public.profiles          p  ON p.id  = gm.user_id
  WHERE e.dispute_id = p_dispute_id
  ORDER BY e.created_at ASC, e.id ASC
  LIMIT v_limit;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.list_dispute_events(uuid, int) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.list_dispute_events(uuid, int) TO authenticated;
COMMENT ON FUNCTION public.list_dispute_events(uuid, int) IS
  'Primitiva 14 (mig 20260527170000): chronological event timeline for a dispute, pre-joined with actor display_name. Active-member gate. Append-only — order ASC by created_at.';
