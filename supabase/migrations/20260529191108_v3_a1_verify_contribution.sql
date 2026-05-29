-- 20260529191108 — V3-A1 (REVERTED en 20260529191210 — ver rollback).
--
-- INTENTO: aterrizar verify_contribution(p_group_id, p_contribution_id, p_note)
-- como auto-reputation chain. Founder pidió "cerrar conexión §C.11".
--
-- HALLAZGO POST-APPLY: la RPC verify_contribution(p_contribution_id, p_outcome, p_note)
-- ya existía en BD desde mig previa no encontrada en el repo (probable seed canónico
-- pre-fase B), y cubre el flow completo (verified|rejected + auto-reputation +
-- system_event + engine eval). Esta mig creó un OVERLOAD innecesario.
--
-- Ver rollback en 20260529191210_v3_a1_verify_contribution_rollback_overload.sql.
-- Memoria: `feedback_verify_before_implement` (protocolo verify contra BD-real
-- antes de cualquier mig). Cuerpo §0 de PrimitivesArchitecture.md.

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

  SELECT c.status, c.membership_id, COALESCE(NULLIF(btrim(c.title),''), NULLIF(btrim(c.description),''), 'Contribución')
    INTO v_status, v_contributor_mid, v_title
    FROM public.group_contributions c
   WHERE c.id = p_contribution_id
     AND c.group_id = p_group_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contribution not found in group' USING errcode = '22023';
  END IF;

  IF v_status = 'verified' THEN
    RETURN p_contribution_id;
  END IF;

  IF v_status <> 'claimed' THEN
    RAISE EXCEPTION 'contribution cannot be verified from status %', v_status
      USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(p_group_id, 'contribution.verify');

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

  IF v_verifier_mid = v_contributor_mid THEN
    RAISE EXCEPTION 'contributor cannot verify their own contribution'
      USING errcode = '42501';
  END IF;

  UPDATE public.group_contributions
     SET status      = 'verified',
         verified_by = v_verifier_user
   WHERE id = p_contribution_id;

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
  'V3-A1 (mig 20260529191108) — REVERTED en 20260529191210 por overload con la firma canónica preexistente verify_contribution(p_contribution_id, p_outcome, p_note).';
