-- V3-D.17 FASE C-back
-- Adds canonical `engine.toggle` permission, grants it to the founder
-- system role, and exposes `set_group_engine_active(p_group_id, p_active)`
-- as the only path for clients to flip the kill switch on
-- `groups.engine_active`. Mirrors the existing toggle-style pattern used
-- by other admin RPCs: assert_permission gate + idempotent write +
-- group_events log line.

-- 1. Permission catalog
INSERT INTO public.permissions (key, category, description)
VALUES ('engine.toggle', 'engine', 'Activar o desactivar el motor de reglas del grupo')
ON CONFLICT (key) DO UPDATE SET
  category    = EXCLUDED.category,
  description = EXCLUDED.description;

-- 2. Grant to every founder system role (one row per group)
INSERT INTO public.group_role_permissions (role_id, permission_key)
SELECT r.id, 'engine.toggle'
FROM public.group_roles r
WHERE r.is_system = true AND r.key = 'founder'
ON CONFLICT DO NOTHING;

-- 3. set_group_engine_active(p_group_id, p_active)
--    SECURITY DEFINER · gated by assert_permission(p_group_id,'engine.toggle')
--    Idempotent: returns the resulting row even if no change.
--    Logs to group_events with summary + previous/new state in payload.
CREATE OR REPLACE FUNCTION public.set_group_engine_active(
  p_group_id uuid,
  p_active   boolean
)
RETURNS TABLE (
  group_id      uuid,
  engine_active boolean,
  changed       boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_prev      boolean;
  v_changed   boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  IF p_group_id IS NULL OR p_active IS NULL THEN
    RAISE EXCEPTION 'p_group_id and p_active are required' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(p_group_id, 'engine.toggle');

  SELECT g.engine_active INTO v_prev
  FROM public.groups g
  WHERE g.id = p_group_id
  FOR UPDATE;

  IF v_prev IS NULL THEN
    RAISE EXCEPTION 'group % not found', p_group_id USING errcode = 'P0002';
  END IF;

  v_changed := v_prev IS DISTINCT FROM p_active;

  IF v_changed THEN
    UPDATE public.groups
       SET engine_active = p_active
     WHERE id = p_group_id;

    INSERT INTO public.group_events (
      group_id, actor_user_id, event_type, entity_kind, entity_id,
      summary, payload, occurred_at
    )
    VALUES (
      p_group_id,
      v_uid,
      'group.engine_toggled',
      'group',
      p_group_id,
      CASE WHEN p_active
           THEN 'Motor de reglas activado'
           ELSE 'Motor de reglas desactivado'
      END,
      jsonb_build_object(
        'previous_engine_active', v_prev,
        'new_engine_active',      p_active
      ),
      now()
    );
  END IF;

  RETURN QUERY
  SELECT p_group_id, p_active, v_changed;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_group_engine_active(uuid, boolean) TO authenticated;

COMMENT ON FUNCTION public.set_group_engine_active(uuid, boolean) IS
  'V3-D.17 — kill switch RPC for the rule engine. Gated by engine.toggle. Idempotent. Logs group.engine_toggled to group_events.';
