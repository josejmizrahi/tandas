-- 20260526050000 — pool_payment_to_vendor (Money 2.0 Phase 4.5).
--
-- Founder audit 2026-05-26: el use case "sociedad" (Socio A aporta
-- terreno in-kind + Socio B aporta cash; el pool paga la construcción
-- de la nave directamente a proveedores) destapa un blocker:
-- `fund_record_expense` rechaza `p_to_member_id IS NULL` con "expense
-- recipient required" (mig 20260524205000 línea 64). La arquitectura
-- previa asumía que TODO gasto está fronteado por un miembro y el
-- pool le reembolsa. Para sociedad, viaje, construcción — escenarios
-- donde el pool YA tiene cash y paga al proveedor directamente — no
-- hay vía nativa: el workaround (registrar fronter ficticio + reembolso
-- inmediato) infla el ledger y crea ruido en la auditoría.
--
-- Esta migración añade el primitivo faltante: gasto del pool sin
-- contraparte miembro.
--
-- Diseño
-- ======
-- Nueva RPC `record_pool_payment_to_vendor(group, amount, currency,
-- vendor_name, note?, source_resource_id?, client_id)`:
--   * Inserta `ledger_entries(type='expense', from=NULL, to=NULL,
--     resource_id=shared_pool_id, metadata={vendor_name, ...})`.
--   * Idempotente via `metadata.client_id` (reuso del partial unique
--     index `ledger_entries_client_id_unique` de mig 00351).
--   * Auth: cualquier miembro activo del grupo. NO requiere admin —
--     mismo posture que registrar un expense normal.
--
-- Compatibilidad con vistas existentes
-- ====================================
-- - `group_money_summary_view` (mig 20260525221500): suma
--   `amount FILTER (type='expense')` sin filtrar por to_member_id, así
--   que el vendor expense reduce `shared_pool_out_cents` y
--   `shared_pool_balance_cents` ✓.
-- - `member_obligations_view` (mig 20260526040000): `pool_receivable`
--   CTE filtra `to_member_id IS NOT NULL`, así que NO crea receivable
--   espurio ✓.
-- - `peer_obligation`/`peer_receivable`: el expense sin split tampoco
--   crea peer obligations vía el trigger materialize_obligations
--   (revisar siguiente).
--
-- Trigger interaction
-- ===================
-- `materialize_obligations_from_expense` (mig 20260526000000) corre
-- AFTER INSERT on ledger_entries cuando type='expense' con
-- `split_breakdown`. Para vendor payments NO mandamos split_breakdown,
-- así que el trigger no dispara. ✓

CREATE OR REPLACE FUNCTION public.record_pool_payment_to_vendor(
  p_group_id            uuid,
  p_amount_cents        bigint,
  p_currency            text DEFAULT NULL,
  p_vendor_name         text DEFAULT NULL,
  p_note                text DEFAULT NULL,
  p_source_resource_id  uuid DEFAULT NULL,
  p_client_id           uuid DEFAULT NULL
)
RETURNS public.ledger_entries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid             uuid := auth.uid();
  v_caller_member   uuid;
  v_currency        text;
  v_group_currency  text;
  v_shared_pool_id  uuid;
  v_vendor          text;
  v_note            text;
  v_metadata        jsonb;
  v_entry           public.ledger_entries;
  v_existing        public.ledger_entries;
