-- 00285_post_beta_p3_p6_p9_hardening.sql
--
-- Post-Beta safe hardening bundle per Plans/Active/ConsistencyAudit_2026-05-17.md §6.B:
--
-- P3: rule_versions.status guard tighten (closes F14).
--     The existing guard (mig 00181) error message promises
--     "active->superseded/inactive only" but the code accepts ANY status
--     mutation. Tighten to enforce the documented transition:
--       - status unchanged: allow (for effective_until-only updates).
--       - status='active' -> status in ('superseded','inactive'): allow.
--       - any other transition: reject.
--
-- P6: record_ledger_entry internal whitelist sync (closes F11).
--     Live whitelist had 9 types; ledger_entries_type_canonical CHECK
--     constraint (mig 00167) lists 11. Missing: 'payment', 'transfer'.
--     Without the sync, any future emitter that calls record_ledger_entry
--     with one of those types would raise "invalid ledger entry type" even
--     though the underlying INSERT would have succeeded.
--
-- P9: notifications_outbox partial atom guard.
--     The dispatcher legitimately updates dispatched_at + dispatch_status +
--     dispatch_error. Everything else (group_id, recipient_member_id,
--     notification_type, payload, deep_link, scheduled_for, created_at)
--     is set-at-insert and must remain immutable. Adds a partial guard
--     that rejects:
--       - any DELETE
--       - any UPDATE that mutates non-dispatcher columns
--       - any UPDATE to dispatched_at after it's already set (set-once)
--
-- Production state at apply time: 0 fines / 0 stale ledger rows / 0
-- problematic notifications_outbox rows expected — greenfield-safe.

-- =============================================================================
-- P3 — rule_versions guard tighten
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rule_versions_atom_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'rule_versions is append-only. DELETE not allowed.'
      USING errcode = 'check_violation';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- Immutable columns (unchanged from mig 00181).
    IF OLD.id                  IS DISTINCT FROM NEW.id                  OR
       OLD.rule_id             IS DISTINCT FROM NEW.rule_id             OR
       OLD.version             IS DISTINCT FROM NEW.version             OR
       OLD.template_id         IS DISTINCT FROM NEW.template_id         OR
       OLD.shape_params        IS DISTINCT FROM NEW.shape_params        OR
       OLD.compiled            IS DISTINCT FROM NEW.compiled            OR
       OLD.effective_from      IS DISTINCT FROM NEW.effective_from      OR
       OLD.previous_version_id IS DISTINCT FROM NEW.previous_version_id OR
       OLD.created_by          IS DISTINCT FROM NEW.created_by          OR
       OLD.change_reason       IS DISTINCT FROM NEW.change_reason       OR
       OLD.created_at          IS DISTINCT FROM NEW.created_at THEN
      RAISE EXCEPTION 'rule_versions is append-only. Only effective_until and status (active->superseded/inactive) may be updated.'
        USING errcode = 'check_violation';
    END IF;

    -- Tightened in mig 00285: status transitions are now constrained.
    -- Allowed:
    --   - unchanged (NEW.status = OLD.status) — pure effective_until updates.
    --   - active -> superseded
    --   - active -> inactive
    -- Anything else (e.g. superseded -> active, inactive -> active,
    -- superseded -> inactive) is rejected.
    IF NEW.status IS DISTINCT FROM OLD.status THEN
      IF NOT (
        OLD.status = 'active' AND NEW.status IN ('superseded', 'inactive')
      ) THEN
        RAISE EXCEPTION
          'rule_versions.status: only active->superseded/inactive transitions allowed (was %, attempted %)',
          OLD.status, NEW.status
          USING errcode = 'check_violation';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.rule_versions_atom_guard() IS
  'P3 (mig 00285) per ConsistencyAudit F14. Tightens status mutation to only allow active->superseded or active->inactive. effective_until still freely mutable. All other columns frozen post-insert.';

