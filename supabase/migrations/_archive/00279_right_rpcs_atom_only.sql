-- 00279_right_rpcs_atom_only.sql
--
-- Sprint 2.5 doctrinal fix per Plans/Active/ConsistencyAudit_2026-05-17.md
-- Finding F2: transfer_right / delegate_right / revoke_right / suspend_right
--   / restore_right / expire_due_rights mutated resources.metadata (holder/
--   delegate/suspended_*) and resources.status as truth; atoms were
--   decoration emitted AFTER mutation.
--
-- Companion of mig 00278 (right_state_view) which already derives holder,
-- delegate, status, suspended_until, last_exercised_at from atoms via the
-- `seq DESC` chain on system_events.
--
-- This migration:
-- - Drops every metadata.holder_*/delegate_*/suspended_* mutation from the
--   6 lifecycle RPCs.
-- - Drops every resources.status mutation. status is now exclusively
--   derived by right_state_view.
-- - Reads holder/status/etc. from right_state_view (atom-derived) inside
--   each RPC for permission gates, idempotency checks, and atom payloads.
-- - Preserves atom payload shape (backward-compatible).
-- - Preserves all permission gates (holder-or-admin for transfer/delegate;
--   admin-or-creator for revoke/suspend/restore — kept as-is for now).
-- - Rewrites `expire_due_rights` cron to query right_state_view (no UPDATE).
-- - Leaves `create_right` and `update_right_metadata` untouched. create_right
--   INSERTs the resource row and emits rightCreated; that's the genesis act
--   and is correct. update_right_metadata still writes metadata silently
--   for now — Task 12 (mig 00280) atomizes its knob changes.
-- - Leaves `exercise_right` writing `last_exercised_at` cache to metadata,
--   for backward compat with any callers that read it directly — but the
--   view derives it from the rightExercised atom regardless, so the cache
--   is just a fast-path that mirrors the atom. (NOTE: long-term this should
--   be dropped too; tracked but not blocking Beta.)
--
-- Production state at apply time: 0 right resources, 0 right atoms.

