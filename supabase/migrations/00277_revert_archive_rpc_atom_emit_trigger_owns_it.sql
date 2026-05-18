-- 00277_revert_archive_rpc_atom_emit_trigger_owns_it.sql
--
-- Reverts mig 00276 (archive_resource/unarchive_resource emit atoms).
--
-- Why: mig 00276 was based on Finding F7 of Plans/Active/ConsistencyAudit_2026-05-17.md
-- which claimed "archive_resource muta sin emitir atom". That diagnosis was
-- incorrect — the audit agent grepped the RPC source and did not inspect
-- triggers. The pre-existing trigger `on_resource_archive_toggle` (function
-- `handle_resource_archive_toggle`) already emits resourceArchived /
-- resourceUnarchived atoms on UPDATE OF archived_at. Mig 00276 added a SECOND
-- emit from the RPC, producing duplicate atoms (verified empirically: a single
-- archive_resource call produced 2 resourceArchived rows in system_events).
--
-- Doctrinal posture: trigger-based atom emit is acceptable IF the trigger fires
-- atomically with the state change (same transaction, AFTER UPDATE). State
-- and atom commit together; replays from atoms remain correct because the
-- atom exists iff the state change committed. Per Axiom 1 ("Act > State"),
-- atom-after-trigger is doctrinally indistinguishable from atom-first-in-RPC
-- as long as they're atomic.
--
-- This migration restores archive_resource / unarchive_resource to their
-- pre-00276 bodies (idempotency via UPDATE filter; original asymmetry where
-- unarchive raises on already-unarchived).
--
-- Follow-up: update Plans/Active/ConsistencyAudit_2026-05-17.md to mark F7
-- as MISDIAGNOSED (status: CLEAN, atom emit via trigger). Already covered by
-- mig 00180-ish-era trigger; no doctrinal fix needed.

CREATE OR REPLACE FUNCTION public.archive_resource(p_resource_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_group_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING errcode = 'insufficient_privilege';
  END IF;

  SELECT group_id INTO v_group_id
    FROM public.resources
   WHERE id = p_resource_id;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = 'check_violation';
  END IF;

  IF NOT public.is_group_admin(v_group_id, v_uid) THEN
    RAISE EXCEPTION 'caller is not a group admin' USING errcode = 'insufficient_privilege';
  END IF;

  UPDATE public.resources
     SET archived_at = now(),
         archived_by = v_uid,
         updated_at  = now()
   WHERE id = p_resource_id
     AND archived_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.unarchive_resource(p_resource_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid         uuid := auth.uid();
  v_archived_by uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING errcode = 'insufficient_privilege';
  END IF;

  SELECT archived_by INTO v_archived_by
    FROM public.resources
   WHERE id = p_resource_id
   FOR UPDATE;

  IF v_archived_by IS NULL THEN
    RAISE EXCEPTION 'resource is not archived' USING errcode = 'check_violation';
  END IF;
  IF v_archived_by <> v_uid THEN
    RAISE EXCEPTION 'only the actor who archived can restore'
      USING errcode = 'insufficient_privilege';
  END IF;

  UPDATE public.resources
     SET archived_at = NULL,
         archived_by = NULL,
         updated_at  = now()
   WHERE id = p_resource_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.archive_resource(uuid)    FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.archive_resource(uuid)    TO authenticated;
REVOKE EXECUTE ON FUNCTION public.unarchive_resource(uuid)  FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.unarchive_resource(uuid)  TO authenticated;

COMMENT ON FUNCTION public.archive_resource(uuid) IS
  'Reverted to pre-mig-00276 body by mig 00277. Atom emission lives in trigger on_resource_archive_toggle → handle_resource_archive_toggle. F7 was misdiagnosed; no doctrinal fix needed.';

COMMENT ON FUNCTION public.unarchive_resource(uuid) IS
  'Reverted to pre-mig-00276 body by mig 00277. Atom emission lives in trigger on_resource_archive_toggle. Restricted to the original archiver.';