-- =============================================================================
-- P6 — record_ledger_entry whitelist sync to 11 canonical types (mig 00167)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.record_ledger_entry(
  p_group_id       uuid,
  p_resource_id    uuid  DEFAULT NULL::uuid,
  p_type           text  DEFAULT NULL::text,
  p_amount_cents   bigint DEFAULT NULL::bigint,
  p_from_member_id uuid  DEFAULT NULL::uuid,
  p_to_member_id   uuid  DEFAULT NULL::uuid,
  p_currency       text  DEFAULT 'MXN'::text,
  p_metadata       jsonb DEFAULT '{}'::jsonb
)
RETURNS public.ledger_entries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry public.ledger_entries;
  -- Synced with ledger_entries_type_canonical CHECK constraint (mig 00167).
  -- All 11 canonical types are accepted; the database-level CHECK enforces
  -- the same list on insert, so a stale list here only manifested as a
  -- spurious RPC-level rejection.
  v_allowed_types constant text[] := array[
    'expense', 'contribution',
    'payout', 'settlement', 'reimbursement',
    'payment', 'transfer',
    'fine_issued', 'fine_paid', 'fine_voided', 'fine_officialized'
  ];
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  IF NOT public.is_group_member(p_group_id, auth.uid()) THEN
    RAISE EXCEPTION 'not a member of this group';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents < 0 THEN
    RAISE EXCEPTION 'amount must be non-negative';
  END IF;
  IF p_type IS NULL OR NOT (p_type = ANY (v_allowed_types)) THEN
    RAISE EXCEPTION 'invalid ledger entry type: %', p_type;
  END IF;
  IF p_resource_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.resources r
       WHERE r.id = p_resource_id AND r.group_id = p_group_id
    ) THEN
      RAISE EXCEPTION 'resource does not belong to group';
    END IF;
  END IF;
  IF p_from_member_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.group_members gm
       WHERE gm.id = p_from_member_id AND gm.group_id = p_group_id AND gm.active
    ) THEN
      RAISE EXCEPTION 'from_member is not an active member of this group';
    END IF;
  END IF;
  IF p_to_member_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.group_members gm
       WHERE gm.id = p_to_member_id AND gm.group_id = p_group_id AND gm.active
    ) THEN
      RAISE EXCEPTION 'to_member is not an active member of this group';
    END IF;
  END IF;

  INSERT INTO public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by
  )
  VALUES (
    p_group_id, p_resource_id, p_type, p_amount_cents, COALESCE(p_currency, 'MXN'),
    p_from_member_id, p_to_member_id, COALESCE(p_metadata, '{}'::jsonb),
    now(), now(), auth.uid()
  )
  RETURNING * INTO v_entry;

  RETURN v_entry;
END;
$$;

COMMENT ON FUNCTION public.record_ledger_entry(uuid, uuid, text, bigint, uuid, uuid, text, jsonb) IS
  'P6 (mig 00285) per ConsistencyAudit F11. Internal whitelist synced to 11 canonical types (was 9; missing payment + transfer). Matches ledger_entries_type_canonical CHECK constraint (mig 00167).';

-- =============================================================================
-- P9 — notifications_outbox partial guard
-- =============================================================================
CREATE OR REPLACE FUNCTION public.notifications_outbox_dispatcher_only_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_old_minus jsonb;
  v_new_minus jsonb;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION
      'notifications_outbox is append-only at the row level; DELETE rejected (id=%)',
      OLD.id
      USING errcode = 'check_violation';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- dispatched_at is set-once. Once stamped, no further updates.
    IF OLD.dispatched_at IS NOT NULL THEN
      RAISE EXCEPTION
        'notifications_outbox.dispatched_at is set-once; UPDATE rejected (id=%)',
        NEW.id
        USING errcode = 'check_violation';
    END IF;

    -- Strip the dispatcher-mutable fields from both sides; remainder must
    -- be byte-identical. Pattern lift from system_events_processed_at_only_guard.
    v_old_minus := ((to_jsonb(OLD) - 'dispatched_at') - 'dispatch_status') - 'dispatch_error';
    v_new_minus := ((to_jsonb(NEW) - 'dispatched_at') - 'dispatch_status') - 'dispatch_error';
    IF v_old_minus IS DISTINCT FROM v_new_minus THEN
      RAISE EXCEPTION
        'notifications_outbox: only dispatched_at/dispatch_status/dispatch_error may be mutated (id=%)',
        NEW.id
        USING errcode = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notifications_outbox_dispatcher_only_guard_trg
  ON public.notifications_outbox;

CREATE TRIGGER notifications_outbox_dispatcher_only_guard_trg
  BEFORE UPDATE OR DELETE ON public.notifications_outbox
  FOR EACH ROW EXECUTE FUNCTION public.notifications_outbox_dispatcher_only_guard();

COMMENT ON FUNCTION public.notifications_outbox_dispatcher_only_guard() IS
  'P9 (mig 00285) per ConsistencyAudit F13. Partial atom guard: rejects DELETE; UPDATE only of dispatched_at (null->ts set-once) + dispatch_status + dispatch_error. Recipient/payload/type/group/scheduled_for frozen post-insert so dispatch records cannot be tampered after the fact.';