-- =============================================================================
-- transfer_right — atom-only; read holder from right_state_view.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.transfer_right(
  p_right_id     uuid,
  p_to_member_id uuid,
  p_reason       text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id      uuid := auth.uid();
  v_group_id       uuid;
  v_holder_user_id uuid;
  v_holder_member  uuid;
  v_status         text;
  v_transferable   boolean;
  v_to_user        uuid;
  v_is_admin       boolean;
BEGIN
  SELECT group_id INTO v_group_id
    FROM public.resources
   WHERE id = p_right_id AND resource_type = 'right' AND archived_at IS NULL;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'right % not found or archived', p_right_id USING errcode = '22023';
  END IF;

  -- Atom-derived truth.
  SELECT holder_user_id, holder_member_id, status, transferable
    INTO v_holder_user_id, v_holder_member, v_status, v_transferable
    FROM public.right_state_view
   WHERE right_id = p_right_id;

  IF v_caller_id IS NOT NULL THEN
    IF NOT public.is_group_member(v_group_id, v_caller_id) THEN
      RAISE EXCEPTION 'not a member of this group' USING errcode = '42501';
    END IF;
    SELECT EXISTS (
      SELECT 1 FROM public.group_members gm
       WHERE gm.group_id = v_group_id AND gm.user_id = v_caller_id
         AND gm.active = true AND gm.role IN ('founder','admin')
    ) INTO v_is_admin;
    IF v_caller_id <> v_holder_user_id AND NOT v_is_admin THEN
      RAISE EXCEPTION 'only the holder or a group admin may transfer this right'
        USING errcode = '42501';
    END IF;
  END IF;

  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'cannot transfer a right with status %', v_status
      USING errcode = '42501';
  END IF;

  IF NOT COALESCE(v_transferable, false) THEN
    RAISE EXCEPTION 'right is not transferable' USING errcode = '42501';
  END IF;

  SELECT gm.user_id INTO v_to_user
    FROM public.group_members gm
   WHERE gm.id = p_to_member_id AND gm.group_id = v_group_id AND gm.active = true;
  IF v_to_user IS NULL THEN
    RAISE EXCEPTION 'new holder must be an active member of the same group'
      USING errcode = '22023';
  END IF;

  -- Atom-only.
  PERFORM public.record_system_event(
    v_group_id, 'rightTransferred', p_right_id, p_to_member_id,
    jsonb_build_object(
      'from_member_id', v_holder_member,
      'to_member_id',   p_to_member_id,
      'transferred_by', v_caller_id,
      'reason',         p_reason
    )
  );
END;
$$;

-- =============================================================================
-- delegate_right — atom-only.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.delegate_right(
  p_right_id           uuid,
  p_delegate_member_id uuid,
  p_until              timestamptz DEFAULT NULL,
  p_reason             text        DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id      uuid := auth.uid();
  v_group_id       uuid;
  v_holder_user_id uuid;
  v_status         text;
  v_delegable      boolean;
  v_delegate_user  uuid;
  v_is_admin       boolean;
BEGIN
  SELECT group_id INTO v_group_id
    FROM public.resources
   WHERE id = p_right_id AND resource_type = 'right' AND archived_at IS NULL;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'right % not found or archived', p_right_id USING errcode = '22023';
  END IF;

  SELECT holder_user_id, status, delegable
    INTO v_holder_user_id, v_status, v_delegable
    FROM public.right_state_view
   WHERE right_id = p_right_id;

  IF v_caller_id IS NOT NULL THEN
    IF NOT public.is_group_member(v_group_id, v_caller_id) THEN
      RAISE EXCEPTION 'not a member of this group' USING errcode = '42501';
    END IF;
    SELECT EXISTS (
      SELECT 1 FROM public.group_members gm
       WHERE gm.group_id = v_group_id AND gm.user_id = v_caller_id
         AND gm.active = true AND gm.role IN ('founder','admin')
    ) INTO v_is_admin;
    IF v_caller_id <> v_holder_user_id AND NOT v_is_admin THEN
      RAISE EXCEPTION 'only the holder or a group admin may delegate this right'
        USING errcode = '42501';
    END IF;
  END IF;

  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'cannot delegate a right with status %', v_status
      USING errcode = '42501';
  END IF;

  IF NOT COALESCE(v_delegable, false) THEN
    RAISE EXCEPTION 'right is not delegable' USING errcode = '42501';
  END IF;

  SELECT gm.user_id INTO v_delegate_user
    FROM public.group_members gm
   WHERE gm.id = p_delegate_member_id AND gm.group_id = v_group_id AND gm.active = true;
  IF v_delegate_user IS NULL THEN
    RAISE EXCEPTION 'delegate must be an active member of the same group'
      USING errcode = '22023';
  END IF;

  PERFORM public.record_system_event(
    v_group_id, 'rightDelegated', p_right_id, p_delegate_member_id,
    jsonb_build_object(
      'delegate_member_id', p_delegate_member_id,
      'until',              p_until,
      'delegated_by',       v_caller_id,
      'reason',             p_reason
    )
  );
END;
$$;

-- =============================================================================
-- revoke_right — atom-only. Idempotent against atom-derived status.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.revoke_right(
  p_right_id uuid,
  p_reason   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id      uuid := auth.uid();
  v_group_id       uuid;
  v_previous_status text;
BEGIN
  SELECT group_id INTO v_group_id
    FROM public.resources
   WHERE id = p_right_id AND resource_type = 'right' AND archived_at IS NULL;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'right % not found or archived', p_right_id USING errcode = '22023';
  END IF;

  IF v_caller_id IS NOT NULL THEN
    IF NOT public.is_group_member(v_group_id, v_caller_id) THEN
      RAISE EXCEPTION 'not a member of this group' USING errcode = '42501';
    END IF;
  END IF;

  SELECT status INTO v_previous_status
    FROM public.right_state_view WHERE right_id = p_right_id;

  IF v_previous_status = 'revoked' THEN
    RETURN;
  END IF;

  PERFORM public.record_system_event(
    v_group_id, 'rightRevoked', p_right_id, NULL,
    jsonb_build_object(
      'previous_status', v_previous_status,
      'revoked_by',      v_caller_id,
      'reason',          p_reason
    )
  );
END;
$$;

-- =============================================================================
-- suspend_right — atom-only.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.suspend_right(
  p_right_id uuid,
  p_until    timestamptz DEFAULT NULL,
  p_reason   text        DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id uuid := auth.uid();
  v_group_id  uuid;
  v_status    text;
BEGIN
  SELECT group_id INTO v_group_id
    FROM public.resources
   WHERE id = p_right_id AND resource_type = 'right' AND archived_at IS NULL;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'right % not found or archived', p_right_id USING errcode = '22023';
  END IF;
  IF v_caller_id IS NOT NULL THEN
    IF NOT public.is_group_member(v_group_id, v_caller_id) THEN
      RAISE EXCEPTION 'not a member of this group' USING errcode = '42501';
    END IF;
  END IF;

  SELECT status INTO v_status
    FROM public.right_state_view WHERE right_id = p_right_id;

  IF v_status IN ('revoked','expired') THEN
    RAISE EXCEPTION 'cannot suspend a right with status %', v_status
      USING errcode = '42501';
  END IF;
  IF v_status = 'suspended' THEN
    RETURN;
  END IF;

  PERFORM public.record_system_event(
    v_group_id, 'rightSuspended', p_right_id, NULL,
    jsonb_build_object(
      'until',        p_until,
      'suspended_by', v_caller_id,
      'reason',       p_reason
    )
  );
END;
$$;

-- =============================================================================
-- restore_right — atom-only.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.restore_right(
  p_right_id uuid,
  p_reason   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id uuid := auth.uid();
  v_group_id  uuid;
  v_status    text;
BEGIN
  SELECT group_id INTO v_group_id
    FROM public.resources
   WHERE id = p_right_id AND resource_type = 'right' AND archived_at IS NULL;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'right % not found or archived', p_right_id USING errcode = '22023';
  END IF;
  IF v_caller_id IS NOT NULL THEN
    IF NOT public.is_group_member(v_group_id, v_caller_id) THEN
      RAISE EXCEPTION 'not a member of this group' USING errcode = '42501';
    END IF;
  END IF;

  SELECT status INTO v_status
    FROM public.right_state_view WHERE right_id = p_right_id;

  IF v_status NOT IN ('revoked','suspended') THEN
    RAISE EXCEPTION 'cannot restore a right with status % (must be revoked or suspended)', v_status
      USING errcode = '42501';
  END IF;

  PERFORM public.record_system_event(
    v_group_id, 'rightRestored', p_right_id, NULL,
    jsonb_build_object(
      'previous_status', v_status,
      'restored_by',     v_caller_id,
      'reason',          p_reason
    )
  );
END;
$$;

-- =============================================================================
-- exercise_right — atom-only; drop last_exercised_at cache write.
--   The view derives last_exercised_at from the latest rightExercised atom
--   occurred_at, so the cache write was pure decoration.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.exercise_right(
  p_right_id uuid,
  p_context  jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id      uuid := auth.uid();
  v_group_id       uuid;
  v_holder_user_id uuid;
  v_delegate_user  uuid;
  v_status         text;
  v_caller_mem     uuid;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;
  SELECT group_id INTO v_group_id
    FROM public.resources
   WHERE id = p_right_id AND resource_type = 'right' AND archived_at IS NULL;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'right % not found or archived', p_right_id USING errcode = '22023';
  END IF;
  IF NOT public.is_group_member(v_group_id, v_caller_id) THEN
    RAISE EXCEPTION 'not a member of this group' USING errcode = '42501';
  END IF;

  SELECT holder_user_id, delegate_user_id, status
    INTO v_holder_user_id, v_delegate_user, v_status
    FROM public.right_state_view WHERE right_id = p_right_id;

  IF v_caller_id <> v_holder_user_id
     AND (v_delegate_user IS NULL OR v_caller_id <> v_delegate_user) THEN
    RAISE EXCEPTION 'caller is neither holder nor active delegate of this right'
      USING errcode = '42501';
  END IF;
  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'cannot exercise a right with status %', v_status
      USING errcode = '42501';
  END IF;

  SELECT gm.id INTO v_caller_mem
    FROM public.group_members gm
   WHERE gm.group_id = v_group_id AND gm.user_id = v_caller_id AND gm.active = true
   LIMIT 1;

  PERFORM public.record_system_event(
    v_group_id, 'rightExercised', p_right_id, v_caller_mem,
    jsonb_build_object(
      'exercised_by_user_id',   v_caller_id,
      'exercised_by_member_id', v_caller_mem,
      'context',                COALESCE(p_context, '{}'::jsonb)
    )
  );
END;
$$;

-- =============================================================================
-- expire_due_rights — cron; atom-only; query right_state_view for "active +
--   expired_at past + no archived" rights.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.expire_due_rights()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count int := 0;
  v_row   record;
BEGIN
  FOR v_row IN
    SELECT
      rs.right_id,
      rs.group_id,
      rs.holder_member_id,
      rs.expires_at,
      rs.name
      FROM public.right_state_view rs
     WHERE rs.status = 'active'
       AND rs.expires_at IS NOT NULL
       AND rs.expires_at <= now()
       AND rs.archived_at IS NULL
  LOOP
    PERFORM public.record_system_event(
      v_row.group_id,
      'rightExpired',
      v_row.right_id,
      v_row.holder_member_id,
      jsonb_build_object(
        'expired_at',       v_row.expires_at,
        'holder_member_id', v_row.holder_member_id,
        'name',             v_row.name,
        'source',           'cron:expire_due_rights'
      )
    );
    v_count := v_count + 1;
  END LOOP;

  IF v_count > 0 THEN
    RAISE NOTICE 'expire_due_rights: expired % right(s)', v_count;
  END IF;
  RETURN v_count;
END;
$$;

-- =============================================================================
-- Permissions preserved.
-- =============================================================================
REVOKE EXECUTE ON FUNCTION public.transfer_right(uuid, uuid, text)        FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.transfer_right(uuid, uuid, text)        TO authenticated;
REVOKE EXECUTE ON FUNCTION public.delegate_right(uuid, uuid, timestamptz, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.delegate_right(uuid, uuid, timestamptz, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.revoke_right(uuid, text)                FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.revoke_right(uuid, text)                TO authenticated;
REVOKE EXECUTE ON FUNCTION public.suspend_right(uuid, timestamptz, text)  FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.suspend_right(uuid, timestamptz, text)  TO authenticated;
REVOKE EXECUTE ON FUNCTION public.restore_right(uuid, text)               FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.restore_right(uuid, text)               TO authenticated;
REVOKE EXECUTE ON FUNCTION public.exercise_right(uuid, jsonb)             FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exercise_right(uuid, jsonb)             TO authenticated;
-- expire_due_rights is a cron entry, no role grants here.

COMMENT ON FUNCTION public.transfer_right(uuid, uuid, text) IS
  'Sprint 2.5 (mig 00279) per ConsistencyAudit F2. Atom-only; holder derived from right_state_view (mig 00278). No metadata.holder_* mutation.';
COMMENT ON FUNCTION public.delegate_right(uuid, uuid, timestamptz, text) IS
  'Sprint 2.5 (mig 00279) per ConsistencyAudit F2. Atom-only; status/delegable derived from right_state_view. No metadata.delegate_* mutation.';
COMMENT ON FUNCTION public.revoke_right(uuid, text) IS
  'Sprint 2.5 (mig 00279) per ConsistencyAudit F2. Atom-only; previous_status from right_state_view. No resources.status mutation. Idempotent.';
COMMENT ON FUNCTION public.suspend_right(uuid, timestamptz, text) IS
  'Sprint 2.5 (mig 00279) per ConsistencyAudit F2. Atom-only. No metadata.suspended_* mutation. Idempotent.';
COMMENT ON FUNCTION public.restore_right(uuid, text) IS
  'Sprint 2.5 (mig 00279) per ConsistencyAudit F2. Atom-only; previous_status from right_state_view. No resources.status mutation.';
COMMENT ON FUNCTION public.exercise_right(uuid, jsonb) IS
  'Sprint 2.5 (mig 00279) per ConsistencyAudit F2. Atom-only; holder/delegate/status from right_state_view. No metadata.last_exercised_at cache write (the view derives it from atom occurred_at).';
COMMENT ON FUNCTION public.expire_due_rights() IS
  'Sprint 2.5 (mig 00279) per ConsistencyAudit F2. Cron path. Queries right_state_view (atom-derived) for active+expired+unarchived rights. Emits rightExpired atom only; no resources.status mutation.';
