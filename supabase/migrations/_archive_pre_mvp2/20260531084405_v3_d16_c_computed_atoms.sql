-- V3 FASE D.16 — Mig C: 3 computed atoms + shape rows.
-- balance: source_resource_id primary, fallback to resource_id when source NULL.
--          Approximate (not full ledger w/ reversal nullification). Documented.
-- booking_count: count from group_resource_bookings WHERE status <> 'cancelled'.
-- usage_count_24h: count from group_events WHERE event_type='resource.used'
--                  AND entity_id=resource_id AND created_at >= now() - 24h.

BEGIN;

-- =============================================================================
-- C1: extend _rule_atom_resolve with 3 computed atoms
-- =============================================================================
CREATE OR REPLACE FUNCTION public._rule_atom_resolve(
  p_resource_id uuid,
  p_atom_key    text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_r   public.group_resources%ROWTYPE;
  v_val jsonb;
  v_balance numeric;
  v_count int;
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
    -- D.16 computed atoms (founder-approved approximation; reversal neutral)
    -- =========================================================================
    WHEN 'resource.balance' THEN
      SELECT COALESCE(SUM(
        CASE
          WHEN transaction_type IN ('contribution','income','refund','allocation','payout')          THEN  amount
          WHEN transaction_type IN ('expense','settlement_payment','fine_payment','pool_charge','booking_charge') THEN -amount
          ELSE 0
        END), 0)
      INTO v_balance
      FROM public.group_resource_transactions
      WHERE (source_resource_id = p_resource_id
             OR (source_resource_id IS NULL AND resource_id = p_resource_id));
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
$$;

-- =============================================================================
-- C2: register 3 atom shapes with category='atom'
-- =============================================================================
INSERT INTO public.rule_shapes_catalog (shape_key, category, display_name, description, schema, resource_types, metadata)
VALUES
  ('atom.resource.balance', 'atom',
   'Balance del recurso',
   'Suma con signo de group_resource_transactions. Aproximación operativa, no ledger contable definitivo. Reversal neutral.',
   jsonb_build_object('atom_key','resource.balance','atom_type','number'),
   ARRAY['fund','asset','vehicle','tool','inventory','real_estate','intellectual_property']::text[],
   jsonb_build_object(
     'derivation', 'SUM(amount * sign(transaction_type)) WHERE source_resource_id=p_resource_id OR (source_resource_id IS NULL AND resource_id=p_resource_id)',
     'positive_kinds', jsonb_build_array('contribution','income','refund','allocation','payout'),
     'negative_kinds', jsonb_build_array('expense','settlement_payment','fine_payment','pool_charge','booking_charge'),
     'neutral_kinds',  jsonb_build_array('transfer','adjustment','reversal'),
     'computed', true,
     'approximate', true,
     'nullable', false)),

  ('atom.resource.booking_count', 'atom',
   'Reservas vivas del recurso',
   'Cantidad de reservas no canceladas.',
   jsonb_build_object('atom_key','resource.booking_count','atom_type','number'),
   ARRAY['space','slot','asset','vehicle','tool']::text[],
   jsonb_build_object(
     'derivation', 'COUNT(*) FROM group_resource_bookings WHERE resource_id=p_resource_id AND status<>''cancelled''',
     'computed', true,
     'nullable', false)),

  ('atom.resource.usage_count_24h', 'atom',
   'Usos en las últimas 24h',
   'Cantidad de resource.used events para este recurso en la última ventana de 24h.',
   jsonb_build_object('atom_key','resource.usage_count_24h','atom_type','number'),
   ARRAY[]::text[],
   jsonb_build_object(
     'derivation', 'COUNT(*) FROM group_events WHERE event_type=''resource.used'' AND entity_id=p_resource_id AND created_at >= now() - interval ''24 hours''',
     'computed', true,
     'nullable', false))
ON CONFLICT (shape_key) DO UPDATE
  SET category=EXCLUDED.category, display_name=EXCLUDED.display_name,
      description=EXCLUDED.description, schema=EXCLUDED.schema,
      resource_types=EXCLUDED.resource_types, metadata=EXCLUDED.metadata;

COMMIT;
