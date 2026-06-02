-- V3-D.20 FASE C-back 1/3
-- Extiende el modelo de Membership con 2 estados nuevos:
--   paused   = pausa voluntaria/temporal no punitiva
--   removed  = salida administrativa reversible (banned hoy es "fuerte")
-- Mantiene los 6 estados actuales (requested|invited|active|suspended|left|banned).
-- set_membership_state se reescribe para soportar los 8 estados con gates
-- diferenciados. Auto-revoke de mandates se extiende a paused + removed.
-- banned→active queda explícitamente bloqueado sin "membership.unban"
-- (que se introduce abajo) — doctrina: reactivar a un baneado requiere
-- decisión y se hace via execute_decision membership branch.

-- 1. CHECK status — amplía catálogo
ALTER TABLE public.group_memberships
  DROP CONSTRAINT IF EXISTS group_memberships_status_check;
ALTER TABLE public.group_memberships
  ADD  CONSTRAINT group_memberships_status_check CHECK (
    status = ANY (ARRAY[
      'requested','invited','active','paused','suspended','removed','left','banned'
    ])
  );

-- 2. Nueva columna paused_until (opcional, espejo de suspended_until)
ALTER TABLE public.group_memberships
  ADD COLUMN IF NOT EXISTS paused_until    timestamptz,
  ADD COLUMN IF NOT EXISTS paused_reason   text,
  ADD COLUMN IF NOT EXISTS removed_at      timestamptz,
  ADD COLUMN IF NOT EXISTS removed_reason  text,
  ADD COLUMN IF NOT EXISTS unbanned_at     timestamptz,
  ADD COLUMN IF NOT EXISTS unban_decision_id uuid REFERENCES public.group_decisions(id);

-- 3. Permission nuevo: members.pause (separado de suspend que es punitivo)
INSERT INTO public.permissions (key, category, description)
VALUES ('members.pause', 'members', 'Pausar membresías voluntariamente')
ON CONFLICT (key) DO UPDATE SET
  category    = EXCLUDED.category,
  description = EXCLUDED.description;

INSERT INTO public.group_role_permissions (role_id, permission_key)
SELECT r.id, 'members.pause'
FROM public.group_roles r
WHERE r.is_system = true AND r.key = 'founder'
ON CONFLICT DO NOTHING;

-- 4. set_membership_state — reescritura con 8 estados.
--    Gates por target:
--      requested   members.invite
--      invited     members.invite
--      active      members.update (excepto si OLD=banned: bloqueado, requiere execute_decision)
--      paused      self O members.pause
--      suspended   members.suspend
--      removed     members.remove
--      left        self O members.remove
--      banned      members.remove
--
--    Auto-revoke mandates: paused, suspended, removed, left, banned.

