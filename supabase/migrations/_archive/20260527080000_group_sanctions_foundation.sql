-- 20260527080000 — group_sanctions Foundation (Primitiva 11 Sanciones).
--
-- Sanctions backend already ships `issue_sanction`, `update_sanction_status`
-- and `dispute_sanction`. What Foundation iOS needs is a *read* surface:
-- the canonical list of active+disputed sanctions per group, joined with
-- target/issuer display info so a single round-trip renders the list view.
--
-- Doctrina (Plan §B5): tipos no monetarios renderizan distinto
-- (warning sin monto, suspension con duración, repair_task con checklist).
-- Read RPC returns the full polymorphic shape; iOS picks what to render
-- per kind.
--
-- Active states from the canonical CHECK constraint: 'proposed', 'active',
-- 'disputed'. Resolved states ('reversed','completed','cancelled') are
-- explicitly excluded so the card surface stays focused on what needs
-- attention.

CREATE OR REPLACE FUNCTION public.group_sanctions_active(
  p_group_id uuid,
  p_limit    int DEFAULT 50
)
RETURNS TABLE (
  sanction_id              uuid,
  group_id                 uuid,
  target_membership_id     uuid,
  target_display_name      text,
  issued_by_membership_id  uuid,
  issued_by_display_name   text,
  sanction_kind            text,
  status                   text,
  amount                   numeric,
  unit                     text,
  reason                   text,
  starts_at                timestamptz,
  ends_at                  timestamptz,
  obligation_id            uuid,
  dispute_id               uuid,
  created_at               timestamptz
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
    s.id                                                            AS sanction_id,
    s.group_id                                                      AS group_id,
    s.target_membership_id                                          AS target_membership_id,
    COALESCE(NULLIF(tp.display_name, ''), 'Sin nombre')              AS target_display_name,
    s.issued_by_membership_id                                       AS issued_by_membership_id,
    COALESCE(NULLIF(ip.display_name, ''), NULL)                      AS issued_by_display_name,
    s.sanction_kind                                                 AS sanction_kind,
    s.status                                                        AS status,
    s.amount                                                        AS amount,
    s.unit                                                          AS unit,
    s.reason                                                        AS reason,
    s.starts_at                                                     AS starts_at,
    s.ends_at                                                       AS ends_at,
    s.obligation_id                                                 AS obligation_id,
    s.dispute_id                                                    AS dispute_id,
    s.created_at                                                    AS created_at
  FROM public.group_sanctions s
  JOIN public.group_memberships tm ON tm.id = s.target_membership_id
  LEFT JOIN public.profiles tp     ON tp.id = tm.user_id
  LEFT JOIN public.group_memberships im ON im.id = s.issued_by_membership_id
  LEFT JOIN public.profiles ip     ON ip.id = im.user_id
  WHERE s.group_id = p_group_id
    AND s.status IN ('proposed', 'active', 'disputed')
  ORDER BY s.created_at DESC
  LIMIT GREATEST(1, COALESCE(p_limit, 50));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_sanctions_active(uuid, int) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_sanctions_active(uuid, int) TO authenticated;

COMMENT ON FUNCTION public.group_sanctions_active(uuid, int) IS
  'Primitiva 11 Foundation (mig 20260527080000): active+disputed sanctions for a group, pre-joined with target/issuer display names. SECURITY INVOKER so RLS still gates row visibility. Caller must be an active member.';
