-- V3 — record_pool_charge_batch: cobrar el mismo cargo a N miembros
-- de un grupo en una sola transacción atómica.
--
-- Doctrina: si UNA inserción falla (e.g., target no activo, mandato
-- expirado mid-batch, etc.) el batch completo rollback. No queremos
-- dejar al grupo con cobros parciales que requieran cleanup manual.
--
-- Per-target el cliente puede pasar un mismo client_id base; el
-- backend concatena con el target_id para que cada obligation tenga
-- su propio client_id único (idempotency real per row sin colisiones).

CREATE OR REPLACE FUNCTION public.record_pool_charge_batch(
  p_group_id uuid,
  p_target_membership_ids uuid[],
  p_amount numeric,
  p_unit text,
  p_charge_kind text,
  p_reason text DEFAULT NULL,
  p_mandate_id uuid DEFAULT NULL,
  p_client_id_base text DEFAULT NULL
) RETURNS TABLE(target_membership_id uuid, obligation_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_target uuid;
  v_obligation_id uuid;
  v_per_client_id text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING errcode = '42501';
  END IF;
  IF p_target_membership_ids IS NULL OR cardinality(p_target_membership_ids) = 0 THEN
    RAISE EXCEPTION 'target_membership_ids cannot be empty' USING errcode = '22023';
  END IF;
  IF cardinality(p_target_membership_ids) > 100 THEN
    RAISE EXCEPTION 'batch size exceeds 100 targets' USING errcode = '22023';
  END IF;

  -- Cada target invoca el RPC canonical record_pool_charge para
  -- preservar exactamente la misma lógica de autoridad / autorización
  -- / event emission / rule evaluation. Cero duplicación de logic.
  FOREACH v_target IN ARRAY p_target_membership_ids LOOP
    v_per_client_id := CASE
      WHEN p_client_id_base IS NULL THEN NULL
      ELSE p_client_id_base || ':' || v_target::text
    END;
    v_obligation_id := public.record_pool_charge(
      p_group_id => p_group_id,
      p_target_membership_id => v_target,
      p_amount => p_amount,
      p_unit => p_unit,
      p_charge_kind => p_charge_kind,
      p_reason => p_reason,
      p_mandate_id => p_mandate_id,
      p_client_id => v_per_client_id
    );
    target_membership_id := v_target;
    obligation_id := v_obligation_id;
    RETURN NEXT;
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public.record_pool_charge_batch(uuid, uuid[], numeric, text, text, text, uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.record_pool_charge_batch(uuid, uuid[], numeric, text, text, text, uuid, text) TO authenticated;

COMMENT ON FUNCTION public.record_pool_charge_batch(uuid, uuid[], numeric, text, text, text, uuid, text) IS
  'V3: cobra el mismo charge_kind/amount a N miembros atómicamente. Cada target reuses record_pool_charge para preservar authority + event + rule eval logic. Si UNA falla, rollback total. Limit 100 targets per batch.';