CREATE OR REPLACE FUNCTION public.set_membership_state(
  p_membership_id uuid,
  p_new_state     text,
  p_reason        text DEFAULT NULL,
  p_until         timestamptz DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_m         public.group_memberships%ROWTYPE;
  v_is_self   boolean;
  v_event_uuid uuid;
  v_event_type text;
BEGIN
  SELECT * INTO v_m FROM public.group_memberships WHERE id = p_membership_id FOR UPDATE;
  IF v_m.id IS NULL THEN
    RAISE EXCEPTION 'membership not found' USING errcode = 'P0002';
  END IF;
  v_is_self := (v_m.user_id = auth.uid());

  IF p_new_state NOT IN (
    'requested','invited','active','paused','suspended','removed','left','banned'
  ) THEN
    RAISE EXCEPTION 'invalid membership state %', p_new_state USING errcode = '22023';
  END IF;

  -- D.20: banned → active bloqueado salvo via execute_decision (que setea
  -- unban_decision_id antes de llamar). Marker: si la transición viene de
  -- execute_decision, la fila ya fue cargada con `unban_decision_id IS NOT NULL`.
  IF v_m.status = 'banned' AND p_new_state = 'active' THEN
    IF v_m.unban_decision_id IS NULL THEN
      RAISE EXCEPTION 'banned → active requires a decision (see execute_decision membership branch)'
        USING errcode = '42501';
    END IF;
  END IF;

  -- Gates por target state.
  IF p_new_state = 'left' THEN
    IF NOT (v_is_self OR public.has_group_permission(v_m.group_id, 'members.remove')) THEN
      RAISE EXCEPTION 'caller cannot move membership to left';
    END IF;
  ELSIF p_new_state = 'paused' THEN
    IF NOT (v_is_self OR public.has_group_permission(v_m.group_id, 'members.pause')) THEN
      RAISE EXCEPTION 'caller cannot pause this membership';
    END IF;
  ELSIF p_new_state = 'suspended' THEN
    PERFORM public.assert_permission(v_m.group_id, 'members.suspend');
  ELSIF p_new_state = 'removed' THEN
    PERFORM public.assert_permission(v_m.group_id, 'members.remove');
  ELSIF p_new_state = 'banned' THEN
    PERFORM public.assert_permission(v_m.group_id, 'members.remove');
  ELSE
    PERFORM public.assert_permission(v_m.group_id, 'members.update');
  END IF;

  UPDATE public.group_memberships
     SET status            = p_new_state,
         suspended_until   = CASE WHEN p_new_state='suspended' THEN p_until ELSE NULL END,
         suspended_reason  = CASE WHEN p_new_state='suspended' THEN p_reason ELSE NULL END,
         paused_until      = CASE WHEN p_new_state='paused'    THEN p_until ELSE NULL END,
         paused_reason     = CASE WHEN p_new_state='paused'    THEN p_reason ELSE NULL END,
         removed_at        = CASE WHEN p_new_state='removed'   THEN now() ELSE NULL END,
         removed_reason    = CASE WHEN p_new_state='removed'   THEN p_reason ELSE NULL END,
         left_at           = CASE WHEN p_new_state IN ('left','banned') THEN now() ELSE left_at END,
         left_reason       = CASE WHEN p_new_state IN ('left','banned') THEN p_reason ELSE left_reason END,
         unbanned_at       = CASE WHEN v_m.status='banned' AND p_new_state='active' THEN now() ELSE unbanned_at END
   WHERE id = p_membership_id;

  -- Map target state → canonical group_membership_events.event_type
  v_event_type := CASE p_new_state
    WHEN 'suspended' THEN 'suspended'
    WHEN 'active'    THEN 'reactivated'
    WHEN 'paused'    THEN 'paused'
    WHEN 'removed'   THEN 'removed'
    WHEN 'left'      THEN 'left'
    WHEN 'banned'    THEN 'banned'
    ELSE 'other'
  END;

  INSERT INTO public.group_membership_events (
    group_id, membership_id, actor_user_id, event_type, reason
  ) VALUES (
    v_m.group_id, p_membership_id, auth.uid(), v_event_type, p_reason
  );

  -- Auto-revoke mandates donde el miembro es representante para estados
  -- que lo incapacitan de actuar.
  IF p_new_state IN ('paused','suspended','removed','left','banned') THEN
    UPDATE public.group_mandates
       SET status = 'revoked',
           revoked_at = now(),
           revoked_reason = 'member_state_change'
     WHERE representative_membership_id = p_membership_id
       AND status = 'active';
  END IF;

  -- Canonical system event + engine bridge
  SELECT rse.uuid_id INTO v_event_uuid FROM public.record_system_event(
    v_m.group_id, 'member.state_changed', 'membership', p_membership_id,
    'Cambio de estado de membresía',
    jsonb_build_object('to', p_new_state, 'from', v_m.status, 'reason', p_reason)
  ) rse;
  PERFORM public.evaluate_rules_for_event(v_event_uuid, 'sync');
END;
$function$;

COMMENT ON FUNCTION public.set_membership_state(uuid, text, text, timestamptz) IS
  'V3-D.20 — 8 estados (+ paused, removed). banned→active requiere unban_decision_id (set by execute_decision).';
