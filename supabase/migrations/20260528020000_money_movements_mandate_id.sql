-- 20260528020000 — group_money_movements expone mandate_id (V2-G5 read).
--
-- group_resource_transactions ya persiste mandate_id (las RPCs canónicas de
-- dinero lo aceptan en p_mandate_id desde Phase 4.4 y V2-G5 sub-slice 1
-- ya lo está poblando desde iOS), pero la read-surface
-- group_money_movements no lo exponía. Esta migración:
--   - DROP + CREATE OR REPLACE (cambiar RETURNS TABLE requiere drop)
--   - agrega `mandate_id uuid` al final del TABLE shape
--   - mantiene la misma firma de parámetros y comportamiento
--
-- MoneyMovementDetailView usa el id para cross-referenciar contra
-- MandatesStore y mostrar "Hecho por X representando a Y" cuando el
-- mandato sigue activo; cuando ya fue revocado se muestra el id como
-- referencia neutra.

DROP FUNCTION IF EXISTS public.group_money_movements(uuid, int, text[], bigint);

CREATE OR REPLACE FUNCTION public.group_money_movements(
  p_group_id    uuid,
  p_limit       int       DEFAULT 100,
  p_filter      text[]    DEFAULT NULL,
  p_before_seq  bigint    DEFAULT NULL
)
RETURNS TABLE (
  transaction_id          uuid,
  seq                     bigint,
  group_id                uuid,
  transaction_type        text,
  amount                  numeric,
  unit                    text,
  from_membership_id      uuid,
  from_display_name       text,
  to_membership_id        uuid,
  to_display_name         text,
  paid_by_membership_id   uuid,
  paid_by_display_name    text,
  recorded_by_user_id     uuid,
  recorded_by_display_name text,
  source_entity_kind      text,
  source_entity_id        uuid,
  source_resource_id      uuid,
  resource_id             uuid,
  reversed_entry_id       uuid,
  in_kind                 boolean,
  split_mode              text,
  description             text,
  occurred_at             timestamptz,
  created_at              timestamptz,
  mandate_id              uuid
)
LANGUAGE plpgsql
STABLE SECURITY INVOKER
SET search_path = 'public', 'pg_catalog'
AS $$
#variable_conflict use_column
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    t.id                                 AS transaction_id,
    t.seq                                AS seq,
    t.group_id                           AS group_id,
    t.transaction_type                   AS transaction_type,
    t.amount                             AS amount,
    t.unit                               AS unit,
    t.from_membership_id                 AS from_membership_id,
    NULLIF(p_from.display_name, '')      AS from_display_name,
    t.to_membership_id                   AS to_membership_id,
    NULLIF(p_to.display_name, '')        AS to_display_name,
    t.paid_by_membership_id              AS paid_by_membership_id,
    NULLIF(p_paid.display_name, '')      AS paid_by_display_name,
    t.recorded_by                        AS recorded_by_user_id,
    NULLIF(p_rec.display_name, '')       AS recorded_by_display_name,
    t.source_entity_kind                 AS source_entity_kind,
    t.source_entity_id                   AS source_entity_id,
    t.source_resource_id                 AS source_resource_id,
    t.resource_id                        AS resource_id,
    t.reversed_entry_id                  AS reversed_entry_id,
    t.in_kind                            AS in_kind,
    t.split_mode                         AS split_mode,
    t.description                        AS description,
    t.occurred_at                        AS occurred_at,
    t.created_at                         AS created_at,
    t.mandate_id                         AS mandate_id
  FROM public.group_resource_transactions t
  LEFT JOIN public.group_memberships gm_from ON gm_from.id = t.from_membership_id
  LEFT JOIN public.profiles          p_from  ON p_from.id  = gm_from.user_id
  LEFT JOIN public.group_memberships gm_to   ON gm_to.id   = t.to_membership_id
  LEFT JOIN public.profiles          p_to    ON p_to.id    = gm_to.user_id
  LEFT JOIN public.group_memberships gm_paid ON gm_paid.id = t.paid_by_membership_id
  LEFT JOIN public.profiles          p_paid  ON p_paid.id  = gm_paid.user_id
  LEFT JOIN public.profiles          p_rec   ON p_rec.id   = t.recorded_by
  WHERE t.group_id = p_group_id
    AND (p_filter     IS NULL OR t.transaction_type = ANY (p_filter))
    AND (p_before_seq IS NULL OR t.seq < p_before_seq)
  ORDER BY t.seq DESC
  LIMIT GREATEST(1, COALESCE(p_limit, 100));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_money_movements(uuid, int, text[], bigint) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_money_movements(uuid, int, text[], bigint) TO authenticated;

COMMENT ON FUNCTION public.group_money_movements(uuid, int, text[], bigint) IS
  'Primitiva 19 Foundation (mig 20260527110000 + 20260528020000): paginated read of group_resource_transactions for a group, newest first by seq. p_filter restricts transaction_type; NULL = all. p_before_seq cursor enables infinite scroll. Pre-joined with from/to/paid_by/recorded_by display names. mandate_id propagado para que iOS muestre "actuó en nombre de…" en MoneyMovementDetailView. SECURITY INVOKER + active-member gate.';
