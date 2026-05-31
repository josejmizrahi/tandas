-- 20260527010000 — group_membership_boundary read helper (Primitiva 2).
--
-- Primitiva 1 (group_members) responde "¿quiénes son las personas?".
-- Primitiva 2 (boundary) responde "¿quién pertenece, quién está
-- pendiente, qué tipo de pertenencia tiene?".
--
-- Founder spec 2026-05-27: dejar `group_members(p_group_id)` intacto
-- y crear un helper canónico nuevo que UNIONa
--   - rows reales de group_memberships (excluye left/banned), y
--   - invites pendientes (group_invites WHERE status='pending'
--     AND expires_at > now())
-- en una sola superficie con `boundary_kind` distinguiendo membership
-- vs invite. Así iOS muestra "Invitación pendiente" sin hacer join
-- contra group_invites, y sin que membership_id mienta apuntando a un
-- invite_id.
--
-- Shape:
--   boundary_id       = membership_id si kind='membership', invite_id si 'invite'
--   boundary_kind     = 'membership' | 'invite'
--   membership_id     = gm.id (null para invites)
--   invite_id         = gi.id (null para memberships)
--   user_id           = gm.user_id | gi.invited_user_id (puede ser null)
--   display_name      = profile.display_name → profile.username → email → phone → 'Invitado'
--   username/avatar   = de profile cuando hay user_id, null si invite por email/phone sin match
--   status            = gm.status para memberships; 'invited' para invites pendientes
--   membership_type   = gm.membership_type | invite.metadata->>'membership_type' (default 'member')
--   role_names        = roles para memberships; array vacío para invites
--   joined_at         = gm.joined_at; null para invites
--   invited_at        = null para memberships; gi.created_at para invites
--   is_current_user   = gm.user_id = auth.uid(); false para invites
--
-- Orden:
--   1. current user primero
--   2. status priority (active → requested → invited → suspended)
--   3. membership_type (member → provisional)
--   4. display_name asc
--   5. joined_at asc nulls last
--
-- Errores canónicos:
--   - must be authenticated
--   - caller is not an active member of group <uuid>

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
-- `status`/`membership_type`/`display_name` collide between RETURN
-- TABLE OUT params and the inner CTE column names. Prefer the column
-- ref in PL/pgSQL so the ORDER BY clause resolves against the CTE.
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
      -- Don't double-count: if the invitee already has any membership
      -- row in this group (even non-active), prefer the membership row.
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
