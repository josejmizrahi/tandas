-- 20260527020000 — group_purposes Foundation (Primitiva 3).
--
-- Primitiva 3 answers "¿para qué existe este grupo?". The doctrine
-- supports three purpose kinds living side-by-side:
--   - declared:   the statement the group puts forward.
--   - operative:  how it actually works day-to-day.
--   - emotional:  what it feels like to belong.
--
-- Schema (00001) already shapes `group_purposes` with the right
-- constraints (kind/status/visibility CHECKs, unique active per
-- (group_id, kind)). The catalog also already has the `purpose.set`
-- permission. This migration adds the two canonical RPCs Foundation
-- needs:
--
--   - public.group_purposes_active(p_group_id) → table (read helper).
--   - public.set_group_purpose(p_group_id, p_kind, p_body, p_visibility)
--     → upsert by kind; idempotent re-set updates the existing active
--     row instead of duplicating.
--
-- No archive RPC in this slice (founder spec). Visibility defaults to
-- 'members' so the basic "agregar propósito" sheet stays one-tap.

-- ===========================================================================
-- 1. RPC: group_purposes_active
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.group_purposes_active(p_group_id uuid)
RETURNS TABLE (
  purpose_id   uuid,
  group_id     uuid,
  kind         text,
  body         text,
  visibility   text,
  status       text,
  created_by   uuid,
  created_at   timestamptz,
  updated_at   timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
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
    SELECT 1
      FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    gp.id          AS purpose_id,
    gp.group_id    AS group_id,
    gp.kind        AS kind,
    gp.body        AS body,
    gp.visibility  AS visibility,
    gp.status      AS status,
    gp.created_by  AS created_by,
    gp.created_at  AS created_at,
    gp.updated_at  AS updated_at
  FROM public.group_purposes gp
  WHERE gp.group_id = p_group_id
    AND gp.status   = 'active'
  ORDER BY
    CASE gp.kind
      WHEN 'declared'  THEN 0
      WHEN 'operative' THEN 1
      WHEN 'emotional' THEN 2
      ELSE 9
    END,
    gp.updated_at ASC NULLS LAST;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_purposes_active(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_purposes_active(uuid) TO authenticated;

COMMENT ON FUNCTION public.group_purposes_active(uuid) IS
  'Primitiva 3 Foundation (mig 20260527020000): returns the group''s active purposes (declared/operative/emotional) for any active member. Excludes draft/archived. Caller must be an active member.';

-- ===========================================================================
-- 2. RPC: set_group_purpose
-- ===========================================================================
-- Idempotent upsert by kind: if an active row for (group_id, kind)
-- exists, update body/visibility/updated_at in place (preserving
-- created_at + created_by). Otherwise insert a new active row.
--
-- Auth: requires the `purpose.set` permission via assert_permission.
-- `assert_permission` is SECURITY DEFINER and checks
-- group_memberships.status='active' as part of the join, so it also
-- enforces "caller is an active member of the group".

-- Existing function had `RETURNS uuid` + archive-then-insert (versioning).
-- Founder spec for Foundation chose update-in-place (no version history
-- in this slice) and a richer return shape so iOS can render without a
-- follow-up read. Drop the old signature, then recreate.
DROP FUNCTION IF EXISTS public.set_group_purpose(uuid, text, text, text);

CREATE OR REPLACE FUNCTION public.set_group_purpose(
  p_group_id   uuid,
  p_kind       text,
  p_body       text,
  p_visibility text DEFAULT 'members'
)
RETURNS public.group_purposes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid        uuid := auth.uid();
  v_kind       text;
  v_body       text;
  v_visibility text;
  v_existing   public.group_purposes;
  v_row        public.group_purposes;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  v_kind := COALESCE(NULLIF(btrim(p_kind), ''), '');
  IF v_kind NOT IN ('declared', 'operative', 'emotional') THEN
    RAISE EXCEPTION 'invalid purpose kind' USING errcode = '22023';
  END IF;

  v_visibility := COALESCE(NULLIF(btrim(p_visibility), ''), 'members');
  IF v_visibility NOT IN ('private', 'members', 'public') THEN
    RAISE EXCEPTION 'invalid purpose visibility' USING errcode = '22023';
  END IF;

  v_body := NULLIF(btrim(p_body), '');
  IF v_body IS NULL THEN
    RAISE EXCEPTION 'purpose body required' USING errcode = '22023';
  END IF;

  -- Permission + active-membership gate (assert_permission joins on
  -- group_memberships.status='active' so it doubles as the active
  -- membership check).
  PERFORM public.assert_permission(p_group_id, 'purpose.set');

  -- Upsert by (group_id, kind) WHERE status='active'.
  SELECT * INTO v_existing
    FROM public.group_purposes gp
   WHERE gp.group_id = p_group_id
     AND gp.kind     = v_kind
     AND gp.status   = 'active'
   FOR UPDATE;

  IF v_existing.id IS NOT NULL THEN
    UPDATE public.group_purposes
       SET body       = v_body,
           visibility = v_visibility,
           updated_at = now()
     WHERE id = v_existing.id
     RETURNING * INTO v_row;
  ELSE
    INSERT INTO public.group_purposes (group_id, kind, body, visibility, status, created_by)
    VALUES (p_group_id, v_kind, v_body, v_visibility, 'active', v_uid)
    RETURNING * INTO v_row;
  END IF;

  -- Mirror the declared purpose into groups.purpose_summary so the
  -- group list/header surface stays in sync without an extra round
  -- trip. Preserved from the previous set_group_purpose impl.
  IF v_kind = 'declared' THEN
    UPDATE public.groups SET purpose_summary = v_body WHERE id = p_group_id;
  END IF;

  -- Best-effort audit. record_system_event is SECURITY DEFINER and
  -- never raises in the canonical path, so a failure here would
  -- bubble up — leave it as-is so we notice if it ever does.
  PERFORM public.record_system_event(
    p_group_id, 'purpose.set', 'purpose', v_row.id,
    'Propósito del grupo actualizado',
    jsonb_build_object('kind', v_row.kind, 'visibility', v_row.visibility)
  );

  RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_group_purpose(uuid, text, text, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.set_group_purpose(uuid, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.set_group_purpose(uuid, text, text, text) IS
  'Primitiva 3 Foundation (mig 20260527020000): upsert the active purpose row for (group_id, kind). Requires permission ''purpose.set''. Idempotent — re-setting the same kind updates the existing active row instead of duplicating. Raises ''must be authenticated'' | ''invalid purpose kind'' | ''invalid purpose visibility'' | ''purpose body required'' | ''caller lacks permission purpose.set in group <uuid>''.';
