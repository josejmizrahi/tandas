-- 20260529204315 — V3-R0: invite_member creates placeholder membership.
--
-- Cierra el caso "registré un gasto pagado por alguien que aún no
-- aceptó la invitación". Hoy invite_member solo escribía a
-- group_invites; el invitado no tenía membership_id, así que no podía
-- ser pagador ni participante de un split, y sus obligations no se
-- materializaban.
--
-- Schema ya estaba listo (founder anterior pre-pavimentó):
--   - group_memberships.status permite 'invited'.
--   - group_invites.placeholder_membership_id column existe.
--   - accept_invite YA tiene el branch de reconciliación:
--       ELSIF v_invite.placeholder_membership_id IS NOT NULL THEN
--         UPDATE membership SET user_id=auth.uid(), status='active'
-- Solo faltaba que invite_member creara la placeholder y la enlazara.
--
-- Diseño:
--   1. INSERT placeholder membership con user_id=v_user_id (resuelto
--      por phone si ya existe profile; NULL si no), status='invited',
--      joined_via='placeholder_claim', membership_type por p_membership_type.
--   2. INSERT group_invites con placeholder_membership_id = la nueva row.
--   3. Resto del flow (system_event + notification) intacto.
--
-- Reconciliación al accept: se le pone user_id real y status='active'.
-- Las obligations que ya se crearon contra la placeholder se mantienen
-- intactas — apuntan al mismo membership_id, se reconcilian sin migrar
-- nada.

CREATE OR REPLACE FUNCTION public.invite_member(
  p_group_id          uuid,
  p_email             text DEFAULT NULL,
  p_phone             text DEFAULT NULL,
  p_membership_type   text DEFAULT 'member',
  p_message           text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $function$
DECLARE
  v_invite_id          uuid;
  v_code               text;
  v_token_hash         text;
  v_user_id            uuid;
  v_placeholder_id     uuid;
  v_membership_type    text;
BEGIN
  PERFORM public.assert_permission(p_group_id, 'members.invite');
  IF p_email IS NULL AND p_phone IS NULL THEN
    RAISE EXCEPTION 'invite requires email or phone';
  END IF;

  v_membership_type := COALESCE(NULLIF(btrim(p_membership_type), ''), 'member');
  IF v_membership_type NOT IN ('member','provisional','guest','observer','external') THEN
    RAISE EXCEPTION 'invalid membership_type %', v_membership_type;
  END IF;

  v_code       := upper(substring(encode(extensions.gen_random_bytes(8), 'hex') for 8));
  v_token_hash := encode(extensions.digest(v_code || p_group_id::text, 'sha256'), 'hex');

  -- Resolve user_id by phone match (best-effort; null if no profile yet).
  SELECT p.id INTO v_user_id FROM public.profiles p
   WHERE (p_phone IS NOT NULL AND lower(coalesce(p.phone, '')) = lower(p_phone))
   LIMIT 1;

  -- 1. Create the placeholder membership FIRST so we can link the invite to it.
  -- status='invited' keeps it out of "active member" queries; joined_via
  -- 'placeholder_claim' marks the lifecycle for the reconciliation path in
  -- accept_invite.
  INSERT INTO public.group_memberships (
    group_id, user_id, status, joined_via, membership_type
  ) VALUES (
    p_group_id, v_user_id, 'invited', 'placeholder_claim', v_membership_type
  )
  RETURNING id INTO v_placeholder_id;

  -- 2. Create the invite linked to the placeholder.
  INSERT INTO public.group_invites (
    group_id, email, phone, invited_user_id, invited_by,
    status, token_hash, code, expires_at, metadata,
    placeholder_membership_id
  ) VALUES (
    p_group_id, p_email, p_phone, v_user_id, auth.uid(),
    'pending', v_token_hash, v_code, now() + interval '14 days',
    jsonb_build_object('message', p_message, 'membership_type', v_membership_type),
    v_placeholder_id
  )
  RETURNING id INTO v_invite_id;

  -- 3. Record system event + enqueue notification (intacto vs versión previa).
  PERFORM public.record_system_event(
    p_group_id, 'member.invited', 'invite', v_invite_id, 'Invitación creada',
    jsonb_build_object(
      'email', p_email,
      'phone', p_phone,
      'placeholder_membership_id', v_placeholder_id,
      'authority_path', 'direct_permission'
    )
  );

  INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
  SELECT p_group_id, v_user_id, 'member.invited',
         jsonb_build_object('invite_id', v_invite_id, 'group_id', p_group_id, 'code', v_code)
  WHERE v_user_id IS NOT NULL;

  RETURN v_invite_id;
END;
$function$;

COMMENT ON FUNCTION public.invite_member(uuid, text, text, text, text) IS
  'V3-R0 (mig 20260529204315): invite_member now creates a placeholder group_memberships row (status=invited, joined_via=placeholder_claim, membership_type=p_membership_type) and links it via group_invites.placeholder_membership_id. The invitee gets a real membership_id immediately so they can be a payer/participant in splits before they accept. accept_invite reconciles by setting user_id + status=active on the existing row.';
