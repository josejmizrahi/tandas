-- V3 PARTE 3.3 — append_dispute_event emits dispute.event_added to group_events
--
-- Estado previo: RPC inserta a group_dispute_events (atom privado de
-- la disputa) pero no emite a group_events (feed público). Esto rompía
-- la doctrina memory: los participantes de un dispute ven los eventos
-- en su detalle pero el resto del grupo no ve actividad en el feed
-- general.
--
-- Slice aditivo: emit dispute.event_added con dispute_id + event_type
-- intra-dispute + body_summary (primeras 80 chars).

CREATE OR REPLACE FUNCTION public.append_dispute_event(
  p_dispute_id uuid,
  p_event_type text,
  p_body text,
  p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_d public.group_disputes%ROWTYPE;
  v_actor uuid;
  v_id uuid;
BEGIN
  SELECT * INTO v_d FROM public.group_disputes WHERE id = p_dispute_id;
  IF v_d.id IS NULL THEN RAISE EXCEPTION 'dispute not found'; END IF;
  v_actor := (
    SELECT id FROM public.group_memberships
     WHERE group_id = v_d.group_id AND user_id = auth.uid() AND status = 'active'
  );
  IF v_actor IS NULL THEN RAISE EXCEPTION 'caller is not a member'; END IF;

  IF v_actor NOT IN (v_d.opened_by_membership_id, v_d.respondent_membership_id, v_d.mediator_membership_id)
     AND NOT public.has_group_permission(v_d.group_id, 'disputes.mediate') THEN
    RAISE EXCEPTION 'caller cannot append to this dispute';
  END IF;

  INSERT INTO public.group_dispute_events (dispute_id, actor_membership_id, event_type, body, metadata)
  VALUES (p_dispute_id, v_actor, p_event_type, p_body, COALESCE(p_metadata, '{}'::jsonb))
  RETURNING id INTO v_id;

  PERFORM public.record_system_event(
    p_group_id    => v_d.group_id,
    p_event_type  => 'dispute.event_added',
    p_entity_kind => 'dispute',
    p_entity_id   => p_dispute_id,
    p_payload     => jsonb_build_object(
      'dispute_id',         p_dispute_id,
      'dispute_event_id',   v_id,
      'inner_event_type',   p_event_type,
      'actor_membership_id', v_actor
    )
  );

  RETURN v_id;
END;
$function$;
