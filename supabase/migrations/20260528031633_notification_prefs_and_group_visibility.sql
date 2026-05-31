-- 20260527220000 — Notifications + Privacy (B7).
--
-- Two thin surfaces:
--   1) my_notification_preferences(p_group_id) + set_notification_preference(...)
--      — per-user × per-group × per-category × per-channel toggle.
--   2) group_visibility(p_group_id) + set_group_visibility(...)
--      — group-level visibility (private / unlisted / public).
--
-- Categories are caller-defined text (notification_preferences has no
-- CHECK on category). iOS curates the canonical set in domain.

-- ===========================================================================
-- 1. READ: my_notification_preferences(p_group_id) → SETOF rows
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.my_notification_preferences(p_group_id uuid)
RETURNS TABLE (
  group_id   uuid,
  category   text,
  channel    text,
  enabled    boolean,
  updated_at timestamptz
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
  SELECT np.group_id, np.category, np.channel, np.enabled, np.updated_at
    FROM public.notification_preferences np
   WHERE np.user_id  = v_uid
     AND np.group_id = p_group_id
   ORDER BY np.category, np.channel;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.my_notification_preferences(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.my_notification_preferences(uuid) TO authenticated;
COMMENT ON FUNCTION public.my_notification_preferences(uuid) IS
  'B7 (mig 20260527220000): caller''s notification preferences for a group. Rows omitted = enabled by default (iOS handles the merge with curated category × channel grid). Active-member gate.';

-- ===========================================================================
-- 2. WRITE: set_notification_preference(...)
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.set_notification_preference(
  p_group_id uuid,
  p_category text,
  p_channel  text,
  p_enabled  boolean
)
RETURNS void
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
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  IF p_channel NOT IN ('push','email','sms','in_app') THEN
    RAISE EXCEPTION 'invalid channel: %', p_channel USING errcode = '22023';
  END IF;

  INSERT INTO public.notification_preferences (user_id, group_id, category, channel, enabled, updated_at)
  VALUES (v_uid, p_group_id, p_category, p_channel, p_enabled, now())
  ON CONFLICT (user_id, group_id, category, channel)
  DO UPDATE SET enabled = excluded.enabled, updated_at = now();
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_notification_preference(uuid, text, text, boolean) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.set_notification_preference(uuid, text, text, boolean) TO authenticated;
COMMENT ON FUNCTION public.set_notification_preference(uuid, text, text, boolean) IS
  'B7 (mig 20260527220000): upsert caller''s preference for a (group, category, channel) tuple. Active-member gate; channel validated.';

-- ===========================================================================
-- 3. READ: group_visibility(p_group_id) → text
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.group_visibility(p_group_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_vis text;
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

  SELECT visibility INTO v_vis FROM public.groups WHERE id = p_group_id;
  IF v_vis IS NULL THEN
    RAISE EXCEPTION 'group not found' USING errcode = 'P0002';
  END IF;
  RETURN v_vis;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_visibility(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_visibility(uuid) TO authenticated;
COMMENT ON FUNCTION public.group_visibility(uuid) IS
  'B7 (mig 20260527220000): returns groups.visibility text (private/unlisted/public). Active-member gate.';

-- ===========================================================================
-- 4. WRITE: set_group_visibility(p_group_id, p_visibility) → text
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.set_group_visibility(
  p_group_id   uuid,
  p_visibility text
)
RETURNS text
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

  PERFORM public.assert_permission(p_group_id, 'group.update');

  IF p_visibility NOT IN ('private','unlisted','public') THEN
    RAISE EXCEPTION 'invalid visibility: %', p_visibility USING errcode = '22023';
  END IF;

  UPDATE public.groups
     SET visibility = p_visibility,
         updated_at = now()
   WHERE id = p_group_id;

  PERFORM public.record_system_event(
    p_group_id, 'group.visibility_updated', 'group', p_group_id,
    'Visibilidad actualizada', jsonb_build_object('visibility', p_visibility)
  );

  RETURN p_visibility;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_group_visibility(uuid, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.set_group_visibility(uuid, text) TO authenticated;
COMMENT ON FUNCTION public.set_group_visibility(uuid, text) IS
  'B7 (mig 20260527220000): updates groups.visibility (private/unlisted/public). Requires group.update.';
