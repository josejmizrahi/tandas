-- 00276_archive_resource_emit_atoms.sql
--
-- Sprint 1.3 doctrinal fix per Plans/Active/ConsistencyAudit_2026-05-17.md
-- Finding F7: archive_resource/unarchive_resource muta resources.archived_at +
--   archived_by WITHOUT emitting resourceArchived/resourceUnarchived atoms
--   (despite both atom types being whitelisted via mig 00186/00209/00211/00258
--   and surfaced in SystemEventType.swift).
--
-- The archive lifecycle is the user-visible "delete" action across the entire
-- platform — events archived, funds archived, assets archived, etc. — and the
-- absence of an atom means there's no audit trail of who archived what, when,
-- or why. Replaying history cannot reconstruct the archive state.
--
-- Doctrine restored:
-- - Both RPCs emit their canonical atom BEFORE the UPDATE (atom-first).
-- - archived_at + archived_by remain on resources as operational cache
--   (acceptable per OperationalCacheDoctrine §1: atom-backed, RLS-protected,
--   recomputable post-fix). Audit trail lives in system_events.
-- - Idempotency preserved: archive on already-archived resource updates 0 rows
--   AND emits no atom (early return on archived_at IS NOT NULL).
-- - Permission semantics preserved: admin-only archive; only original archiver
--   may unarchive.

CREATE OR REPLACE FUNCTION public.archive_resource(p_resource_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid           uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
  v_already       timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING errcode = 'insufficient_privilege';
  END IF;

  SELECT group_id, resource_type, archived_at
    INTO v_group_id, v_resource_type, v_already
    FROM public.resources
   WHERE id = p_resource_id
   FOR UPDATE;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = 'check_violation';
  END IF;

  IF NOT public.is_group_admin(v_group_id, v_uid) THEN
    RAISE EXCEPTION 'caller is not a group admin' USING errcode = 'insufficient_privilege';
  END IF;

  -- Idempotent: already archived → return silently, no atom.
  IF v_already IS NOT NULL THEN
    RETURN;
  END IF;

  -- Atom first (doctrine: atoms are the verdadero record; cache is downstream).
  PERFORM public.record_system_event(
    v_group_id,
    'resourceArchived',
    p_resource_id,
    NULL,
    jsonb_build_object(
      'resource_type', v_resource_type,
      'archived_by',   v_uid
    )
  );

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
  v_uid               uuid := auth.uid();
  v_group_id          uuid;
  v_resource_type     text;
  v_archived_by       uuid;
  v_previous_archived timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING errcode = 'insufficient_privilege';
  END IF;

  SELECT group_id, resource_type, archived_by, archived_at
    INTO v_group_id, v_resource_type, v_archived_by, v_previous_archived
    FROM public.resources
   WHERE id = p_resource_id
   FOR UPDATE;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = 'check_violation';
  END IF;

  -- Idempotent: already unarchived → return silently, no atom.
  IF v_archived_by IS NULL OR v_previous_archived IS NULL THEN
    RETURN;
  END IF;

  -- Permission semantics preserved: only the original archiver may restore.
  IF v_archived_by <> v_uid THEN
    RAISE EXCEPTION 'only the actor who archived can restore'
      USING errcode = 'insufficient_privilege';
  END IF;

  -- Atom first.
  PERFORM public.record_system_event(
    v_group_id,
    'resourceUnarchived',
    p_resource_id,
    NULL,
    jsonb_build_object(
      'resource_type',         v_resource_type,
      'unarchived_by',         v_uid,
      'previous_archived_at',  v_previous_archived
    )
  );

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
  'Sprint 1.3 (mig 00276) per ConsistencyAudit F7. Emits resourceArchived atom before flipping archived_at. archived_at remains as operational cache (atom-backed per OperationalCacheDoctrine §5). Idempotent on already-archived rows.';

COMMENT ON FUNCTION public.unarchive_resource(uuid) IS
  'Sprint 1.3 (mig 00276) per ConsistencyAudit F7. Emits resourceUnarchived atom before clearing archived_at. Restricted to the original archiver. Idempotent on already-unarchived rows.';
