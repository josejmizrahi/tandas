CREATE OR REPLACE FUNCTION public.group_mandates_active(p_group_id uuid)
RETURNS TABLE (
  mandate_id                  uuid,
  group_id                    uuid,
  principal_type              text,
  principal_id                uuid,
  representative_membership_id uuid,
  representative_display_name text,
  mandate_type                text,
  scope                       jsonb,
  status                      text,
  starts_at                   timestamptz,
  ends_at                     timestamptz,
  source_decision_id          uuid,
  granted_by                  uuid,
  granted_by_display_name     text,
  created_at                  timestamptz,
  updated_at                  timestamptz
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
    m.id                                  AS mandate_id,
    m.group_id                            AS group_id,
    m.principal_type                      AS principal_type,
    m.principal_id                        AS principal_id,
    m.representative_membership_id        AS representative_membership_id,
    NULLIF(p_rep.display_name, '')        AS representative_display_name,
    m.mandate_type                        AS mandate_type,
    m.scope                               AS scope,
    m.status                              AS status,
    m.starts_at                           AS starts_at,
    m.ends_at                             AS ends_at,
    m.source_decision_id                  AS source_decision_id,
    m.granted_by                          AS granted_by,
    NULLIF(p_gb.display_name, '')         AS granted_by_display_name,
    m.created_at                          AS created_at,
    m.updated_at                          AS updated_at
  FROM public.group_mandates m
  LEFT JOIN public.group_memberships gm_rep ON gm_rep.id = m.representative_membership_id
  LEFT JOIN public.profiles          p_rep  ON p_rep.id  = gm_rep.user_id
  LEFT JOIN public.profiles          p_gb   ON p_gb.id   = m.granted_by
  WHERE m.group_id = p_group_id
    AND m.status   = 'active'
    AND (m.ends_at IS NULL OR m.ends_at > now())
  ORDER BY m.created_at DESC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_mandates_active(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_mandates_active(uuid) TO authenticated;

COMMENT ON FUNCTION public.group_mandates_active(uuid) IS
  'Primitiva 23 Foundation (mig 20260527130000): active mandates of a group (status=active AND (ends_at IS NULL OR ends_at > now())). Pre-joined with representative + granted_by display names. SECURITY INVOKER + active-member gate.';

CREATE OR REPLACE FUNCTION public.grant_mandate(
  p_group_id                    uuid,
  p_representative_membership_id uuid,
  p_mandate_type                text,
  p_principal_type              text DEFAULT 'group',
  p_principal_id                uuid DEFAULT NULL,
  p_scope                       jsonb DEFAULT '{}'::jsonb,
  p_ends_at                     timestamptz DEFAULT NULL,
  p_source_decision_id          uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_mtype     text;
  v_ptype     text;
  v_scope     jsonb;
  v_id        uuid;
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

  v_mtype := NULLIF(btrim(coalesce(p_mandate_type, '')), '');
  IF v_mtype IS NULL OR v_mtype NOT IN
    ('speak','sign','vote','negotiate','spend','represent','delegate','other')
  THEN
    RAISE EXCEPTION 'invalid mandate type' USING errcode = '22023';
  END IF;

  v_ptype := COALESCE(NULLIF(btrim(coalesce(p_principal_type, '')), ''), 'group');
  IF v_ptype NOT IN ('group','committee','role','membership') THEN
    RAISE EXCEPTION 'invalid principal type' USING errcode = '22023';
  END IF;

  IF v_ptype <> 'group' AND p_principal_id IS NULL THEN
    RAISE EXCEPTION 'principal_id required for non-group principal' USING errcode = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.id       = p_representative_membership_id
       AND gm.group_id = p_group_id
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'representative is not an active member of group %', p_group_id
      USING errcode = '22023';
  END IF;

  IF p_ends_at IS NOT NULL AND p_ends_at <= now() THEN
    RAISE EXCEPTION 'ends_at must be in the future' USING errcode = '22023';
  END IF;

  v_scope := COALESCE(p_scope, '{}'::jsonb);

  PERFORM public.assert_permission(p_group_id, 'mandates.grant');

  INSERT INTO public.group_mandates (
    group_id, principal_type, principal_id,
    representative_membership_id, mandate_type, scope,
    status, ends_at, source_decision_id, granted_by
  ) VALUES (
    p_group_id, v_ptype,
    CASE WHEN v_ptype = 'group' THEN NULL ELSE p_principal_id END,
    p_representative_membership_id, v_mtype, v_scope,
    'active', p_ends_at, p_source_decision_id, v_uid
  )
  RETURNING id INTO v_id;

  PERFORM public.record_system_event(
    p_group_id, 'mandate.granted', 'mandate', v_id,
    'Mandato otorgado',
    jsonb_build_object(
      'mandate_type',   v_mtype,
      'principal_type', v_ptype,
      'ends_at',        p_ends_at
    )
  );

  RETURN v_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.grant_mandate(uuid, uuid, text, text, uuid, jsonb, timestamptz, uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.grant_mandate(uuid, uuid, text, text, uuid, jsonb, timestamptz, uuid) TO authenticated;

COMMENT ON FUNCTION public.grant_mandate(uuid, uuid, text, text, uuid, jsonb, timestamptz, uuid) IS
  'Primitiva 23 Foundation (mig 20260527130000): otorga un mandato activo. Valida tipos + futuro ends_at + representative=active member. principal_id ignorado cuando principal_type=group. Requires mandates.grant. Emits mandate.granted event.';

CREATE OR REPLACE FUNCTION public.revoke_mandate(
  p_mandate_id uuid,
  p_reason     text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_group_id uuid;
  v_status   text;
  v_reason   text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT m.group_id, m.status
    INTO v_group_id, v_status
    FROM public.group_mandates m
   WHERE m.id = p_mandate_id
   FOR UPDATE;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'mandate not found' USING errcode = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = v_group_id
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', v_group_id
      USING errcode = '42501';
  END IF;

  PERFORM public.assert_permission(v_group_id, 'mandates.revoke');

  IF v_status <> 'active' THEN
    RETURN;
  END IF;

  v_reason := NULLIF(btrim(coalesce(p_reason, '')), '');

  UPDATE public.group_mandates
     SET status         = 'revoked',
         revoked_at     = now(),
         revoked_by     = v_uid,
         revoked_reason = v_reason,
         updated_at     = now()
   WHERE id = p_mandate_id;

  PERFORM public.record_system_event(
    v_group_id, 'mandate.revoked', 'mandate', p_mandate_id,
    'Mandato revocado',
    jsonb_build_object('reason', v_reason)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.revoke_mandate(uuid, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.revoke_mandate(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.revoke_mandate(uuid, text) IS
  'Primitiva 23 Foundation (mig 20260527130000): flips status active->revoked + sets revoked_at/by/reason. Idempotent for non-active rows. Requires mandates.revoke. Emits mandate.revoked event.';
