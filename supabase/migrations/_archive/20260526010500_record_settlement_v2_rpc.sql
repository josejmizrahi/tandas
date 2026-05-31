-- 20260526010500 — record_settlement_v2 RPC (Money 2.0 Phase 4.2).
--
-- Canonical settlement writer for the new 8-layer money architecture.
-- Replaces `record_settlement` (mig 00220) en filosofía — la vieja se
-- mantiene activa para backwards-compat hasta que iOS migre todos los
-- call sites a v2 (Phase 4.4).
--
-- Differences from v1
-- ===================
--   v1 (record_settlement, mig 00220):
--     * Solo escribe ledger_entries row type='settlement'.
--     * NO crea entidad settlement (porque no existía).
--     * NO conoce obligations (porque no existían).
--     * NO actualiza obligation status.
--     * NO es idempotent.
--
--   v2 (este RPC):
--     1. Idempotency check via (group_id, p_client_id).
--     2. INSERT en `settlements` table (status='confirmed').
--     3. FIFO allocate vs open obligations (owed_by=from, owed_to=to,
--        status IN ('open','partially_paid'), ORDER BY created_at ASC).
--     4. INSERT settlement_obligations bridge rows.
--     5. UPDATE obligation status to 'settled' or 'partially_paid'.
--     6. INSERT ledger_entries audit row (type='settlement') — sigue
--        siendo source of truth para balance views.
--     7. Link settlement.ledger_entry_id ← ledger entry id.
--
-- Edge cases
-- ==========
-- Over-allocation: si settlement amount > total outstanding obligations,
-- la diferencia queda unallocated (bridge sum < settlement.amount). El
-- ledger entry registra el monto completo, así que `member_balances_per_group`
-- naturalmente refleja el "advance / credit" hasta que Phase 6 (Wallet)
-- lo formalice. Esto NO es error — es el escenario "Alice pre-paga".
--
-- No-obligations: si el dyad no tiene open obligations, el settlement
-- crea 0 bridge rows pero igual escribe la settlement row + ledger. Eso
-- representa "Alice da $X a Bob aunque no le debiera nada" (regalo /
-- adelanto). Future Phase 6 puede materializar esto como wallet credit
-- para Bob.
--
-- Transaction atomicity: Postgres function = single transaction. Si
-- algo falla, todo rollback (settlement + bridge + obligation updates
-- + ledger entry).

CREATE OR REPLACE FUNCTION public.record_settlement_v2(
  p_group_id           uuid,
  p_from_member_id     uuid,
  p_to_member_id       uuid,
  p_amount_cents       bigint,
  p_currency           text DEFAULT NULL,
  p_note               text DEFAULT NULL,
  p_client_id          uuid DEFAULT NULL,
  p_source_resource_id uuid DEFAULT NULL
)
RETURNS public.settlements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid              uuid := auth.uid();
  v_caller_member    uuid;
  v_currency         text;
  v_group_currency   text;
  v_settlement       public.settlements;
  v_existing         public.settlements;
  v_ledger           public.ledger_entries;
  v_remaining        bigint;
  v_obligation       record;
  v_allocated        bigint;
  v_metadata         jsonb;
  v_note             text;
