-- V3 PARTE 3.1 — assign_role_to_member emits role.granted to group_events
--
-- Estado previo: el RPC inserta a group_member_roles + a
-- group_membership_events (atom privado per-membership) con
-- event_type='role_assigned'. NO emite a group_events (feed público).
--
-- Spec §0.6 marca `role.granted/revoked per-member` como faltante en el
-- catálogo público. Slice aditivo: agregamos la emisión a group_events
-- sin tocar group_membership_events. La firma + permission + behavior
-- queda intacta.

CREATE OR REPLACE FUNCTION public.assign_role_to_member(
  p_membership_id uuid,
  p_role_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_group uuid;
BEGIN
  SELECT group_id INTO v_group FROM public.group_memberships WHERE id = p_membership_id;
  IF v_group IS NULL THEN RAISE EXCEPTION 'membership not found'; END IF;
  PERFORM public.assert_permission(v_group, 'roles.manage');

  INSERT INTO public.group_member_roles (membership_id, role_id, assigned_by)
  VALUES (p_membership_id, p_role_id, auth.uid())
  ON CONFLICT DO NOTHING;

  INSERT INTO public.group_membership_events (group_id, membership_id, actor_user_id, event_type, payload)
  VALUES (v_group, p_membership_id, auth.uid(), 'role_assigned',
          jsonb_build_object('role_id', p_role_id));

  PERFORM public.record_system_event(
    p_group_id    => v_group,
    p_event_type  => 'role.granted',
    p_entity_kind => 'membership',
    p_entity_id   => p_membership_id,
    p_payload     => jsonb_build_object(
      'role_id',       p_role_id,
      'membership_id', p_membership_id
    )
  );
END;
$function$;
