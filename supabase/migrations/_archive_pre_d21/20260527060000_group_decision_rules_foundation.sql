-- 20260527060000 — group_decision_rules Foundation (Primitivas 6/16/22).
--
-- Primitiva 6 (Poder/Autoridad), 16 (Decisiones), 22 (Legitimidad)
-- comparten una primera superficie común: ¿cómo decide este grupo?
-- El schema canónico ya carga la respuesta en `groups.decision_rules`
-- jsonb (reemplazo de `governance`). Esta migración agrega los dos
-- RPCs Foundation que iOS necesita para leer y editar esa pieza.
--
-- Shape canónico de groups.decision_rules:
--   {
--     "default_style": "majority",     -- admin_only | majority |
--                                      -- supermajority | unanimity |
--                                      -- consensus
--     "quorum_min": 2,                  -- int >= 1, o null
--     "notes": "..."                    -- texto libre opcional
--   }
--
-- Cuando la columna está vacía ('{}'), el read RPC devuelve los
-- defaults explícitos para que iOS no tenga que normalizar.

-- ===========================================================================
-- 1. RPC: group_decision_rules
-- ===========================================================================
-- Lectura simple. Devuelve la jsonb completa (con defaults aplicados)
-- + un campo `is_default` para que la UI pueda distinguir "el grupo
-- nunca ajustó esto" vs "esto es lo que el grupo eligió".
--
-- Auth: active member (mismo gate que el resto del Foundation set).

CREATE OR REPLACE FUNCTION public.group_decision_rules(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_raw    jsonb;
  v_style  text;
  v_quorum int;
  v_notes  text;
  v_empty  boolean;
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

  SELECT COALESCE(g.decision_rules, '{}'::jsonb)
    INTO v_raw
    FROM public.groups g
   WHERE g.id = p_group_id;

  IF v_raw IS NULL THEN
    RAISE EXCEPTION 'group not found: %', p_group_id USING errcode = 'P0002';
  END IF;

  v_empty  := (v_raw = '{}'::jsonb);
  v_style  := COALESCE(NULLIF(v_raw->>'default_style', ''), 'majority');
  v_notes  := NULLIF(v_raw->>'notes', '');

  BEGIN
    v_quorum := NULLIF(v_raw->>'quorum_min', '')::int;
  EXCEPTION WHEN others THEN
    v_quorum := NULL;
  END;

  RETURN jsonb_build_object(
    'group_id',      p_group_id,
    'default_style', v_style,
    'quorum_min',    v_quorum,
    'notes',         v_notes,
    'is_default',    v_empty
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_decision_rules(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_decision_rules(uuid) TO authenticated;

COMMENT ON FUNCTION public.group_decision_rules(uuid) IS
  'Primitivas 6/16/22 Foundation (mig 20260527060000): returns the active decision rules for a group (default_style/quorum_min/notes). Defaults are baked in when the jsonb is empty. Active-member gate. Raises ''must be authenticated'' | ''caller is not an active member of group <uuid>'' | ''group not found: <uuid>''.';

-- ===========================================================================
-- 2. RPC: set_decision_rules
-- ===========================================================================
-- Upsert in-place on groups.decision_rules. Validates the shape and
-- writes the canonical jsonb. Gated by the existing `group.update`
-- permission (semantically: editing the decision rules is editing
-- the group's config — no new permission key needed).
--
-- Returns the same jsonb shape as the read RPC so iOS can render
-- without a follow-up call.

CREATE OR REPLACE FUNCTION public.set_decision_rules(
  p_group_id      uuid,
  p_default_style text,
  p_quorum_min    int  DEFAULT NULL,
  p_notes         text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_style  text;
  v_notes  text;
  v_rules  jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  v_style := COALESCE(NULLIF(btrim(p_default_style), ''), '');
  IF v_style NOT IN ('admin_only', 'majority', 'supermajority', 'unanimity', 'consensus') THEN
    RAISE EXCEPTION 'invalid decision style' USING errcode = '22023';
  END IF;

  IF p_quorum_min IS NOT NULL AND p_quorum_min < 1 THEN
    RAISE EXCEPTION 'quorum_min must be >= 1' USING errcode = '22023';
  END IF;

  v_notes := NULLIF(btrim(COALESCE(p_notes, '')), '');

  -- Permission + active-membership gate.
  PERFORM public.assert_permission(p_group_id, 'group.update');

  -- Compose the canonical jsonb. Use jsonb_strip_nulls so absent
  -- fields don't pollute the stored object.
  v_rules := jsonb_strip_nulls(jsonb_build_object(
    'default_style', v_style,
    'quorum_min',    p_quorum_min,
    'notes',         v_notes
  ));

  UPDATE public.groups
     SET decision_rules = v_rules,
         updated_at     = now()
   WHERE id = p_group_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'group not found: %', p_group_id USING errcode = 'P0002';
  END IF;

  -- Best-effort audit (same pattern as set_group_purpose).
  PERFORM public.record_system_event(
    p_group_id, 'decision_rules.set', 'group', p_group_id,
    'Reglas de decisión actualizadas',
    jsonb_build_object(
      'default_style', v_style,
      'quorum_min',    p_quorum_min,
      'has_notes',     v_notes IS NOT NULL
    )
  );

  -- Mirror the read shape so the caller doesn't need a follow-up.
  RETURN jsonb_build_object(
    'group_id',      p_group_id,
    'default_style', v_style,
    'quorum_min',    p_quorum_min,
    'notes',         v_notes,
    'is_default',    false
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_decision_rules(uuid, text, int, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.set_decision_rules(uuid, text, int, text) TO authenticated;

COMMENT ON FUNCTION public.set_decision_rules(uuid, text, int, text) IS
  'Primitivas 6/16/22 Foundation (mig 20260527060000): upsert groups.decision_rules in-place. Validates style (admin_only/majority/supermajority/unanimity/consensus) and quorum_min (>=1 or null). Requires permission ''group.update''. Returns the same shape as group_decision_rules(). Raises ''must be authenticated'' | ''invalid decision style'' | ''quorum_min must be >= 1'' | ''group not found: <uuid>'' | ''caller lacks permission group.update in group <uuid>''.';
