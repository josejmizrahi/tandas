-- D.24.4 — `approve_membership_request` now also writes a
-- notifications_outbox row for the requester, so the new member sees
-- "Tu solicitud fue aprobada" in Inbox + push when they next open the
-- app. Mirrors the canonical Inbox payload shape.
-- NOTE: superseded by 20260601022038_d24_4_approve_membership_request_fix_variable_conflict
-- which restores the `#variable_conflict use_column` directive that
-- was lost in this rewrite.

CREATE OR REPLACE FUNCTION public.approve_membership_request(p_membership_id uuid)
 RETURNS TABLE(membership_id uuid, group_id uuid, status text, changed boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid           uuid := auth.uid();
  v_m             public.group_memberships%ROWTYPE;
  v_default_role  uuid;
  v_has_role      int;
  v_changed       boolean;
  v_group_name    text;
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

  IF v_m.user_id IS NOT NULL THEN
    SELECT name INTO v_group_name FROM public.groups WHERE id = v_m.group_id;
    INSERT INTO public.notifications_outbox
      (recipient_user_id, group_id, category, payload, dispatch_status, dispatched_at)
    VALUES (
      v_m.user_id,
      v_m.group_id,
      'member.joined',
      jsonb_build_object(
        'title',         'Tu solicitud fue aprobada',
        'group_name',    COALESCE(v_group_name, 'Grupo'),
        'message',       'Ya formás parte. Abrí la app y mirá qué hay para vos.',
        'membership_id', p_membership_id
      ),
      'dispatched',
      now()
    );
  END IF;

  membership_id := v_m.id; group_id := v_m.group_id;
  status := 'active'; changed := v_changed;
  RETURN NEXT;
END;
$function$;
