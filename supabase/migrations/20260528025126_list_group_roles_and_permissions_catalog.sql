-- 20260527200000 — Roles + Permissions read surface (Primitiva 17, B3).
--
-- Schema canónico ya existe: group_roles (system + custom), group_role_permissions
-- (role × permission_key), permissions (catalog), group_member_roles
-- (membership × role). Write RPCs (create_custom_role,
-- update_role_permissions, assign_role_to_member, revoke_role_from_member)
-- también. Lo que falta para B3 son los reads:
--   1) list_group_roles(p_group_id) → roles del grupo con sus
--      permisos + member_count pre-joined
--   2) list_permissions_catalog() → catálogo global por categoría
--      (49 perms agrupadas en 12 buckets) para el editor UI

-- ===========================================================================
-- 1. READ: list_group_roles(p_group_id)
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.list_group_roles(p_group_id uuid)
RETURNS TABLE (
  role_id           uuid,
  group_id          uuid,
  key               text,
  name              text,
  description       text,
  is_system         boolean,
  is_default        boolean,
  permission_keys   text[],
  member_count      integer,
  created_at        timestamptz
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
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
    r.id                                                                AS role_id,
    r.group_id                                                          AS group_id,
    r.key                                                               AS key,
    r.name                                                              AS name,
    r.description                                                       AS description,
    r.is_system                                                         AS is_system,
    r.is_default                                                        AS is_default,
    coalesce(
      (SELECT array_agg(rp.permission_key ORDER BY rp.permission_key)
         FROM public.group_role_permissions rp
        WHERE rp.role_id = r.id),
      ARRAY[]::text[]
    )                                                                   AS permission_keys,
    coalesce(
      (SELECT count(*)::int FROM public.group_member_roles mr
        WHERE mr.role_id = r.id),
      0
    )                                                                   AS member_count,
    r.created_at                                                        AS created_at
  FROM public.group_roles r
  WHERE r.group_id = p_group_id
  ORDER BY r.is_system DESC, r.is_default DESC, lower(r.name) ASC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.list_group_roles(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.list_group_roles(uuid) TO authenticated;
COMMENT ON FUNCTION public.list_group_roles(uuid) IS
  'Primitiva 17 (mig 20260527200000): roles for a group with permission_keys[] and member_count pre-joined. Active-member gate.';

-- ===========================================================================
-- 2. READ: list_permissions_catalog()
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.list_permissions_catalog()
RETURNS TABLE (
  key         text,
  description text,
  category    text
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
#variable_conflict use_column
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT p.key, p.description, p.category
    FROM public.permissions p
   ORDER BY p.category ASC, p.key ASC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.list_permissions_catalog() FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.list_permissions_catalog() TO authenticated;
COMMENT ON FUNCTION public.list_permissions_catalog() IS
  'Primitiva 17 (mig 20260527200000): static permissions catalog (key, description, category). Authenticated-only gate; no group context needed.';
