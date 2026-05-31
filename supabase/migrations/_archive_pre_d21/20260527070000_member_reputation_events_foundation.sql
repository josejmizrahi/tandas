-- 20260527070000 — member reputation events Foundation (Primitiva 12 Trust).
--
-- Trust per doctrine: "registro auditable de momentos, NO score público".
-- The canonical `group_reputation_events` table is append-only with three
-- visibility tiers (private/members/public) and a RLS SELECT policy that
-- already routes via visibility + records.read permission for private rows.
--
-- This migration adds the two RPCs Foundation needs:
--   - `member_reputation_events(p_group_id, p_subject_membership_id, p_limit)`
--     → table (read; active-member gate; respects visibility via RLS).
--   - `record_reputation_event(...)` → public.group_reputation_events
--     (write; requires permission `reputation.record`; intended to be
--      called by backend triggers/edge functions, not by user-facing UX).

-- ===========================================================================
-- 1. RPC: member_reputation_events
-- ===========================================================================
-- Returns the visible reputation events for a single subject membership,
-- newest first, capped by p_limit (default 50). Caller must be an active
-- member of the group. RLS on the underlying table further filters by
-- visibility, so private rows only surface when the caller has
-- `records.read`.

CREATE OR REPLACE FUNCTION public.member_reputation_events(
  p_group_id              uuid,
  p_subject_membership_id uuid,
  p_limit                 int DEFAULT 50
)
RETURNS TABLE (
  event_id              uuid,
  group_id              uuid,
  subject_membership_id uuid,
  actor_membership_id   uuid,
  reputation_type       text,
  reason                text,
  evidence_entity_kind  text,
  evidence_entity_id    uuid,
  visibility            text,
  status                text,
  metadata              jsonb,
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
    r.id                    AS event_id,
    r.group_id              AS group_id,
    r.subject_membership_id AS subject_membership_id,
    r.actor_membership_id   AS actor_membership_id,
    r.reputation_type       AS reputation_type,
    r.reason                AS reason,
    r.evidence_entity_kind  AS evidence_entity_kind,
    r.evidence_entity_id    AS evidence_entity_id,
    r.visibility            AS visibility,
    r.status                AS status,
    r.metadata              AS metadata,
    r.occurred_at           AS occurred_at,
    r.created_at            AS created_at
  FROM public.group_reputation_events r
  WHERE r.group_id              = p_group_id
    AND r.subject_membership_id = p_subject_membership_id
    AND r.status                = 'active'
  ORDER BY r.occurred_at DESC
  LIMIT GREATEST(1, COALESCE(p_limit, 50));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.member_reputation_events(uuid, uuid, int) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.member_reputation_events(uuid, uuid, int) TO authenticated;

COMMENT ON FUNCTION public.member_reputation_events(uuid, uuid, int) IS
  'Primitiva 12 Foundation (mig 20260527070000): visible reputation events for a single subject membership, newest first. SECURITY INVOKER so RLS visibility tiers apply (public/members/private records.read).';

-- ===========================================================================
-- 2. RPC: record_reputation_event
-- ===========================================================================
-- SECURITY DEFINER write path. Gated by `reputation.record` permission.
-- Intended for backend triggers, edge functions or admin tooling — NOT
-- a user-facing "marcar trust" affordance (doctrine bans that).

CREATE OR REPLACE FUNCTION public.record_reputation_event(
  p_group_id              uuid,
  p_subject_membership_id uuid,
  p_reputation_type       text,
  p_reason                text DEFAULT NULL,
  p_evidence_entity_kind  text DEFAULT NULL,
  p_evidence_entity_id    uuid DEFAULT NULL,
  p_visibility            text DEFAULT 'members',
  p_metadata              jsonb DEFAULT '{}'::jsonb
)
RETURNS public.group_reputation_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_type      text;
  v_vis       text;
  v_actor_mid uuid;
  v_row       public.group_reputation_events;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  v_type := COALESCE(NULLIF(btrim(p_reputation_type), ''), '');
  IF v_type NOT IN (
    'trust_event','contribution_recognized','commitment_kept','commitment_broken',
    'conflict_resolved','care_shown','leadership_shown','rule_violation',
    'reliability_signal','skill_signal','other'
  ) THEN
    RAISE EXCEPTION 'invalid reputation type' USING errcode = '22023';
  END IF;

  v_vis := COALESCE(NULLIF(btrim(p_visibility), ''), 'members');
  IF v_vis NOT IN ('private','members','public') THEN
    RAISE EXCEPTION 'invalid reputation visibility' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(p_group_id, 'reputation.record');

  SELECT gm.id INTO v_actor_mid
    FROM public.group_memberships gm
   WHERE gm.group_id = p_group_id
     AND gm.user_id  = v_uid
     AND gm.status   = 'active'
   LIMIT 1;

  INSERT INTO public.group_reputation_events (
    group_id, subject_membership_id, actor_membership_id,
    reputation_type, reason, evidence_entity_kind, evidence_entity_id,
    visibility, status, metadata
  )
  VALUES (
    p_group_id, p_subject_membership_id, v_actor_mid,
    v_type, NULLIF(btrim(COALESCE(p_reason,'')), ''), p_evidence_entity_kind, p_evidence_entity_id,
    v_vis, 'active', COALESCE(p_metadata, '{}'::jsonb)
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.record_reputation_event(uuid, uuid, text, text, text, uuid, text, jsonb) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.record_reputation_event(uuid, uuid, text, text, text, uuid, text, jsonb) TO authenticated;

COMMENT ON FUNCTION public.record_reputation_event(uuid, uuid, text, text, text, uuid, text, jsonb) IS
  'Primitiva 12 Foundation (mig 20260527070000): append a reputation event. Requires permission ''reputation.record''. NOT user-facing UX — doctrine forbids manual trust marking. Raises ''must be authenticated'' | ''invalid reputation type'' | ''invalid reputation visibility'' | ''caller lacks permission reputation.record in group <uuid>''.';
