-- 20260529...: V3-INV — group_membership_boundary now joins the
-- placeholder membership to its source invite (V3-R0) so iOS can
-- expose the invite_id on the placeholder row for swipe-to-revoke,
-- and so the legacy "invite" branch stops duplicating the row when a
-- placeholder already exists.
--
-- Changes vs the previous version:
--   1. memberships CTE LEFT JOINs group_invites by
--      placeholder_membership_id and carries the invite_id forward.
--   2. The display_name fallback for invited placeholders without a
--      profile now pulls from the invite's email/phone metadata
--      (which is what the inviter typed) instead of "Miembro".
--   3. invites CTE filter additionally excludes rows whose
--      placeholder_membership_id is already represented in memberships.

DROP FUNCTION IF EXISTS public.group_membership_boundary(uuid);

CREATE OR REPLACE FUNCTION public.group_membership_boundary(p_group_id uuid)
RETURNS TABLE (
  boundary_id      uuid,
  boundary_kind    text,
  membership_id    uuid,
  invite_id        uuid,
  user_id          uuid,
  display_name     text,
  username         text,
  avatar_url       text,
  status           text,
  membership_type  text,
  role_names       text[],
  joined_at        timestamptz,
  invited_at       timestamptz,
  is_current_user  boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $function$
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
  WITH memberships AS (
    SELECT
      gm.id                                     AS boundary_id,
      'membership'::text                        AS boundary_kind,
      gm.id                                     AS membership_id,
      gi.id                                     AS invite_id,
      gm.user_id                                AS user_id,
      COALESCE(
        NULLIF(btrim(p.display_name), ''),
        NULLIF(btrim(p.username),     ''),
        NULLIF(btrim(gi.email),       ''),
        NULLIF(btrim(gi.phone),       ''),
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
      gi.created_at                             AS invited_at,
      (gm.user_id = v_uid)                      AS is_current_user
    FROM public.group_memberships gm
    LEFT JOIN public.profiles p ON p.id = gm.user_id
    LEFT JOIN public.group_invites gi
           ON gi.placeholder_membership_id = gm.id
          AND gi.status = 'pending'
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
      AND gi.placeholder_membership_id IS NULL   -- V3-INV: placeholder rows already surface via memberships CTE
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
$function$;

COMMENT ON FUNCTION public.group_membership_boundary(uuid) IS
  'V3-INV (mig 20260529221000): group_membership_boundary now exposes the linked invite_id on placeholder memberships (via LEFT JOIN to group_invites on placeholder_membership_id) so iOS can swipe-to-revoke directly from the row. Display name falls back to invite email/phone when the placeholder has no profile yet. Invites whose placeholder already exists are excluded from the invite CTE to avoid duplicates.';
