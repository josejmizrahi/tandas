-- 20260527120000 — group_cultural_norms Foundation (Primitiva 20).
--
-- Primitiva 20 (Culture) answers "¿qué nos hace ser este grupo?":
-- valores, tabúes, símbolos, historias, idioma, rituales, costumbres,
-- estética, principios. Declarativo, sin rule engine. La tabla
-- public.group_cultural_norms ya existe (00001 canonical schema) con
-- CHECK constraints:
--   - norm_type ∈ ('value','taboo','symbol','story','language',
--                  'ritual','custom','aesthetic','principle')
--   - status    ∈ ('proposed','endorsed','retired')
--   - visibility∈ ('private','members','public')
--
-- Foundation RPCs:
--   - group_cultural_norms_active(p_group_id) — read, excluye retired
--   - propose_cultural_norm(...)              — gated por culture.propose
--   - endorse_cultural_norm(p_norm_id)        — gated por culture.endorse
--   - retire_cultural_norm(p_norm_id, p_reason) — admin (group.update)
--
-- Doctrina: count agregado = señal cualitativa, no votación. No
-- tabla de endorsements per-user en Foundation; futuro slice puede
-- agregarla si necesitamos audit por usuario o desambiguar
-- "endorsado por mí".

-- ===========================================================================
-- 1. READ: group_cultural_norms_active
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.group_cultural_norms_active(p_group_id uuid)
RETURNS TABLE (
  norm_id        uuid,
  group_id       uuid,
  norm_type      text,
  title          text,
  body           text,
  visibility     text,
  status         text,
  endorsed_count integer,
  proposed_by    uuid,
  proposed_by_display_name text,
  created_at     timestamptz,
  updated_at     timestamptz
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
    n.id                                AS norm_id,
    n.group_id                          AS group_id,
    n.norm_type                         AS norm_type,
    n.title                             AS title,
    n.body                              AS body,
    n.visibility                        AS visibility,
    n.status                            AS status,
    n.endorsed_count                    AS endorsed_count,
    n.proposed_by                       AS proposed_by,
    NULLIF(p.display_name, '')          AS proposed_by_display_name,
    n.created_at                        AS created_at,
    n.updated_at                        AS updated_at
  FROM public.group_cultural_norms n
  LEFT JOIN public.profiles p ON p.id = n.proposed_by
  WHERE n.group_id = p_group_id
    AND n.status <> 'retired'
  ORDER BY n.endorsed_count DESC, n.created_at DESC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_cultural_norms_active(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_cultural_norms_active(uuid) TO authenticated;

COMMENT ON FUNCTION public.group_cultural_norms_active(uuid) IS
  'Primitiva 20 Foundation (mig 20260527120000): proposed+endorsed cultural norms of a group (excludes retired). Pre-joined with proposer display_name. Sorted by endorsed_count DESC then created_at DESC. SECURITY INVOKER + active-member gate.';

-- ===========================================================================
-- 2. WRITE: propose_cultural_norm
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.propose_cultural_norm(
  p_group_id   uuid,
  p_norm_type  text,
  p_title      text,
  p_body       text DEFAULT NULL,
  p_visibility text DEFAULT 'members'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_title text;
  v_body  text;
  v_type  text;
  v_vis   text;
  v_id    uuid;
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

  v_title := NULLIF(btrim(coalesce(p_title, '')), '');
  IF v_title IS NULL THEN
    RAISE EXCEPTION 'norm title required' USING errcode = '22023';
  END IF;

  v_body := NULLIF(btrim(coalesce(p_body, '')), '');

  v_type := COALESCE(NULLIF(btrim(coalesce(p_norm_type, '')), ''), 'value');
  IF v_type NOT IN ('value','taboo','symbol','story','language','ritual','custom','aesthetic','principle') THEN
    RAISE EXCEPTION 'invalid norm type' USING errcode = '22023';
  END IF;

  v_vis := COALESCE(NULLIF(btrim(coalesce(p_visibility, '')), ''), 'members');
  IF v_vis NOT IN ('private','members','public') THEN
    RAISE EXCEPTION 'invalid visibility' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(p_group_id, 'culture.propose');

  INSERT INTO public.group_cultural_norms (
    group_id, norm_type, title, body, visibility, status, proposed_by
  ) VALUES (
    p_group_id, v_type, v_title, v_body, v_vis, 'proposed', v_uid
  )
  RETURNING id INTO v_id;

  PERFORM public.record_system_event(
    p_group_id, 'cultural_norm.proposed', 'cultural_norm', v_id,
    'Norma cultural propuesta',
    jsonb_build_object(
      'norm_type',  v_type,
      'visibility', v_vis
    )
  );

  RETURN v_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.propose_cultural_norm(uuid, text, text, text, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.propose_cultural_norm(uuid, text, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.propose_cultural_norm(uuid, text, text, text, text) IS
  'Primitiva 20 Foundation (mig 20260527120000): proposes a new cultural norm in proposed state. Trims+validates type/visibility/title; body optional. Requires permission culture.propose. Emits cultural_norm.proposed event.';

-- ===========================================================================
-- 3. WRITE: endorse_cultural_norm
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.endorse_cultural_norm(p_norm_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_group_id  uuid;
  v_status    text;
  v_new_count integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT n.group_id, n.status
    INTO v_group_id, v_status
    FROM public.group_cultural_norms n
   WHERE n.id = p_norm_id
   FOR UPDATE;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'cultural norm not found' USING errcode = 'P0002';
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

  IF v_status = 'retired' THEN
    RAISE EXCEPTION 'cultural norm is retired' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_group_id, 'culture.endorse');

  UPDATE public.group_cultural_norms
     SET endorsed_count = endorsed_count + 1,
         status         = CASE WHEN status = 'proposed' THEN 'endorsed' ELSE status END,
         updated_at     = now()
   WHERE id = p_norm_id
  RETURNING endorsed_count INTO v_new_count;

  PERFORM public.record_system_event(
    v_group_id, 'cultural_norm.endorsed', 'cultural_norm', p_norm_id,
    'Norma cultural respaldada',
    jsonb_build_object('endorsed_count', v_new_count)
  );

  RETURN v_new_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.endorse_cultural_norm(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.endorse_cultural_norm(uuid) TO authenticated;

COMMENT ON FUNCTION public.endorse_cultural_norm(uuid) IS
  'Primitiva 20 Foundation (mig 20260527120000): increments endorsed_count and flips status proposed→endorsed on first endorse. Requires permission culture.endorse. Foundation does NOT track per-user endorsements (qualitative signal). Returns new count. Emits cultural_norm.endorsed event.';

-- ===========================================================================
-- 4. WRITE: retire_cultural_norm
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.retire_cultural_norm(
  p_norm_id uuid,
  p_reason  text DEFAULT NULL
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
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT n.group_id, n.status
    INTO v_group_id, v_status
    FROM public.group_cultural_norms n
   WHERE n.id = p_norm_id
   FOR UPDATE;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'cultural norm not found' USING errcode = 'P0002';
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

  -- Retiring is configurational: gated by the group-config permission.
  PERFORM public.assert_permission(v_group_id, 'group.update');

  IF v_status = 'retired' THEN
    RETURN;  -- idempotent
  END IF;

  UPDATE public.group_cultural_norms
     SET status     = 'retired',
         updated_at = now()
   WHERE id = p_norm_id;

  PERFORM public.record_system_event(
    v_group_id, 'cultural_norm.retired', 'cultural_norm', p_norm_id,
    'Norma cultural retirada',
    jsonb_build_object('reason', NULLIF(btrim(coalesce(p_reason,'')), ''))
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.retire_cultural_norm(uuid, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.retire_cultural_norm(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.retire_cultural_norm(uuid, text) IS
  'Primitiva 20 Foundation (mig 20260527120000): flips status to retired. Idempotent. Requires permission group.update (configurational decision, not member-level). Emits cultural_norm.retired event.';
