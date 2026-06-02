-- V3-D.20 FASE C.3
-- approve_membership_request(membership_id): cierra el flujo requested→active.
-- Gate: members.invite. Idempotente: si ya está active retorna sin error.
-- Asigna el default role del grupo si el membership no tiene roles.

CREATE OR REPLACE FUNCTION public.approve_membership_request(
  p_membership_id uuid
)
RETURNS TABLE (
  membership_id uuid,
  group_id      uuid,
  status        text,
  changed       boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid           uuid := auth.uid();
  v_m             public.group_memberships%ROWTYPE;
  v_default_role  uuid;
  v_has_role      int;
  v_changed       boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  IF p_membership_id IS NULL THEN
    RAISE EXCEPTION 'p_membership_id is required' USING errcode = '22023';
  END IF;

  SELECT * INTO v_m FROM public.group_memberships WHERE id = p_membership_id FOR UPDATE;
  IF v_m.id IS NULL THEN
    RAISE EXCEPTION 'membership % not found', p_membership_id USING errcode = 'P0002';
  END IF;

  PERFORM public.assert_permission(v_m.group_id, 'members.invite');

  IF v_m.status = 'active' THEN
    membership_id := v_m.id; group_id := v_m.group_id;
    status := 'active'; changed := false;
    RETURN NEXT; RETURN;
  END IF;

  IF v_m.status <> 'requested' THEN
    RAISE EXCEPTION 'cannot approve membership in state %', v_m.status
      USING errcode = '22023';
  END IF;

  UPDATE public.group_memberships
     SET status       = 'active',
         joined_at    = COALESCE(joined_at, now()),
         confirmed_at = now()
   WHERE id = p_membership_id;
  v_changed := true;

  -- Default role assignment (idempotente)
  SELECT count(*) INTO v_has_role
    FROM public.group_member_roles WHERE membership_id = p_membership_id;
  IF v_has_role = 0 THEN
    SELECT id INTO v_default_role
      FROM public.group_roles
     WHERE group_id = v_m.group_id AND is_default = true
     LIMIT 1;
    IF v_default_role IS NOT NULL THEN
      INSERT INTO public.group_member_roles (membership_id, role_id, assigned_by)
      VALUES (p_membership_id, v_default_role, v_uid)
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;

  -- Events
  INSERT INTO public.group_membership_events (
    group_id, membership_id, actor_user_id, event_type, reason
  ) VALUES (
    v_m.group_id, p_membership_id, v_uid, 'joined', 'request_approved'
  );

  PERFORM public.record_system_event(
    v_m.group_id, 'member.joined', 'membership', p_membership_id,
    'Solicitud de pertenencia aprobada',
    jsonb_build_object('source', 'request_approval', 'requester', v_m.user_id)
  );

  membership_id := v_m.id; group_id := v_m.group_id;
  status := 'active'; changed := v_changed;
  RETURN NEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_membership_request(uuid) TO authenticated;

COMMENT ON FUNCTION public.approve_membership_request(uuid) IS
  'V3-D.20 — cierra el ciclo request_membership → active. Idempotente. Gate members.invite.';
