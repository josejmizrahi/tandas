-- 20260529200725 — V3-S3: expose split_breakdown in group_money_movements.
--
-- Cierra el loop visual del split engine (S1). Hoy la lista de movimientos
-- expone split_mode pero NO el breakdown row-by-row, así que MoneyMovement
-- DetailView solo puede decir "split: custom" sin mostrar a quién le tocó
-- cuánto. Agregamos `split_breakdown jsonb` enriquecido con display_name
-- por participante para que iOS pinte la card "Pedro: $33.33 / Tú: $33.34"
-- sin depender de MembersStore estar cacheado.
--
-- Shape del jsonb:
--   [{ "membership_id": uuid, "display_name": text|null, "amount": numeric|null }]
-- amount es null cuando la fila legacy (pre-S1) emitía split_mode='even'
-- con solo membership_id. iOS muestra "—" o calcula amount/n en ese caso.
--
-- Cambio de signature → DROP+CREATE. Backward-safe: el iOS decoder lee
-- por CodingKeys; campos extra en el response JSON son ignorados.

DROP FUNCTION IF EXISTS public.group_money_movements(uuid, integer, text[], bigint);

CREATE OR REPLACE FUNCTION public.group_money_movements(
  p_group_id    uuid,
  p_limit       integer DEFAULT 100,
  p_filter      text[] DEFAULT NULL,
  p_before_seq  bigint  DEFAULT NULL
)
RETURNS TABLE (
  transaction_id            uuid,
  seq                       bigint,
  group_id                  uuid,
  transaction_type          text,
  amount                    numeric,
  unit                      text,
  from_membership_id        uuid,
  from_display_name         text,
  to_membership_id          uuid,
  to_display_name           text,
  paid_by_membership_id     uuid,
  paid_by_display_name      text,
  recorded_by_user_id       uuid,
  recorded_by_display_name  text,
  source_entity_kind        text,
  source_entity_id          uuid,
  source_resource_id        uuid,
  resource_id               uuid,
  reversed_entry_id         uuid,
  in_kind                   boolean,
  split_mode                text,
  split_breakdown           jsonb,
  description               text,
  occurred_at               timestamptz,
  created_at                timestamptz,
  mandate_id                uuid
)
LANGUAGE plpgsql
STABLE
SET search_path = 'public', 'pg_catalog'
AS $function$
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
    t.id, t.seq, t.group_id, t.transaction_type, t.amount, t.unit,
    t.from_membership_id, NULLIF(p_from.display_name, ''),
    t.to_membership_id, NULLIF(p_to.display_name, ''),
    t.paid_by_membership_id, NULLIF(p_paid.display_name, ''),
    t.recorded_by, NULLIF(p_rec.display_name, ''),
    t.source_entity_kind, t.source_entity_id, t.source_resource_id,
    t.resource_id, t.reversed_entry_id, t.in_kind, t.split_mode,
    -- Enriched breakdown: resolves each share's membership_id → display_name.
    (
      SELECT jsonb_agg(
        jsonb_build_object(
          'membership_id', el->>'membership_id',
          'display_name',  NULLIF(p_bd.display_name, ''),
          'amount',        CASE WHEN (el ? 'amount') THEN (el->>'amount')::numeric ELSE NULL END
        )
      )
      FROM jsonb_array_elements(t.split_breakdown) el
      LEFT JOIN public.group_memberships gm_bd ON gm_bd.id = (el->>'membership_id')::uuid
      LEFT JOIN public.profiles          p_bd  ON p_bd.id  = gm_bd.user_id
    ),
    t.description, t.occurred_at, t.created_at, t.mandate_id
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
$function$;

REVOKE EXECUTE ON FUNCTION public.group_money_movements(uuid, integer, text[], bigint) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_money_movements(uuid, integer, text[], bigint) TO authenticated;

COMMENT ON FUNCTION public.group_money_movements(uuid, integer, text[], bigint) IS
  'V3-S3 (mig 20260529200725): returns pre-joined money movements with split_breakdown enriched per-participant (membership_id + display_name + amount). amount may be null for legacy rows where split_mode=even was emitted with only membership_id (pre-S1).';
