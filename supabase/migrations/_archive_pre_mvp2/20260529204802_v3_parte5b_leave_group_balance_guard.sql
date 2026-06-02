-- V3 PARTE 5b — leave_group balance guard
--
-- Estado previo: cualquier miembro activo podía salir del grupo aunque
-- tuviera obligaciones abiertas o créditos no liquidados. El contrato
-- social del grupo dice que las obligaciones tienen peso; permitir un
-- "rage quit con deuda" rompe la doctrina Money 2.0 y deja basura en
-- group_obligations (status='open' sin titular activo).
--
-- Gate canónico (spec §M PARTE 5): member_balance_in_group(group, member)
-- debe ser exactamente 0 para permitir leave_group voluntario. Bloquea
-- ambas direcciones: miembro que debe Y miembro al que le deben. El
-- mensaje incluye el balance actual para que iOS muestre "salda %.2f
-- antes de salir".
--
-- IMPORTANT: este gate aplica SOLO al path voluntario `leave_group`.
-- La expulsión admin via `set_membership_state(membership, 'expelled')`
-- mantiene su path actual (el admin ya conoce el balance y firma el
-- expulse explícitamente — políticas pueden cubrir la liquidación).
--
-- Gap doctrinal conocido (no se cierra en este slice): member_balance_in_group
-- NO cuenta obligations donde el miembro es owed_to_membership_id. Un
-- creditor con balance neto 0 puede salir y dejar a su deudor sin
-- contraparte. Cerrarlo requiere expandir la función → PARTE 5b.bis
-- futuro.

CREATE OR REPLACE FUNCTION public.leave_group(
  p_group_id uuid,
  p_reason text DEFAULT NULL::text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_membership uuid;
  v_balance numeric;
BEGIN
  SELECT id INTO v_membership FROM public.group_memberships
   WHERE group_id = p_group_id AND user_id = auth.uid() AND status = 'active';
  IF v_membership IS NULL THEN
    RAISE EXCEPTION 'no active membership to leave';
  END IF;

  v_balance := public.member_balance_in_group(p_group_id, v_membership);
  IF v_balance <> 0 THEN
    RAISE EXCEPTION
      'balance_pending: settle obligations before leaving (current balance: %)', v_balance
      USING ERRCODE = '42501';
  END IF;

  PERFORM public.set_membership_state(v_membership, 'left', p_reason, NULL);
END;
$function$;

COMMENT ON FUNCTION public.leave_group(uuid, text) IS
  'V3 PARTE 5b: voluntary leave path. Asserts member_balance_in_group=0 before set_membership_state. Expulsion path (set_membership_state directly) bypasses this guard — admin authority assumes ownership of the balance disposition.';
