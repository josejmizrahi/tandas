-- 20260527190000 — Boundary policy (Primitiva 2, B2).
--
-- Primitiva 2 (Membership boundary) ya tenía el surface de lectura
-- (group_membership_boundary que UNION-ea memberships + pending
-- invites). Lo que faltaba era la *política* que rige la frontera:
-- cómo entra alguien al grupo, quién puede invitar, si requiere
-- aprobación, cómo se sale.
--
-- Persistido bajo groups.settings.boundary_policy (jsonb) para no
-- inflar el schema con 4 columnas escalares. Mismo patrón que
-- group_decision_rules → groups.decision_rules.

-- ===========================================================================
-- 1. READ: group_boundary_policy(p_group_id) → jsonb
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.group_boundary_policy(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_policy  jsonb;
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

  SELECT coalesce(g.settings->'boundary_policy', '{}'::jsonb)
    INTO v_policy
    FROM public.groups g
   WHERE g.id = p_group_id;

  IF v_policy IS NULL OR v_policy = '{}'::jsonb THEN
    RETURN jsonb_build_object(
      'group_id',           p_group_id,
      'entry_mode',         'invite_only',
      'who_can_invite',     'any_member',
      'requires_approval',  false,
      'exit_mode',          'free',
      'notes',              null,
      'is_default',         true
    );
  END IF;

  RETURN jsonb_build_object(
    'group_id',           p_group_id,
    'entry_mode',         coalesce(v_policy->>'entry_mode',        'invite_only'),
    'who_can_invite',     coalesce(v_policy->>'who_can_invite',    'any_member'),
    'requires_approval',  coalesce((v_policy->>'requires_approval')::boolean, false),
    'exit_mode',          coalesce(v_policy->>'exit_mode',         'free'),
    'notes',              v_policy->>'notes',
    'is_default',         false
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_boundary_policy(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_boundary_policy(uuid) TO authenticated;
COMMENT ON FUNCTION public.group_boundary_policy(uuid) IS
  'Primitiva 2 (mig 20260527190000): returns the active boundary policy (entry/inviter/approval/exit). Defaults baked in when groups.settings.boundary_policy is empty. Active-member gate.';

-- ===========================================================================
-- 2. WRITE: set_group_boundary_policy(...) → jsonb (re-read)
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.set_group_boundary_policy(
  p_group_id          uuid,
  p_entry_mode        text,
  p_who_can_invite    text,
  p_requires_approval boolean,
  p_exit_mode         text,
  p_notes             text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_clean  jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  PERFORM public.assert_permission(p_group_id, 'group.update');

  IF p_entry_mode NOT IN ('open','invite_only','closed') THEN
    RAISE EXCEPTION 'invalid entry_mode: %', p_entry_mode USING errcode = '22023';
  END IF;
  IF p_who_can_invite NOT IN ('any_member','admins_only') THEN
    RAISE EXCEPTION 'invalid who_can_invite: %', p_who_can_invite USING errcode = '22023';
  END IF;
  IF p_exit_mode NOT IN ('free','requires_notice') THEN
    RAISE EXCEPTION 'invalid exit_mode: %', p_exit_mode USING errcode = '22023';
  END IF;

  v_clean := jsonb_build_object(
    'entry_mode',        p_entry_mode,
    'who_can_invite',    p_who_can_invite,
    'requires_approval', p_requires_approval,
    'exit_mode',         p_exit_mode,
    'notes',             nullif(btrim(coalesce(p_notes, '')), '')
  );

  UPDATE public.groups
     SET settings   = coalesce(settings, '{}'::jsonb) || jsonb_build_object('boundary_policy', v_clean),
         updated_at = now()
   WHERE id = p_group_id;

  PERFORM public.record_system_event(
    p_group_id, 'boundary_policy.updated', 'group', p_group_id,
    'Política de entrada actualizada', v_clean
  );

  RETURN public.group_boundary_policy(p_group_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_group_boundary_policy(uuid, text, text, boolean, text, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.set_group_boundary_policy(uuid, text, text, boolean, text, text) TO authenticated;
COMMENT ON FUNCTION public.set_group_boundary_policy(uuid, text, text, boolean, text, text) IS
  'Primitiva 2 (mig 20260527190000): upsert in-place on groups.settings.boundary_policy. Validates enums. Requires group.update.';
