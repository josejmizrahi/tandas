-- 20260527140000 — group_contributions Foundation (Primitiva 9 — C3).
--
-- Primitiva 9 (Contribuciones): no-monetarias capturadas como
-- first-class (cuidado/moderación/docs/labor/time/idea/etc). Plan
-- doctrina: "registrar ≠ aprobar" — cualquier miembro registra su
-- propia contribución; verificación es paso aparte.
--
-- Tabla group_contributions ya canónica con CHECK constraints:
--   - contribution_type ∈ ('money','labor','time','idea','care',
--                          'moderation','content','contact','asset',
--                          'hosting','docs','trust','other')
--   - status ∈ ('claimed','verified','rejected','rewarded')
--
-- Foundation RPCs (verify_contribution deferido):
--   - group_contributions_active(...) — read filtrable por
--     membership/resource. Excluye rejected.
--   - log_contribution(...)            — self-claim. caller =
--     membership_id derivado de auth.uid().

-- ===========================================================================
-- 1. READ: group_contributions_active
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.group_contributions_active(
  p_group_id      uuid,
  p_membership_id uuid DEFAULT NULL,
  p_resource_id   uuid DEFAULT NULL
)
RETURNS TABLE (
  contribution_id          uuid,
  group_id                 uuid,
  membership_id            uuid,
  member_display_name      text,
  contribution_type        text,
  amount                   numeric,
  unit                     text,
  title                    text,
  description              text,
  source_resource_id       uuid,
  source_transaction_id    uuid,
  status                   text,
  verified_by              uuid,
  verified_by_display_name text,
  occurred_at              timestamptz,
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
    c.id                                  AS contribution_id,
    c.group_id                            AS group_id,
    c.membership_id                       AS membership_id,
    NULLIF(p_mem.display_name, '')        AS member_display_name,
    c.contribution_type                   AS contribution_type,
    c.amount                              AS amount,
    c.unit                                AS unit,
    c.title                               AS title,
    c.description                         AS description,
    c.source_resource_id                  AS source_resource_id,
    c.source_transaction_id               AS source_transaction_id,
    c.status                              AS status,
    c.verified_by                         AS verified_by,
    NULLIF(p_ver.display_name, '')        AS verified_by_display_name,
    c.occurred_at                         AS occurred_at,
    c.created_at                          AS created_at
  FROM public.group_contributions c
  LEFT JOIN public.group_memberships gm_mem ON gm_mem.id = c.membership_id
  LEFT JOIN public.profiles          p_mem  ON p_mem.id  = gm_mem.user_id
  LEFT JOIN public.profiles          p_ver  ON p_ver.id  = c.verified_by
  WHERE c.group_id = p_group_id
    AND c.status <> 'rejected'
    AND (p_membership_id IS NULL OR c.membership_id      = p_membership_id)
    AND (p_resource_id   IS NULL OR c.source_resource_id = p_resource_id)
  ORDER BY c.occurred_at DESC, c.created_at DESC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_contributions_active(uuid, uuid, uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_contributions_active(uuid, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.group_contributions_active(uuid, uuid, uuid) IS
  'Primitiva 9 Foundation (mig 20260527140000): non-rejected contributions of a group, optionally filtered by membership or source resource. Pre-joined with member + verified_by display names. SECURITY INVOKER + active-member gate. Order: occurred_at DESC, created_at DESC.';

-- ===========================================================================
-- 2. WRITE: log_contribution
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.log_contribution(
  p_group_id          uuid,
  p_contribution_type text,
  p_title             text DEFAULT NULL,
  p_description       text DEFAULT NULL,
  p_amount            numeric DEFAULT NULL,
  p_unit              text DEFAULT NULL,
  p_source_resource_id uuid DEFAULT NULL,
  p_occurred_at       timestamptz DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid           uuid := auth.uid();
  v_membership_id uuid;
  v_type          text;
  v_title         text;
  v_desc          text;
  v_unit          text;
  v_id            uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT id INTO v_membership_id
    FROM public.group_memberships
   WHERE group_id = p_group_id
     AND user_id  = v_uid
     AND status   = 'active'
   LIMIT 1;

  IF v_membership_id IS NULL THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  v_type := NULLIF(btrim(coalesce(p_contribution_type, '')), '');
  IF v_type IS NULL OR v_type NOT IN
    ('money','labor','time','idea','care','moderation','content',
     'contact','asset','hosting','docs','trust','other')
  THEN
    RAISE EXCEPTION 'invalid contribution type' USING errcode = '22023';
  END IF;

  v_title := NULLIF(btrim(coalesce(p_title, '')), '');
  v_desc  := NULLIF(btrim(coalesce(p_description, '')), '');
  v_unit  := NULLIF(btrim(coalesce(p_unit, '')), '');

  -- title OR description required so the row has at least one human
  -- identifier (no "phantom contributions" of just type+amount).
  IF v_title IS NULL AND v_desc IS NULL THEN
    RAISE EXCEPTION 'contribution requires a title or description' USING errcode = '22023';
  END IF;

  IF p_amount IS NOT NULL AND p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be positive when provided' USING errcode = '22023';
  END IF;

  -- amount + unit go together (either both or neither).
  IF (p_amount IS NULL) <> (v_unit IS NULL) THEN
    RAISE EXCEPTION 'amount and unit must be provided together' USING errcode = '22023';
  END IF;

  -- Resource (if linked) must belong to the same group.
  IF p_source_resource_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.group_resources r
     WHERE r.id = p_source_resource_id AND r.group_id = p_group_id
  ) THEN
    RAISE EXCEPTION 'source resource does not belong to this group' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(p_group_id, 'contribution.record');

  INSERT INTO public.group_contributions (
    group_id, membership_id, contribution_type,
    amount, unit, title, description,
    source_resource_id, status, occurred_at
  ) VALUES (
    p_group_id, v_membership_id, v_type,
    p_amount, v_unit, v_title, v_desc,
    p_source_resource_id, 'claimed', COALESCE(p_occurred_at, now())
  )
  RETURNING id INTO v_id;

  PERFORM public.record_system_event(
    p_group_id, 'contribution.logged', 'contribution', v_id,
    'Contribución registrada',
    jsonb_build_object(
      'contribution_type', v_type,
      'amount',            p_amount,
      'unit',              v_unit
    )
  );

  RETURN v_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.log_contribution(uuid, text, text, text, numeric, text, uuid, timestamptz) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.log_contribution(uuid, text, text, text, numeric, text, uuid, timestamptz) TO authenticated;

COMMENT ON FUNCTION public.log_contribution(uuid, text, text, text, numeric, text, uuid, timestamptz) IS
  'Primitiva 9 Foundation (mig 20260527140000): self-claim a contribution. Requires contribution.record. membership_id derived from auth.uid(). title or description required; amount+unit must come paired; source_resource_id must belong to group. Status starts at claimed; verify lands later. Emits contribution.logged event.';
