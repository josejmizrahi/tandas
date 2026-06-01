-- D.24.4 — `request_membership` now also writes notifications_outbox rows
-- so admins (members with `members.invite`) get push + Inbox surfacing
-- the new join request instead of having to open the app proactively.
-- Mirror the canonical Inbox payload shape used elsewhere
-- (`title`, `group_name`, `message`).

CREATE OR REPLACE FUNCTION public.request_membership(p_group_id uuid, p_message text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_membership   uuid;
  v_visibility   text;
  v_group_name   text;
  v_requester    uuid := auth.uid();
  v_requester_dn text;
BEGIN
  IF v_requester IS NULL THEN
    RAISE EXCEPTION 'must be authenticated';
  END IF;

  SELECT visibility, name INTO v_visibility, v_group_name
    FROM public.groups WHERE id = p_group_id;
  IF v_visibility NOT IN ('public','unlisted') THEN
    RAISE EXCEPTION 'group is not open to membership requests';
  END IF;

  SELECT COALESCE(NULLIF(btrim(display_name), ''), username, 'Alguien')
    INTO v_requester_dn
    FROM public.profiles WHERE id = v_requester;

  INSERT INTO public.group_memberships (group_id, user_id, status, joined_via, metadata)
  VALUES (p_group_id, v_requester, 'requested', 'admin_add', jsonb_build_object('message', p_message))
  ON CONFLICT (group_id, user_id) DO UPDATE SET status = 'requested'
  RETURNING id INTO v_membership;

  INSERT INTO public.group_membership_events (group_id, membership_id, actor_user_id, event_type, reason)
  VALUES (p_group_id, v_membership, v_requester, 'requested', p_message);

  PERFORM public.record_system_event(
    p_group_id, 'member.requested', 'membership', v_membership,
    'Solicitud de pertenencia', jsonb_build_object('message', p_message)
  );

  -- D.24.4: notify every admin (members.invite holder) that there's a
  -- new request to review. SELECT DISTINCT user_id so a user with
  -- multiple roles only gets one notification. Excludes the requester
  -- in the unlikely case they happen to also hold members.invite via a
  -- prior membership.
  INSERT INTO public.notifications_outbox
    (recipient_user_id, group_id, category, payload, dispatch_status, dispatched_at)
  SELECT DISTINCT
    gm.user_id,
    p_group_id,
    'member.requested',
    jsonb_build_object(
      'title',             'Nueva solicitud de pertenencia',
      'group_name',        COALESCE(v_group_name, 'Grupo'),
      'message',           v_requester_dn || ' quiere entrar' ||
                           COALESCE(': ' || p_message, ''),
      'membership_id',     v_membership,
      'requester_user_id', v_requester
    ),
    'dispatched',
    now()
  FROM public.group_memberships gm
  JOIN public.group_member_roles gmr     ON gmr.membership_id = gm.id
  JOIN public.group_role_permissions grp ON grp.role_id       = gmr.role_id
  WHERE gm.group_id    = p_group_id
    AND gm.status      = 'active'
    AND grp.permission_key = 'members.invite'
    AND gm.user_id <> v_requester;

  RETURN v_membership;
END;
$function$;
