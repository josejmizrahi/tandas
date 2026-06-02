-- V3-D.17 FASE E
-- Replaces the D.16 "approximation" branch of `resource.balance` inside
-- `_rule_atom_resolve` with an exact implementation that neutralises
-- reversed transaction pairs:
--   * any tx that is itself a reversal (reversed_entry_id IS NOT NULL)
--     is excluded, and
--   * the original tx referenced by another row's reversed_entry_id is
--     also excluded.
-- Both sides of a reversal pair therefore disappear from the sum,
-- matching the doctrine "reversal neutral".
--
-- The atom key stays `resource.balance` (no new atom). Other branches
-- (booking_count, usage_24h, all non-computed atoms) are preserved
-- verbatim.

CREATE OR REPLACE FUNCTION public._rule_atom_resolve(
  p_resource_id uuid,
  p_atom_key    text
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_r       public.group_resources%ROWTYPE;
  v_val     jsonb;
  v_balance numeric;
  v_count   int;
BEGIN
  IF p_resource_id IS NULL OR p_atom_key IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id;
  IF v_r.id IS NULL THEN RETURN NULL; END IF;

  CASE p_atom_key
    WHEN 'resource.id'                  THEN RETURN to_jsonb(v_r.id::text);
    WHEN 'resource.type'                THEN RETURN to_jsonb(v_r.resource_type);
    WHEN 'resource.name'                THEN RETURN to_jsonb(v_r.name);
    WHEN 'resource.status'              THEN RETURN to_jsonb(v_r.status);
    WHEN 'resource.lifecycle_state'     THEN RETURN to_jsonb(v_r.status);
    WHEN 'resource.unit'                THEN RETURN CASE WHEN v_r.unit IS NULL THEN NULL ELSE to_jsonb(v_r.unit) END;
    WHEN 'resource.archived_at'         THEN RETURN CASE WHEN v_r.archived_at IS NULL THEN NULL ELSE to_jsonb(v_r.archived_at::text) END;
    WHEN 'resource.owner_membership_id' THEN RETURN CASE WHEN v_r.owner_membership_id IS NULL THEN NULL ELSE to_jsonb(v_r.owner_membership_id::text) END;
    WHEN 'resource.value' THEN
      SELECT to_jsonb(current_value) INTO v_val FROM public.group_resource_assets WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.condition' THEN
      SELECT to_jsonb(condition)     INTO v_val FROM public.group_resource_assets WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.custodian_membership_id' THEN
      SELECT CASE WHEN custodian_membership_id IS NULL THEN NULL ELSE to_jsonb(custodian_membership_id::text) END
        INTO v_val FROM public.group_resource_assets WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.holder_membership_id' THEN
      SELECT CASE WHEN holder_membership_id IS NULL THEN NULL ELSE to_jsonb(holder_membership_id::text) END
        INTO v_val FROM public.group_resource_rights WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.is_transferable' THEN
      SELECT to_jsonb(transferable) INTO v_val FROM public.group_resource_rights WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.slot_assignee' THEN
      SELECT CASE WHEN assigned_membership_id IS NULL THEN NULL ELSE to_jsonb(assigned_membership_id::text) END
        INTO v_val FROM public.group_resource_slots WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.threshold' THEN
      SELECT to_jsonb(threshold_target) INTO v_val FROM public.group_resource_funds WHERE resource_id = p_resource_id;
      RETURN v_val;
    WHEN 'resource.is_locked' THEN
      SELECT to_jsonb(locked_at IS NOT NULL) INTO v_val FROM public.group_resource_funds WHERE resource_id = p_resource_id;
      RETURN v_val;

    -- =========================================================================
    -- D.17 — exact resource.balance: reversed pairs disappear from the sum.
    -- A row is excluded when:
    --   (a) it is itself a reversal (reversed_entry_id IS NOT NULL), or
    --   (b) it is the original referenced by some other row's reversed_entry_id.
    -- =========================================================================
    WHEN 'resource.balance' THEN
      SELECT COALESCE(SUM(
        CASE
          WHEN t.transaction_type IN ('contribution','income','refund','allocation','payout')                       THEN  t.amount
          WHEN t.transaction_type IN ('expense','settlement_payment','fine_payment','pool_charge','booking_charge') THEN -t.amount
          ELSE 0
        END), 0)
      INTO v_balance
      FROM public.group_resource_transactions t
      WHERE (t.source_resource_id = p_resource_id
             OR (t.source_resource_id IS NULL AND t.resource_id = p_resource_id))
        AND t.reversed_entry_id IS NULL
        AND NOT EXISTS (
          SELECT 1
          FROM public.group_resource_transactions r
          WHERE r.reversed_entry_id = t.id
        );
      RETURN to_jsonb(v_balance);

    WHEN 'resource.booking_count' THEN
      SELECT count(*) INTO v_count
        FROM public.group_resource_bookings
       WHERE resource_id = p_resource_id
         AND status <> 'cancelled';
      RETURN to_jsonb(v_count);

    WHEN 'resource.usage_count_24h' THEN
      SELECT count(*) INTO v_count
        FROM public.group_events
       WHERE event_type = 'resource.used'
         AND entity_id  = p_resource_id
         AND created_at >= now() - interval '24 hours';
      RETURN to_jsonb(v_count);

    ELSE
      RETURN NULL;
  END CASE;
END;
$function$;

COMMENT ON FUNCTION public._rule_atom_resolve(uuid, text) IS
  'V3-D.17 — resource.balance now exact: reversed pairs (original + reversal) are both excluded.';
