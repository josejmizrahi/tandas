-- 00287_resource_links_atom_guard.sql
--
-- Closes ConsistencyAudit_2026-05-17 finding F12: resource_links lacks an
-- atom guard. Soft-unlink (UPDATE unlinked_at = now()) is intended per
-- doctrine, but pre-mig 00287 nothing physically prevented service_role or
-- a future generic update RPC from rewriting any column post-INSERT.
--
-- F6 RECLASSIFIED → CLEAN (misdiagnosed). The audit reported the kind
-- catalog as narrow ('uses' only). Verified live state at 2026-05-18:
-- the CHECK constraint (resource_links_link_kind_v1_check) accepts 8 kinds
-- (uses, funds, governs, located_in, scheduled_in, reserves,
-- grants_access_to, owns); a companion `resource_link_kinds` catalog table
-- holds 24 (kind, from_type, to_type) tuples enforced by
-- is_valid_resource_link(), which link_resources() invokes before INSERT.
-- 'grants_access_to' correctly requires from_type='right' (3 valid
-- targets: asset, slot, space). 'funds' requires from_type='fund'. The
-- audit's F6 description was based on a stale snapshot — no remediation
-- needed.
--
-- This migration:
-- - Adds resource_links_unlink_only_guard() partial trigger:
--     * DELETE → reject (preserves audit history).
--     * UPDATE allowed only when transitioning unlinked_at null→ts AND
--       unlinked_by null→uuid in the same UPDATE (the existing
--       unlinked_consistency_chk constraint enforces null-paired-with-null
--       state but doesn't prevent value-flips).
--     * Any other mutation rejected (group_id, from_resource_id,
--       to_resource_id, link_kind, linked_at, linked_by frozen).
--     * Re-set of already-stamped unlinked_at rejected (set-once).
-- - Pattern: lift from system_events_processed_at_only_guard (mig 00162)
--   and notifications_outbox_dispatcher_only_guard (mig 00285 P9).

CREATE OR REPLACE FUNCTION public.resource_links_unlink_only_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_old_minus jsonb;
  v_new_minus jsonb;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION
      'resource_links is soft-unlink only; DELETE rejected (id=%)',
      OLD.id
      USING errcode = 'check_violation';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- Set-once on unlinked_at.
    IF OLD.unlinked_at IS NOT NULL THEN
      RAISE EXCEPTION
        'resource_links.unlinked_at is set-once; UPDATE rejected (id=%)',
        NEW.id
        USING errcode = 'check_violation';
    END IF;

    -- The only legitimate transition is the unlink stamp (unlinked_at +
    -- unlinked_by go from NULL to set together). Strip those two columns
    -- from both sides; the remainder must be byte-identical.
    v_old_minus := (to_jsonb(OLD) - 'unlinked_at') - 'unlinked_by';
    v_new_minus := (to_jsonb(NEW) - 'unlinked_at') - 'unlinked_by';
    IF v_old_minus IS DISTINCT FROM v_new_minus THEN
      RAISE EXCEPTION
        'resource_links: only unlinked_at + unlinked_by may be mutated (null→set, paired); id=%',
        NEW.id
        USING errcode = 'check_violation';
    END IF;

    -- Sanity: if the unlink stamp is being applied, both must transition
    -- together. The existing resource_links_unlinked_consistency_chk
    -- already enforces "(unlinked_at IS NULL) = (unlinked_by IS NULL)" at
    -- row-state level, but we double-check the transition is null→set
    -- (not somehow set→null, which the chk also rejects but better to
    -- be explicit here).
    IF NEW.unlinked_at IS NOT NULL AND OLD.unlinked_at IS NULL THEN
      IF NEW.unlinked_by IS NULL THEN
        RAISE EXCEPTION
          'resource_links unlink: unlinked_by must be set when unlinked_at is set (id=%)',
          NEW.id
          USING errcode = 'check_violation';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS resource_links_unlink_only_guard_trg ON public.resource_links;

CREATE TRIGGER resource_links_unlink_only_guard_trg
  BEFORE UPDATE OR DELETE ON public.resource_links
  FOR EACH ROW EXECUTE FUNCTION public.resource_links_unlink_only_guard();

COMMENT ON FUNCTION public.resource_links_unlink_only_guard() IS
  'F12 (mig 00287) per ConsistencyAudit. Partial atom guard: rejects DELETE; UPDATE only of unlinked_at + unlinked_by (null→set, paired, set-once). All other columns frozen post-INSERT. Companion to soft-unlink doctrine in unlink_resources() RPC.';
