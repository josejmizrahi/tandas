-- PARTE 12 hot-fix: cancel_sanction_payment_plan citaba `sanction.review`
-- (singular + "review") que NO existe en catálogo `permissions`. Real keys:
-- sanctions.create | sanctions.dispute | sanctions.update.
--
-- Semánticamente cancelar un payment plan = mutar el estado del sanction asociado,
-- por lo que `sanctions.update` es el authority right correcto. Rename mechanical
-- al estado real (paralelo a hot-fixes de start_vote y emit_mandate_expiring).

CREATE OR REPLACE FUNCTION public.cancel_sanction_payment_plan(p_plan_id uuid, p_reason text DEFAULT NULL::text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_plan public.group_sanction_payment_plans%ROWTYPE;
  v_target_user uuid;
  v_is_target boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_plan FROM public.group_sanction_payment_plans WHERE id = p_plan_id;
  IF v_plan.id IS NULL THEN
    RAISE EXCEPTION 'plan % not found', p_plan_id;
  END IF;
  IF v_plan.status <> 'active' THEN
    RAISE EXCEPTION 'plan % is not active', p_plan_id USING errcode = '22023';
  END IF;

  SELECT user_id INTO v_target_user
    FROM public.group_memberships
   WHERE id = v_plan.proposed_by_membership_id;
  v_is_target := (v_target_user = v_uid);

  IF NOT v_is_target THEN
    PERFORM public.assert_permission(v_plan.group_id, 'sanctions.update');
  END IF;

  UPDATE public.group_sanction_payment_plans
     SET status        = 'cancelled',
         cancel_reason = p_reason,
         cancelled_at  = now()
   WHERE id = p_plan_id;

  PERFORM public.record_system_event(
    p_group_id    => v_plan.group_id,
    p_event_type  => 'sanction.payment_plan_cancelled',
    p_entity_kind => 'sanction',
    p_entity_id   => v_plan.sanction_id,
    p_payload     => jsonb_build_object(
      'plan_id',  p_plan_id,
      'reason',   p_reason,
      'by_target', v_is_target
    )
  );
END;
$function$;

-- PARTE 8b posture
REVOKE ALL ON FUNCTION public.cancel_sanction_payment_plan(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sanction_payment_plan(uuid,text) TO authenticated, service_role;
