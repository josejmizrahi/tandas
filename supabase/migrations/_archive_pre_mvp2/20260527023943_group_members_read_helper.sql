CREATE OR REPLACE FUNCTION public.group_members(p_group_id uuid)
RETURNS TABLE (
  membership_id     uuid,
  user_id           uuid,
  display_name      text,
  username          text,
  avatar_url        text,
  status            text,
  membership_type   text,
  role_names        text[],
  joined_at         timestamptz,
  is_current_user   boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
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
    gm.id                                                     AS membership_id,
    gm.user_id                                                AS user_id,
    COALESCE(
      NULLIF(btrim(p.display_name), ''),
      NULLIF(btrim(p.username),     ''),
      'Miembro'
    )                                                         AS display_name,
    p.username                                                AS username,
    p.avatar_url                                              AS avatar_url,
    gm.status                                                 AS status,
    gm.membership_type                                        AS membership_type,
    COALESCE(
      (SELECT array_agg(gr.name ORDER BY gr.name)
         FROM public.group_member_roles gmr
         JOIN public.group_roles        gr ON gr.id = gmr.role_id
        WHERE gmr.membership_id = gm.id),
      ARRAY[]::text[]
    )                                                         AS role_names,
    gm.joined_at                                              AS joined_at,
    (gm.user_id = v_uid)                                      AS is_current_user
  FROM public.group_memberships gm
  LEFT JOIN public.profiles p ON p.id = gm.user_id
  WHERE gm.group_id = p_group_id
    AND gm.status IN ('active', 'invited', 'requested', 'suspended')
  ORDER BY
    (gm.user_id = v_uid) DESC,
    CASE gm.status
      WHEN 'active'    THEN 0
      WHEN 'requested' THEN 1
      WHEN 'invited'   THEN 2
      WHEN 'suspended' THEN 3
      ELSE 4
    END,
    CASE gm.membership_type
      WHEN 'member'      THEN 0
      WHEN 'provisional' THEN 1
      ELSE 2
    END,
    COALESCE(NULLIF(btrim(p.display_name), ''),
             NULLIF(btrim(p.username),     ''),
             'Miembro') ASC,
    gm.joined_at ASC NULLS LAST;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_members(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_members(uuid) TO authenticated;

COMMENT ON FUNCTION public.group_members(uuid) IS
  'Foundation members slice (mig 20260526113000): pre-joined member rows for a group (membership × profile × roles). Visible statuses: active/invited/requested/suspended. Auth: caller must be an active member. Raises ''must be authenticated'' | ''caller is not an active member of group <uuid>''.';
