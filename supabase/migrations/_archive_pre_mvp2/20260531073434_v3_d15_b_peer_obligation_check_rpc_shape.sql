-- V3 FASE D.15 — Mig B (part 1): extend obligation_kind CHECK, new RPC, new shape,
-- compat lists updated on triggers that legitimately accept create_obligation.

BEGIN;

-- =============================================================================
-- B1: CHECK — admit 'peer_obligation'
-- =============================================================================
ALTER TABLE public.group_obligations
  DROP CONSTRAINT IF EXISTS group_obligations_obligation_kind_check;
ALTER TABLE public.group_obligations
  ADD CONSTRAINT group_obligations_obligation_kind_check
  CHECK (obligation_kind = ANY (ARRAY[
    'expense_share'::text, 'fine'::text, 'pool_charge'::text,
    'contribution_due'::text, 'custom'::text, 'peer_obligation'::text]));

-- =============================================================================
-- B2: RPC record_peer_obligation (member -> member, non-punitive)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.record_peer_obligation(
  p_group_id uuid,
  p_owed_by_membership_id uuid,
  p_owed_to_membership_id uuid,
  p_amount numeric,
  p_unit text,
  p_reason text DEFAULT NULL,
  p_source_resource_id uuid DEFAULT NULL,
  p_rule_version_id uuid DEFAULT NULL,
  p_source_event_id uuid DEFAULT NULL,
  p_client_id text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_obligation_id uuid;
  v_unit text;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be > 0' USING errcode = '22023';
  END IF;
  v_unit := NULLIF(btrim(coalesce(p_unit, '')), '');
  IF v_unit IS NULL THEN
    RAISE EXCEPTION 'unit required' USING errcode = '22023';
  END IF;
  IF p_owed_by_membership_id IS NULL OR p_owed_to_membership_id IS NULL THEN
    RAISE EXCEPTION 'owed_by and owed_to required' USING errcode = '22023';
  END IF;
  IF p_owed_by_membership_id = p_owed_to_membership_id THEN
    RAISE EXCEPTION 'self obligation not allowed' USING errcode = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.group_memberships
                  WHERE id = p_owed_by_membership_id AND group_id = p_group_id) THEN
    RAISE EXCEPTION 'owed_by membership not in group' USING errcode = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.group_memberships
                  WHERE id = p_owed_to_membership_id AND group_id = p_group_id) THEN
    RAISE EXCEPTION 'owed_to membership not in group' USING errcode = '22023';
  END IF;

  -- Idempotency via client_id
  IF p_client_id IS NOT NULL THEN
    SELECT id INTO v_obligation_id FROM public.group_obligations
     WHERE group_id = p_group_id
       AND obligation_kind = 'peer_obligation'
       AND metadata->>'client_id' = p_client_id
     LIMIT 1;
    IF v_obligation_id IS NOT NULL THEN RETURN v_obligation_id; END IF;
  END IF;

  INSERT INTO public.group_obligations (
    group_id, owed_by_membership_id, owed_to_membership_id, owed_to_kind,
    obligation_kind, amount_original, amount_outstanding, unit, status,
    description, source_resource_id, metadata)
  VALUES (
    p_group_id, p_owed_by_membership_id, p_owed_to_membership_id, 'member',
    'peer_obligation', p_amount, p_amount, v_unit, 'open',
    p_reason, p_source_resource_id,
    jsonb_build_object(
      'rule_version_id', p_rule_version_id,
      'source_event_id', p_source_event_id,
      'client_id', p_client_id))
  RETURNING id INTO v_obligation_id;

  PERFORM public.record_system_event(
    p_group_id, 'obligation.peer_created', 'obligation', v_obligation_id,
    'Obligación entre miembros creada',
    jsonb_build_object(
      'owed_by_membership_id', p_owed_by_membership_id,
      'owed_to_membership_id', p_owed_to_membership_id,
      'amount', p_amount, 'unit', v_unit,
      'rule_version_id', p_rule_version_id,
      'source_event_id', p_source_event_id));

  RETURN v_obligation_id;
END;
$$;

REVOKE ALL ON FUNCTION public.record_peer_obligation(uuid,uuid,uuid,numeric,text,text,uuid,uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_peer_obligation(uuid,uuid,uuid,numeric,text,text,uuid,uuid,uuid,text) TO authenticated, service_role;

-- =============================================================================
-- B3: New shape consequence.create_obligation
-- =============================================================================
INSERT INTO public.rule_shapes_catalog (shape_key, category, display_name, description, schema, resource_types, metadata)
VALUES
  ('consequence.create_obligation', 'consequence',
   'Crear obligación entre miembros',
   'Obligación monetaria peer-to-peer (no punitiva). El actor del evento queda como deudor; el contraparte se resuelve según counterparty.',
   jsonb_build_object(
     'action','create_obligation',
     'fields', jsonb_build_array(
       jsonb_build_object('key','counterparty','type','enum','label','Contraparte',
                          'enum', jsonb_build_array('target','owner','custodian','holder'),
                          'required',true),
       jsonb_build_object('key','amount','type','number','min',0,'label','Monto','required',true),
       jsonb_build_object('key','currency','type','string','label','Moneda','default','MXN','required',true),
       jsonb_build_object('key','reason','type','string','label','Razón','required',false)),
     'execution','sync',
     'authority_required','obligations.create'),
   ARRAY[]::text[],
   jsonb_build_object('icon','arrow.left.arrow.right.square'))
ON CONFLICT (shape_key) DO UPDATE
  SET category=EXCLUDED.category, display_name=EXCLUDED.display_name,
      description=EXCLUDED.description, schema=EXCLUDED.schema,
      resource_types=EXCLUDED.resource_types, metadata=EXCLUDED.metadata;

-- =============================================================================
-- B4: Add consequence.create_obligation to compatible_consequences of triggers
-- where peer-to-peer obligations make sense (same set as create_pool_charge today)
-- =============================================================================
UPDATE public.rule_shapes_catalog
SET schema = jsonb_set(
  schema, '{compatible_consequences}',
  CASE
    WHEN schema->'compatible_consequences' @> '"consequence.create_obligation"'::jsonb
      THEN schema->'compatible_consequences'
    ELSE (schema->'compatible_consequences') || '["consequence.create_obligation"]'::jsonb
  END)
WHERE category = 'trigger'
  AND shape_key IN (
    'trigger.money.expense_recorded',
    'trigger.money.settlement_recorded',
    'trigger.resource.damaged',
    'trigger.resource.used'
  );

COMMIT;