BEGIN
  -- Auth + arg validation.
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'record_pool_payment_to_vendor: auth required' USING errcode = '42501';
  END IF;
  IF p_group_id IS NULL THEN
    RAISE EXCEPTION 'record_pool_payment_to_vendor: group_id required' USING errcode = '22023';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    RAISE EXCEPTION 'record_pool_payment_to_vendor: amount must be positive' USING errcode = '22023';
  END IF;

  -- Idempotency pre-check (reuses the partial unique index from mig 00351).
  IF p_client_id IS NOT NULL THEN
    SELECT * INTO v_existing
      FROM public.ledger_entries
     WHERE group_id = p_group_id
       AND (metadata->>'client_id') = p_client_id::text
     LIMIT 1;
    IF v_existing.id IS NOT NULL THEN
      RETURN v_existing;
    END IF;
  END IF;

  -- Caller must be an active member.
  SELECT gm.id INTO v_caller_member
    FROM public.group_members gm
   WHERE gm.group_id = p_group_id AND gm.user_id = v_uid AND gm.active
   LIMIT 1;
  IF v_caller_member IS NULL THEN
    RAISE EXCEPTION 'record_pool_payment_to_vendor: caller not an active member of group'
      USING errcode = '42501';
  END IF;

  -- Resolve the shared pool (single row per group post mig 00357).
  SELECT id INTO v_shared_pool_id
    FROM public.resources
   WHERE group_id = p_group_id
     AND resource_type = 'fund'
     AND (metadata->>'is_shared_pool') = 'true'
     AND archived_at IS NULL
   LIMIT 1;
  IF v_shared_pool_id IS NULL THEN
    RAISE EXCEPTION 'record_pool_payment_to_vendor: group has no shared pool — data invariant violated'
      USING errcode = 'check_violation';
  END IF;

  -- Optional resource scope must belong to the group.
  IF p_source_resource_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.resources r
       WHERE r.id = p_source_resource_id AND r.group_id = p_group_id
    ) THEN
      RAISE EXCEPTION 'record_pool_payment_to_vendor: source_resource does not belong to group'
        USING errcode = '22023';
    END IF;
  END IF;

  SELECT g.currency INTO v_group_currency FROM public.groups g WHERE g.id = p_group_id;
  v_currency := COALESCE(p_currency, v_group_currency, 'MXN');

  v_vendor := NULLIF(trim(coalesce(p_vendor_name, '')), '');
  v_note   := NULLIF(trim(coalesce(p_note, '')), '');

  v_metadata := '{}'::jsonb;
  IF v_vendor IS NOT NULL THEN
    v_metadata := v_metadata || jsonb_build_object('vendor_name', v_vendor);
  END IF;
  IF v_note IS NOT NULL THEN
    v_metadata := v_metadata || jsonb_build_object('note', v_note);
  END IF;
  IF p_client_id IS NOT NULL THEN
    v_metadata := v_metadata || jsonb_build_object('client_id', p_client_id::text);
  END IF;
  IF p_source_resource_id IS NOT NULL THEN
    v_metadata := v_metadata || jsonb_build_object(
      'source_resource_id', p_source_resource_id::text
    );
  END IF;

  INSERT INTO public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by, source_resource_id
  ) VALUES (
    p_group_id,
    v_shared_pool_id,             -- attribute to the shared pool resource
    'expense',
    p_amount_cents,
    v_currency,
    NULL,                         -- pool is the source
    NULL,                         -- vendor (no member counterparty)
    v_metadata,
    now(), now(), v_uid,
    p_source_resource_id
  )
  RETURNING * INTO v_entry;

  RETURN v_entry;

EXCEPTION WHEN unique_violation THEN
  -- Concurrent retry with same client_id won the race; re-read.
  IF p_client_id IS NOT NULL THEN
    SELECT * INTO v_existing
      FROM public.ledger_entries
     WHERE group_id = p_group_id
       AND (metadata->>'client_id') = p_client_id::text
     LIMIT 1;
    IF v_existing.id IS NOT NULL THEN
      RETURN v_existing;
    END IF;
  END IF;
  RAISE;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.record_pool_payment_to_vendor(uuid, bigint, text, text, text, uuid, uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.record_pool_payment_to_vendor(uuid, bigint, text, text, text, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.record_pool_payment_to_vendor(uuid, bigint, text, text, text, uuid, uuid) IS
  'Money 2.0 Phase 4.5 (mig 20260526050000): pool paga directo a proveedor — sin miembro fronter, sin peer obligation, sin reembolso. Para construcción, viaje, sociedad: cuando el dinero ya está en el pool y sale al exterior. Idempotente via p_client_id (reusa partial unique index de mig 00351).';
