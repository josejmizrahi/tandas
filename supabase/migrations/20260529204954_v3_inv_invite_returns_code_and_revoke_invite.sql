-- 20260529204954: V3-INV — invite_member returns shareable code +
-- new revoke_invite RPC for admin-initiated cancellation of a pending invite.
--
-- Why:
--   1. iOS quiere mostrar el código justo después de crear la invitación
--      para que el inviter pueda compartirlo (ShareLink, copiar, etc.).
--      Antes la RPC sólo devolvía el invite_id y el código se mandaba
--      out-of-band por SMS/email.
--   2. Para revocar invitaciones (founder UX): swipe-to-delete en la
--      vista de miembros sobre las filas "Invitado · esperando".
--   3. Cuando revocas, el placeholder membership creado en V3-R0 puede
--      tener obligations open (gastos donde el invitado participó).
--      Bloqueamos la revocación si hay saldo abierto — el admin debe
--      saldarlo primero o aceptar la invitación.
--
-- Breaking change controlado: invite_member ahora RETURNS TABLE en vez
-- de UUID. iOS se actualiza en el mismo slice.

DROP FUNCTION IF EXISTS public.invite_member(uuid, text, text, text, text);

CREATE OR REPLACE FUNCTION public.invite_member(
  p_group_id          uuid,
  p_email             text DEFAULT NULL,
  p_phone             text DEFAULT NULL,
  p_membership_type   text DEFAULT 'member',
  p_message           text DEFAULT NULL
)
RETURNS TABLE (
  invite_id                 uuid,
  code                      text,
  placeholder_membership_id uuid
)
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

  SELECT p.id INTO v_user_id FROM public.profiles p
   WHERE (p_phone IS NOT NULL AND lower(coalesce(p.phone, '')) = lower(p_phone))
   LIMIT 1;

  INSERT INTO public.group_memberships (
    group_id, user_id, status, joined_via, membership_type
  ) VALUES (
    p_group_id, v_user_id, 'invited', 'placeholder_claim', v_membership_type
  )
  RETURNING id INTO v_placeholder_id;

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

  invite_id                 := v_invite_id;
  code                      := v_code;
  placeholder_membership_id := v_placeholder_id;
  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.invite_member(uuid, text, text, text, text) IS
  'V3-INV (mig 20260529204954): now returns TABLE(invite_id, code, placeholder_membership_id) so iOS can show the code for share/copy actions right after the invitation is created. Placeholder membership created with status=invited as in V3-R0.';

CREATE OR REPLACE FUNCTION public.revoke_invite(
  p_invite_id uuid,
  p_reason    text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $function$
DECLARE
  v_invite      public.group_invites%ROWTYPE;
  v_open_count  int;
  v_reason      text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_invite FROM public.group_invites WHERE id = p_invite_id;
  IF v_invite.id IS NULL THEN
    RAISE EXCEPTION 'invite not found' USING errcode = 'P0002';
  END IF;

  IF v_invite.invited_by IS DISTINCT FROM auth.uid() THEN
    PERFORM public.assert_permission(v_invite.group_id, 'members.invite');
  END IF;

  IF v_invite.status <> 'pending' THEN
    RAISE EXCEPTION 'invite is % and cannot be revoked', v_invite.status
      USING errcode = '22023';
  END IF;

  IF v_invite.placeholder_membership_id IS NOT NULL THEN
    SELECT COUNT(*)
      INTO v_open_count
      FROM public.group_obligations o
     WHERE o.group_id = v_invite.group_id
       AND (
         o.owed_by_membership_id = v_invite.placeholder_membership_id
         OR o.owed_to_membership_id = v_invite.placeholder_membership_id
       )
       AND o.status IN ('open','partially_settled');
    IF v_open_count > 0 THEN
      RAISE EXCEPTION 'invite has open obligations (%); settle them before revoking', v_open_count
        USING errcode = '22023';
    END IF;
  END IF;

  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');

  UPDATE public.group_invites
     SET status   = 'revoked',
         metadata = COALESCE(metadata, '{}'::jsonb)
                  || jsonb_build_object(
                       'revoked_at',     now(),
                       'revoked_by',     auth.uid(),
                       'revoked_reason', v_reason
                     )
   WHERE id = p_invite_id;

  IF v_invite.placeholder_membership_id IS NOT NULL THEN
    UPDATE public.group_memberships
       SET status      = 'left',
           left_at     = now(),
           left_reason = COALESCE(v_reason, 'invite_revoked')
     WHERE id = v_invite.placeholder_membership_id;
  END IF;

  PERFORM public.record_system_event(
    v_invite.group_id, 'member.invite_revoked', 'invite', p_invite_id,
    'Invitación revocada',
    jsonb_build_object(
      'reason',                    v_reason,
      'placeholder_membership_id', v_invite.placeholder_membership_id,
      'authority_path',            'direct_permission'
    )
  );

  RETURN p_invite_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.revoke_invite(uuid, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.revoke_invite(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.revoke_invite(uuid, text) IS
  'V3-INV (mig 20260529204954): cancel a pending invitation. Authorized to the inviter or anyone with members.invite. Blocks if the linked placeholder membership has open obligations (must be settled first). Soft-closes the placeholder (status=left) and marks the invite revoked. Emits member.invite_revoked event.';
