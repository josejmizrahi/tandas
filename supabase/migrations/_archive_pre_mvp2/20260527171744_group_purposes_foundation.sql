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
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id AND gm.user_id = v_uid AND gm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id USING errcode = '42501';
  END IF;
  RETURN QUERY
  SELECT gp.id, gp.group_id, gp.kind, gp.body, gp.visibility, gp.status, gp.created_by, gp.created_at, gp.updated_at
    FROM public.group_purposes gp
   WHERE gp.group_id = p_group_id AND gp.status = 'active'
   ORDER BY CASE gp.kind WHEN 'declared' THEN 0 WHEN 'operative' THEN 1 WHEN 'emotional' THEN 2 ELSE 9 END,
            gp.updated_at ASC NULLS LAST;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.group_purposes_active(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_purposes_active(uuid) TO authenticated;
COMMENT ON FUNCTION public.group_purposes_active(uuid) IS
  'Primitiva 3 Foundation (mig 20260527020000): returns the group''s active purposes (declared/operative/emotional). Caller must be an active member.';

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
  IF v_kind NOT IN ('declared','operative','emotional') THEN
    RAISE EXCEPTION 'invalid purpose kind' USING errcode = '22023';
  END IF;
  v_visibility := COALESCE(NULLIF(btrim(p_visibility), ''), 'members');
  IF v_visibility NOT IN ('private','members','public') THEN
    RAISE EXCEPTION 'invalid purpose visibility' USING errcode = '22023';
  END IF;
  v_body := NULLIF(btrim(p_body), '');
  IF v_body IS NULL THEN
    RAISE EXCEPTION 'purpose body required' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(p_group_id, 'purpose.set');

  SELECT * INTO v_existing
    FROM public.group_purposes gp
   WHERE gp.group_id = p_group_id AND gp.kind = v_kind AND gp.status = 'active'
   FOR UPDATE;

  IF v_existing.id IS NOT NULL THEN
    UPDATE public.group_purposes
       SET body = v_body, visibility = v_visibility, updated_at = now()
     WHERE id = v_existing.id
     RETURNING * INTO v_row;
  ELSE
    INSERT INTO public.group_purposes (group_id, kind, body, visibility, status, created_by)
    VALUES (p_group_id, v_kind, v_body, v_visibility, 'active', v_uid)
    RETURNING * INTO v_row;
  END IF;

  IF v_kind = 'declared' THEN
    UPDATE public.groups SET purpose_summary = v_body WHERE id = p_group_id;
  END IF;

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
  'Primitiva 3 Foundation (mig 20260527020000): upsert the active purpose row for (group_id, kind). Requires permission purpose.set. Idempotent — re-setting same kind updates in place. Declared mirrors to groups.purpose_summary.';
