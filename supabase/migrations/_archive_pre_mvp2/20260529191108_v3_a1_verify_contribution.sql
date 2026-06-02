-- 20260530000000 — V3-A1: verify_contribution RPC + auto-reputation chain.
--
-- Cierra dos primitivas a la vez:
--   - #9 Contribuciones (PARCIAL → COMPLETA): el path de verificación
--     deferred en 20260527140000 ahora aterriza.
--   - #C.11 listener `contribution.verified` → reputation_event:
--     antes la conexión estaba declarada pero sin emisor real.
--
-- Doctrina (PrimitivesArchitecture §C.9 + §C.11):
--   - "registrar ≠ aprobar". log_contribution lo registra cualquier
--     miembro; verify_contribution requiere permiso contribution.verify.
--   - Verifier NO puede ser el contributor (self-verify bloqueado).
--   - Transition único permitido: claimed → verified. Idempotent:
--     contribution ya verified retorna OK sin re-emitir eventos.
--   - rejected/rewarded NO transitan acá (esos viven en flows separados).
--
-- Patrón canónico (espejo de issue_sanction post-G3.2):
--   1. validate + assert_permission
--   2. UPDATE group_contributions (status='verified', verified_by)
--   3. INSERT group_reputation_events (contribution_recognized,
--      subject=contributor, actor=verifier, evidence=contribution)
--   4. record_system_event('contribution.verified') captura uuid
--   5. evaluate_rules_for_event(uuid, 'sync') — engine puede reaccionar

CREATE OR REPLACE FUNCTION public.verify_contribution(
  p_group_id        uuid,
  p_contribution_id uuid,
  p_note            text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid                uuid := auth.uid();
  v_verifier_mid       uuid;
  v_verifier_user      uuid;
  v_contributor_mid    uuid;
  v_status             text;
  v_title              text;
  v_event_uuid         uuid;
  v_summary            text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  -- Load contribution under lock (prevents concurrent verify race)
  SELECT c.status, c.membership_id, COALESCE(NULLIF(btrim(c.title),''), NULLIF(btrim(c.description),''), 'Contribución')
    INTO v_status, v_contributor_mid, v_title
    FROM public.group_contributions c
   WHERE c.id = p_contribution_id
     AND c.group_id = p_group_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contribution not found in group' USING errcode = '22023';
  END IF;

  -- Idempotency: already verified → return without side effects
  IF v_status = 'verified' THEN
    RETURN p_contribution_id;
  END IF;

  IF v_status <> 'claimed' THEN
    RAISE EXCEPTION 'contribution cannot be verified from status %', v_status
      USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(p_group_id, 'contribution.verify');

  -- Resolve verifier membership (active in group)
  SELECT gm.id, gm.user_id
    INTO v_verifier_mid, v_verifier_user
    FROM public.group_memberships gm
   WHERE gm.group_id = p_group_id
     AND gm.user_id  = v_uid
     AND gm.status   = 'active'
   LIMIT 1;

  IF v_verifier_mid IS NULL THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  -- Doctrine: contributor cannot verify own contribution.
  IF v_verifier_mid = v_contributor_mid THEN
    RAISE EXCEPTION 'contributor cannot verify their own contribution'
      USING errcode = '42501';
  END IF;

  -- 1. Canonical mutation: status transition + verifier
  UPDATE public.group_contributions
     SET status      = 'verified',
         verified_by = v_verifier_user
   WHERE id = p_contribution_id;

  -- 2. Auto-emit reputation event (closes §C.11 listener)
  INSERT INTO public.group_reputation_events (
    group_id, subject_membership_id, actor_membership_id,
    reputation_type, reason, evidence_entity_kind, evidence_entity_id,
    visibility, status, metadata
  )
  VALUES (
    p_group_id, v_contributor_mid, v_verifier_mid,
    'contribution_recognized',
    NULLIF(btrim(COALESCE(p_note, '')), ''),
    'contribution', p_contribution_id,
    'members', 'active',
    jsonb_build_object('contribution_title', v_title)
  );

  -- 3. System event + 4. Rule engine eval (engine bridge)
  v_summary := concat('Contribución verificada: ', v_title);
  SELECT rse.uuid_id INTO v_event_uuid FROM public.record_system_event(
    p_group_id, 'contribution.verified', 'contribution', p_contribution_id,
    v_summary,
    jsonb_build_object(
      'contributor_membership_id', v_contributor_mid,
      'verifier_membership_id',    v_verifier_mid,
      'note',                      NULLIF(btrim(COALESCE(p_note,'')), '')
    )
  ) rse;
  PERFORM public.evaluate_rules_for_event(v_event_uuid, 'sync');

  RETURN p_contribution_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.verify_contribution(uuid, uuid, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.verify_contribution(uuid, uuid, text) TO authenticated;

COMMENT ON FUNCTION public.verify_contribution(uuid, uuid, text) IS
  'V3-A1 (mig 20260530000000): verify a claimed contribution. Requires permission contribution.verify; contributor cannot self-verify; only claimed → verified transition. Idempotent for already-verified rows. Inserts contribution_recognized reputation event + emits contribution.verified system event + invokes rule engine. Closes Primitiva 9 §C.9 and connection §C.11 (contribution.verified → reputation).';
