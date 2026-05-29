-- V3 PARTE 3.2 — revoke_role_from_member emits role.revoked to group_events
--
-- Slice aditivo idéntico al 3.1: la RPC sigue insertando a
-- group_membership_events; agregamos emission al feed público.

CREATE OR REPLACE FUNCTION public.revoke_role_from_member(
  p_membership_id uuid,
  p_role_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_group uuid;
  v_remaining int;
BEGIN
  SELECT group_id INTO v_group FROM public.group_memberships WHERE id = p_membership_id;
  IF v_group IS NULL THEN RAISE EXCEPTION 'membership not found'; END IF;
  PERFORM public.assert_permission(v_group, 'roles.manage');

  SELECT count(*) INTO v_remaining FROM public.group_member_roles
   WHERE membership_id = p_membership_id AND role_id <> p_role_id;
  IF v_remaining = 0 THEN
    RAISE EXCEPTION 'cannot revoke last role from member';
  END IF;

  DELETE FROM public.group_member_roles
   WHERE membership_id = p_membership_id AND role_id = p_role_id;

  INSERT INTO public.group_membership_events (group_id, membership_id, actor_user_id, event_type, payload)
  VALUES (v_group, p_membership_id, auth.uid(), 'role_revoked',
          jsonb_build_object('role_id', p_role_id));

  PERFORM public.record_system_event(
    p_group_id    => v_group,
    p_event_type  => 'role.revoked',
    p_entity_kind => 'membership',
    p_entity_id   => p_membership_id,
    p_payload     => jsonb_build_object(
      'role_id',       p_role_id,
      'membership_id', p_membership_id
    )
  );
END;
$function$;
