CREATE OR REPLACE FUNCTION public.group_membership_boundary(p_group_id uuid)
RETURNS TABLE (
  boundary_id       uuid,
  boundary_kind     text,
  membership_id     uuid,
  invite_id         uuid,
  user_id           uuid,
  display_name      text,
  username          text,
  avatar_url        text,
  status            text,
  membership_type   text,
  role_names        text[],
  joined_at         timestamptz,
  invited_at        timestamptz,
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
  WITH memberships AS (
    SELECT
      gm.id                                     AS boundary_id,
      'membership'::text                        AS boundary_kind,
      gm.id                                     AS membership_id,
      NULL::uuid                                AS invite_id,
      gm.user_id                                AS user_id,
      COALESCE(
        NULLIF(btrim(p.display_name), ''),
        NULLIF(btrim(p.username),     ''),
        'Miembro'
      )                                         AS display_name,
      p.username                                AS username,
      p.avatar_url                              AS avatar_url,
      gm.status                                 AS status,
      gm.membership_type                        AS membership_type,
      COALESCE(
        (SELECT array_agg(gr.name ORDER BY gr.name)
           FROM public.group_member_roles gmr
           JOIN public.group_roles        gr ON gr.id = gmr.role_id
          WHERE gmr.membership_id = gm.id),
        ARRAY[]::text[]
      )                                         AS role_names,
      gm.joined_at                              AS joined_at,
      NULL::timestamptz                         AS invited_at,
      (gm.user_id = v_uid)                      AS is_current_user
    FROM public.group_memberships gm
    LEFT JOIN public.profiles p ON p.id = gm.user_id
    WHERE gm.group_id = p_group_id
      AND gm.status IN ('active', 'invited', 'requested', 'suspended')
  ),
  invites AS (
    SELECT
      gi.id                                     AS boundary_id,
      'invite'::text                            AS boundary_kind,
      NULL::uuid                                AS membership_id,
      gi.id                                     AS invite_id,
      gi.invited_user_id                        AS user_id,
      COALESCE(
        NULLIF(btrim(p.display_name), ''),
        NULLIF(btrim(p.username),     ''),
        NULLIF(btrim(gi.email),       ''),
        NULLIF(btrim(gi.phone),       ''),
        'Invitado'
      )                                         AS display_name,
      p.username                                AS username,
      p.avatar_url                              AS avatar_url,
      'invited'::text                           AS status,
      COALESCE(
        NULLIF(btrim(gi.metadata->>'membership_type'), ''),
        'member'
      )                                         AS membership_type,
      ARRAY[]::text[]                           AS role_names,
      NULL::timestamptz                         AS joined_at,
      gi.created_at                             AS invited_at,
      false                                     AS is_current_user
    FROM public.group_invites gi
    LEFT JOIN public.profiles p ON p.id = gi.invited_user_id
    WHERE gi.group_id = p_group_id
      AND gi.status   = 'pending'
      AND (gi.expires_at IS NULL OR gi.expires_at > now())
      AND (
        gi.invited_user_id IS NULL
        OR NOT EXISTS (
          SELECT 1 FROM public.group_memberships gm
           WHERE gm.group_id = gi.group_id
             AND gm.user_id  = gi.invited_user_id
        )
      )
  )
  SELECT * FROM (
    SELECT * FROM memberships
    UNION ALL
    SELECT * FROM invites
  ) all_rows
  ORDER BY
    is_current_user DESC,
    CASE status
      WHEN 'active'    THEN 0
      WHEN 'requested' THEN 1
      WHEN 'invited'   THEN 2
      WHEN 'suspended' THEN 3
      ELSE 4
    END,
    CASE membership_type
      WHEN 'member'      THEN 0
      WHEN 'provisional' THEN 1
      ELSE 2
    END,
    display_name ASC,
    joined_at ASC NULLS LAST;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_membership_boundary(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_membership_boundary(uuid) TO authenticated;

COMMENT ON FUNCTION public.group_membership_boundary(uuid) IS
  'Foundation Primitiva 2 (mig 20260527010000): unified boundary view. UNIONs group_memberships (excl. left/banned) with non-expired pending group_invites. boundary_kind distinguishes membership vs invite. Auth: caller must be an active member.';
