-- R.0C.2b — Universal Rights RPCs (grant_right / revoke_right / actor_has_right)
--
-- Coexisten con legacy grant_right/revoke_right (subtype semantics) vía overloading
-- por signature. Legacy continúa funcionando para iOS sin cambio; nuevas signatures
-- accionan sobre la universal resource_rights.
--
-- Active right (founder spec):
--   revoked_at IS NULL
--   expired_at IS NULL
--   (starts_at IS NULL OR starts_at <= now())
--   (ends_at IS NULL OR ends_at > now())
--
-- grant_right: upsert/undelete si existe row para (resource, holder, kind).
-- revoke_right: soft revoke idempotente.
-- actor_has_right: STABLE boolean.
--
-- Governance gating diferido a action_catalog (D.22+) en wrappers higher-level.

-- ============================================================
-- grant_right (universal overload)
-- ============================================================
CREATE OR REPLACE FUNCTION public.grant_right(
  p_resource_id        uuid,
  p_holder_actor_id    uuid,
  p_right_kind         text,
  p_percent            numeric DEFAULT NULL,
  p_scope              text DEFAULT NULL,
  p_starts_at          timestamptz DEFAULT NULL,
  p_ends_at            timestamptz DEFAULT NULL,
  p_source_decision_id uuid DEFAULT NULL,
  p_metadata           jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_id          uuid;
  v_existing_id uuid;
  v_sentinel    uuid := '00000000-0000-0000-0000-000000000000';
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  IF p_resource_id IS NULL THEN
    RAISE EXCEPTION 'resource_id required' USING errcode = '22023';
  END IF;
  IF p_right_kind IS NULL THEN
    RAISE EXCEPTION 'right_kind required' USING errcode = '22023';
  END IF;

  -- Find any matching row. Active rights primero, sino más reciente.
  SELECT id INTO v_existing_id
    FROM public.resource_rights
   WHERE resource_id = p_resource_id
     AND COALESCE(holder_actor_id, v_sentinel) = COALESCE(p_holder_actor_id, v_sentinel)
     AND right_kind = p_right_kind
   ORDER BY
     CASE WHEN revoked_at IS NULL AND expired_at IS NULL THEN 0 ELSE 1 END,
     granted_at DESC
   LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    -- UPSERT / UNDELETE
    UPDATE public.resource_rights
       SET percent            = p_percent,
           scope              = p_scope,
           starts_at          = p_starts_at,
           ends_at            = p_ends_at,
           source_decision_id = COALESCE(p_source_decision_id, source_decision_id),
           metadata           = metadata || COALESCE(p_metadata, '{}'::jsonb),
           revoked_at         = NULL,
           expired_at         = NULL,
           granted_at         = now()
     WHERE id = v_existing_id;
    v_id := v_existing_id;
  ELSE
    INSERT INTO public.resource_rights
      (resource_id, holder_actor_id, right_kind, percent, scope,
       starts_at, ends_at, source_decision_id, metadata)
    VALUES
      (p_resource_id, p_holder_actor_id, p_right_kind, p_percent, p_scope,
       p_starts_at, p_ends_at, p_source_decision_id, COALESCE(p_metadata, '{}'::jsonb))
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.grant_right(uuid, uuid, text, numeric, text, timestamptz, timestamptz, uuid, jsonb) TO authenticated;

COMMENT ON FUNCTION public.grant_right(uuid, uuid, text, numeric, text, timestamptz, timestamptz, uuid, jsonb) IS
  'R.0C.2b universal grant. Upsert/undelete: si existe row activa o revocada/expirada para (resource_id, holder_actor_id, right_kind), se reactiva. Sino, inserta. Governance gating diferido a action_catalog. Coexiste con legacy grant_right(p_holder_membership_id, …) que opera sobre resource_right_subtype.';

-- ============================================================
-- revoke_right (universal overload — distinta signature de la legacy)
-- ============================================================
CREATE OR REPLACE FUNCTION public.revoke_right(p_right_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  UPDATE public.resource_rights
     SET revoked_at = now()
   WHERE id = p_right_id
     AND revoked_at IS NULL;

  IF NOT FOUND THEN
    RAISE NOTICE 'revoke_right: % already revoked or not found', p_right_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.revoke_right(uuid) TO authenticated;

COMMENT ON FUNCTION public.revoke_right(uuid) IS
  'R.0C.2b universal soft revoke. revoked_at=now(). Idempotente (no-op si ya revocado). Sync trigger recalcula canonical_owner si OWN. Coexiste con legacy revoke_right(p_resource_id, p_reason, p_client_id).';

-- ============================================================
-- actor_has_right (nueva — no legacy version)
-- ============================================================
CREATE OR REPLACE FUNCTION public.actor_has_right(
  p_actor_id    uuid,
  p_resource_id uuid,
  p_right_kind  text
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.resource_rights
    WHERE resource_id = p_resource_id
      AND holder_actor_id = p_actor_id
      AND right_kind = p_right_kind
      AND revoked_at IS NULL
      AND expired_at IS NULL
      AND (starts_at IS NULL OR starts_at <= now())
      AND (ends_at IS NULL OR ends_at > now())
  );
$$;

GRANT EXECUTE ON FUNCTION public.actor_has_right(uuid, uuid, text) TO authenticated, anon;

COMMENT ON FUNCTION public.actor_has_right(uuid, uuid, text) IS
  'R.0C.2b STABLE boolean. Active right = revoked_at NULL + expired_at NULL + starts_at NULL/≤now + ends_at NULL/>now. Solo holder_actor_id explícito (NULL holders no chequeables aquí).';
