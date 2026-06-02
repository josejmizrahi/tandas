-- R.0E.1 — actor_net_worth(actor_id) jsonb
--
-- Founder scope:
--   - Calcular por moneda
--   - Sumar solo OWN activo (revoked NULL + expired NULL + starts ≤now + ends NULL/>now)
--   - Aplicar percent (default 100 si NULL)
--   - Excluir USE, MANAGE, VIEW (y todos los demás kinds: SELL/TRANSFER/GOVERN/PLEDGE/LIEN/LEASE/COLLECT_INCOME/PAY_EXPENSES/AUDIT/APPROVE)
--   - Reportar BENEFICIARY separado (NO sumarlo al net worth)
--   - NO FX (cada moneda agrupada independiente)
--   - NO iOS
--
-- Limitation R.0E.1: resources NO tienen columnas value/currency dedicadas.
-- Source: resources.metadata->>'estimated_value' y resources.metadata->>'currency'.
-- Currently 0/99 resources tienen estos campos populados → función retorna 0
-- hasta que se popule metadata. Future R.0E.x puede extender a subtype-aware
-- (group_resource_funds.currency + balance computed from group_resource_transactions, etc.).

CREATE OR REPLACE FUNCTION public.actor_net_worth(p_actor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_owned       jsonb;
  v_beneficiary jsonb;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'actor_id required' USING errcode = '22023';
  END IF;

  WITH active_own AS (
    SELECT
      r.id AS resource_id,
      r.resource_type,
      COALESCE((r.metadata->>'estimated_value')::numeric, 0) AS resource_value,
      COALESCE(r.metadata->>'currency', 'unknown') AS currency,
      COALESCE(rr.percent, 100) / 100.0 AS share
      FROM public.resource_rights rr
      JOIN public.resources r ON r.id = rr.resource_id
     WHERE rr.holder_actor_id = p_actor_id
       AND rr.right_kind = 'OWN'
       AND rr.revoked_at IS NULL
       AND rr.expired_at IS NULL
       AND (rr.starts_at IS NULL OR rr.starts_at <= now())
       AND (rr.ends_at IS NULL OR rr.ends_at > now())
       AND r.archived_at IS NULL
  ),
  owned_by_currency AS (
    SELECT
      currency,
      sum(resource_value * share) AS owned_value,
      count(*) AS owned_count,
      jsonb_agg(resource_id) AS resource_ids
      FROM active_own
     GROUP BY currency
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'currency', currency,
           'owned_value', owned_value,
           'owned_count', owned_count,
           'resource_ids', resource_ids
         ) ORDER BY currency), '[]'::jsonb)
    INTO v_owned
    FROM owned_by_currency;

  WITH active_beneficiary AS (
    SELECT
      r.id AS resource_id,
      COALESCE((r.metadata->>'estimated_value')::numeric, 0) AS resource_value,
      COALESCE(r.metadata->>'currency', 'unknown') AS currency,
      COALESCE(rr.percent, 100) / 100.0 AS share
      FROM public.resource_rights rr
      JOIN public.resources r ON r.id = rr.resource_id
     WHERE rr.holder_actor_id = p_actor_id
       AND rr.right_kind = 'BENEFICIARY'
       AND rr.revoked_at IS NULL
       AND rr.expired_at IS NULL
       AND (rr.starts_at IS NULL OR rr.starts_at <= now())
       AND (rr.ends_at IS NULL OR rr.ends_at > now())
       AND r.archived_at IS NULL
  ),
  beneficiary_by_currency AS (
    SELECT
      currency,
      sum(resource_value * share) AS value,
      count(*) AS resource_count,
      jsonb_agg(resource_id) AS resource_ids
      FROM active_beneficiary
     GROUP BY currency
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'currency', currency,
           'value', value,
           'count', resource_count,
           'resource_ids', resource_ids
         ) ORDER BY currency), '[]'::jsonb)
    INTO v_beneficiary
    FROM beneficiary_by_currency;

  RETURN jsonb_build_object(
    'actor_id', p_actor_id,
    'as_of', now(),
    'owned_by_currency', v_owned,
    'beneficiary_by_currency', v_beneficiary,
    'notes', jsonb_build_object(
      'value_source', 'resources.metadata->>estimated_value',
      'currency_source', 'resources.metadata->>currency (default unknown)',
      'excluded_kinds', jsonb_build_array('USE','MANAGE','VIEW','SELL','TRANSFER','GOVERN','PLEDGE','LIEN','LEASE','COLLECT_INCOME','PAY_EXPENSES','AUDIT','APPROVE'),
      'fx', 'none — values grouped by currency without conversion'
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.actor_net_worth(uuid) TO authenticated, anon;

COMMENT ON FUNCTION public.actor_net_worth(uuid) IS
  'R.0E.1. Net worth jsonb por actor. Sum OWN active rights × percent/100 grouped by currency. BENEFICIARY reported separately (not summed). Exclude USE/MANAGE/VIEW/etc. No FX. Value source: resources.metadata->>estimated_value. Currency: metadata->>currency (default unknown).';