BEGIN
  -- Auth + arg validation
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'record_settlement_v2: auth required' USING errcode = '42501';
  END IF;
  IF p_group_id IS NULL THEN
    RAISE EXCEPTION 'record_settlement_v2: group_id required' USING errcode = '22023';
  END IF;
  IF p_from_member_id IS NULL OR p_to_member_id IS NULL THEN
    RAISE EXCEPTION 'record_settlement_v2: from_member_id and to_member_id required' USING errcode = '22023';
  END IF;
  IF p_from_member_id = p_to_member_id THEN
    RAISE EXCEPTION 'record_settlement_v2: from and to members must differ' USING errcode = '22023';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    RAISE EXCEPTION 'record_settlement_v2: amount must be positive' USING errcode = '22023';
  END IF;

  -- Idempotency pre-check (cheap short-circuit before any writes).
  IF p_client_id IS NOT NULL THEN
    SELECT * INTO v_existing
      FROM public.settlements
     WHERE group_id = p_group_id AND client_id = p_client_id
     LIMIT 1;
    IF v_existing.id IS NOT NULL THEN
      RETURN v_existing;
    END IF;
  END IF;

  -- Caller must be an active member of the group.
  SELECT gm.id INTO v_caller_member
    FROM public.group_members gm
   WHERE gm.group_id = p_group_id AND gm.user_id = v_uid AND gm.active
   LIMIT 1;
  IF v_caller_member IS NULL THEN
    RAISE EXCEPTION 'record_settlement_v2: caller not an active member of group'
      USING errcode = '42501';
  END IF;

  -- Both members must belong to the group. from must be active; to may
  -- be inactive (e.g. paying back someone who left).
  IF NOT EXISTS (
    SELECT 1 FROM public.group_members gm
     WHERE gm.id = p_from_member_id AND gm.group_id = p_group_id AND gm.active
  ) THEN
    RAISE EXCEPTION 'record_settlement_v2: from_member not active in group'
      USING errcode = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.group_members gm
     WHERE gm.id = p_to_member_id AND gm.group_id = p_group_id
  ) THEN
    RAISE EXCEPTION 'record_settlement_v2: to_member not in group'
      USING errcode = '22023';
  END IF;

  -- Optional resource scope must belong to the group.
  IF p_source_resource_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.resources r
       WHERE r.id = p_source_resource_id AND r.group_id = p_group_id
    ) THEN
      RAISE EXCEPTION 'record_settlement_v2: source_resource does not belong to group'
        USING errcode = '22023';
    END IF;
  END IF;

  -- Resolve currency.
  SELECT g.currency INTO v_group_currency FROM public.groups g WHERE g.id = p_group_id;
  v_currency := COALESCE(p_currency, v_group_currency, 'MXN');

  v_note := NULLIF(trim(coalesce(p_note, '')), '');

  -- Create the settlement row first (status='confirmed' in Phase 4.2;
  -- future versions may default to 'initiated' + add a confirm step).
  INSERT INTO public.settlements (
    group_id, from_member_id, to_member_id, amount_cents, currency,
    status, source_resource_id, note, client_id, recorded_by
  ) VALUES (
    p_group_id, p_from_member_id, p_to_member_id, p_amount_cents, v_currency,
    'confirmed', p_source_resource_id, v_note, p_client_id, v_uid
  )
  RETURNING * INTO v_settlement;

  -- FIFO allocate against open dyad obligations.
  v_remaining := p_amount_cents;

  FOR v_obligation IN
    SELECT o.id, o.amount_cents,
           COALESCE((SELECT SUM(so.amount_applied_cents)
                       FROM public.settlement_obligations so
                      WHERE so.obligation_id = o.id), 0)::bigint AS prior_applied
      FROM public.obligations o
     WHERE o.group_id = p_group_id
       AND o.owed_by_member_id = p_from_member_id
       AND o.owed_to_member_id = p_to_member_id
       AND o.status IN ('open', 'partially_paid')
     ORDER BY o.created_at ASC
     FOR UPDATE
  LOOP
    EXIT WHEN v_remaining <= 0;

    v_allocated := LEAST(v_remaining, v_obligation.amount_cents - v_obligation.prior_applied);

    IF v_allocated <= 0 THEN
      CONTINUE;
    END IF;

    INSERT INTO public.settlement_obligations (
      settlement_id, obligation_id, amount_applied_cents
    ) VALUES (
      v_settlement.id, v_obligation.id, v_allocated
    );

    IF (v_obligation.prior_applied + v_allocated) >= v_obligation.amount_cents THEN
      UPDATE public.obligations
         SET status = 'settled'
       WHERE id = v_obligation.id;
    ELSE
      UPDATE public.obligations
         SET status = 'partially_paid'
       WHERE id = v_obligation.id;
    END IF;

    v_remaining := v_remaining - v_allocated;
  END LOOP;

  -- Insert audit ledger entry. Note: we deliberately do NOT echo
  -- p_client_id into ledger.metadata (the ledger has its own partial
  -- unique index on metadata.client_id used by fund writers; sharing
  -- the same client_id across both surfaces could trip it). Instead we
  -- write settlement_id which is unique by construction.
  v_metadata := '{}'::jsonb || jsonb_build_object('settlement_id', v_settlement.id::text);
  IF v_note IS NOT NULL THEN
    v_metadata := v_metadata || jsonb_build_object('note', v_note);
  END IF;

  INSERT INTO public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by, source_resource_id
  ) VALUES (
    p_group_id, NULL, 'settlement', p_amount_cents, v_currency,
    p_from_member_id, p_to_member_id, v_metadata,
    now(), now(), v_uid, p_source_resource_id
  )
  RETURNING * INTO v_ledger;

  -- Link audit entry back to settlement.
  UPDATE public.settlements
     SET ledger_entry_id = v_ledger.id
   WHERE id = v_settlement.id
   RETURNING * INTO v_settlement;

  RETURN v_settlement;

EXCEPTION WHEN unique_violation THEN
  -- Idempotency race: a concurrent request inserted the same
  -- (group_id, client_id) settlement between our pre-check and INSERT.
  IF p_client_id IS NOT NULL THEN
    SELECT * INTO v_existing
      FROM public.settlements
     WHERE group_id = p_group_id AND client_id = p_client_id
     LIMIT 1;
    IF v_existing.id IS NOT NULL THEN
      RETURN v_existing;
    END IF;
  END IF;
  RAISE;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.record_settlement_v2(uuid, uuid, uuid, bigint, text, text, uuid, uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.record_settlement_v2(uuid, uuid, uuid, bigint, text, text, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.record_settlement_v2(uuid, uuid, uuid, bigint, text, text, uuid, uuid) IS
  'Money 2.0 Phase 4.2 (mig 20260526010500): canonical settlement writer. Creates a settlements row, FIFO-allocates against open obligations via settlement_obligations bridge, updates obligation status (settled/partially_paid), and inserts the audit ledger entry. Idempotent via (group_id, p_client_id). Over-allocation allowed (unallocated excess shows as credit in balance views until Phase 6 Wallet formalizes it).';
