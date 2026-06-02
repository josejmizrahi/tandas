-- 20260529210000 — V3-SE-1: settle-up plan per member (Splitwise-style).
--
-- Cierra el segundo feature icónico de Splitwise. Hoy iOS solo tiene
-- las obligations donde el caller debe (member_obligation_summary).
-- Para proponer un plan de liquidación "tipo Splitwise" necesitamos
-- agregar el lado opuesto (lo que le deben al caller) y reducir ambos
-- por counterparty con NETTING bidireccional.
--
-- Shape devuelto: 1 fila por counterparty con balance != 0.
--   net_amount > 0 → caller debe esa cantidad neta a counterparty
--   net_amount < 0 → counterparty debe esa cantidad neta al caller
--
-- Ordenamos por |net_amount| DESC para que la UI muestre primero los
-- "líos más grandes". UI hace tap → RecordSettlementSheet prefill.
--
-- Solo agrupa obligations peer-to-peer (owed_to_kind='member'). Las
-- obligations contra el pool (multas, buy-ins) viven en su propio
-- flujo y NO entran al optimizer (decisión 4 del founder firmada).
-- Eso mantiene el plan "pago a un amigo" mental claro.

CREATE OR REPLACE FUNCTION public.group_settlement_plan_for_member(
  p_group_id      uuid,
  p_membership_id uuid
)
RETURNS TABLE (
  counterparty_membership_id uuid,
  counterparty_display_name  text,
  net_amount                 numeric,
  unit                       text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  -- Caller must be an active member of the group AND match the
  -- membership the plan is being asked about (or hold an admin
  -- permission; Foundation: identity match only).
  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id
       AND gm.id       = p_membership_id
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not the active membership being queried'
      USING errcode = '42501';
  END IF;

  RETURN QUERY
  WITH owed_by_me AS (
    SELECT o.owed_to_membership_id AS counter,
           SUM(o.amount_outstanding) AS amt,
           MAX(o.unit) AS unit
      FROM public.group_obligations o
     WHERE o.group_id = p_group_id
       AND o.owed_by_membership_id = p_membership_id
       AND o.owed_to_kind = 'member'
       AND o.status IN ('open','partially_settled')
     GROUP BY o.owed_to_membership_id
  ),
  owed_to_me AS (
    SELECT o.owed_by_membership_id AS counter,
           SUM(o.amount_outstanding) AS amt,
           MAX(o.unit) AS unit
      FROM public.group_obligations o
     WHERE o.group_id = p_group_id
       AND o.owed_to_membership_id = p_membership_id
       AND o.owed_to_kind = 'member'
       AND o.status IN ('open','partially_settled')
     GROUP BY o.owed_by_membership_id
  ),
  parties AS (
    SELECT counter FROM owed_by_me
    UNION
    SELECT counter FROM owed_to_me
  ),
  netted AS (
    SELECT pa.counter,
           COALESCE(o1.amt, 0) - COALESCE(o2.amt, 0) AS net,
           COALESCE(o1.unit, o2.unit) AS unit
      FROM parties pa
      LEFT JOIN owed_by_me o1 ON o1.counter = pa.counter
      LEFT JOIN owed_to_me o2 ON o2.counter = pa.counter
  )
  SELECT
    n.counter,
    COALESCE(NULLIF(p.display_name, ''), NULLIF(p.username, ''), '')::text,
    n.net,
    n.unit
  FROM netted n
  LEFT JOIN public.group_memberships gm ON gm.id = n.counter
  LEFT JOIN public.profiles          p  ON p.id  = gm.user_id
  WHERE n.net <> 0
  ORDER BY ABS(n.net) DESC;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.group_settlement_plan_for_member(uuid, uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_settlement_plan_for_member(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.group_settlement_plan_for_member(uuid, uuid) IS
  'V3-SE-1 (mig 20260529210000): "Settle up" plan from the caller''s perspective. Returns one row per peer counterparty with net_amount: >0 caller owes, <0 caller is owed. Pool obligations excluded by doctrine. Ordered by ABS(net_amount) DESC.';
