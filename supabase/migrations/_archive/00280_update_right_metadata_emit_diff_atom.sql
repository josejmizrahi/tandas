-- 00280_update_right_metadata_emit_diff_atom.sql
--
-- Sprint 2.6 doctrinal fix per Plans/Active/ConsistencyAudit_2026-05-17.md
-- Finding F10: update_right_metadata writes silently — no atom emitted for
--   changes to transferable, expires_at, priority, exclusive,
--   target_resource_id, target_capability, scope, name, delegable, divisible,
--   source. These are normative knobs whose value can shape who can transfer,
--   when a right expires, what scope it applies to, etc. Their silent
--   mutation leaves no audit trail beyond resources.updated_at.
--
-- This migration:
-- - Whitelists new event_type `rightMetadataUpdated` in
--   is_known_system_event_type.
-- - Rewrites update_right_metadata to compute a real diff (only keys whose
--   new value IS DISTINCT FROM the current value land in the diff).
-- - Emits a single rightMetadataUpdated atom carrying the full diff payload
--   when there are real changes; emits nothing on a no-op patch.
-- - Preserves all existing validations (whitelist keys, scope enum,
--   target_resource_id same-group, non-negative priority, non-empty name).
-- - Preserves the existing permission gate (is_group_member). Tightening to
--   holder-or-admin is a separate concern outside the freeze plan; flagged
--   as a follow-up.
--
-- Atom payload shape:
--   {
--     updated_by: uuid,
--     diff: { <key>: { old: <prev>, new: <patched> }, ... }
--   }
--
-- This atom payload schema enables future right_config_view (derive knobs
-- from atoms) and audit replay. iOS / rule engine can subscribe to
-- rightMetadataUpdated to react to normative changes.

-- =============================================================================
-- 1) Whitelist rightMetadataUpdated.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.is_known_system_event_type(p_event_type text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT p_event_type = ANY (ARRAY[
    'eventClosed', 'eventCreated', 'rsvpDeadlinePassed', 'hoursBeforeEvent',
    'eventCancelled', 'eventStarted', 'eventUpdated',
    'rsvpSubmitted', 'rsvpChangedSameDay', 'checkInRecorded', 'checkInMissed',
    'eventDescriptionMissing',
    'slotAssigned', 'slotDeclined', 'slotExpired', 'slotSwapRequested', 'slotSwapApproved',
    'bookingCreated', 'bookingCancelled', 'bookingExpired',
    'bookingNoCheckIn',
    'assetCreated', 'assetTransferred', 'assetAssigned', 'assetReturned',
    'custodyAssigned', 'custodyReleased',
    'maintenanceLogged', 'maintenanceCompleted', 'damageReported',
    'assetUsed', 'assetCheckedOut', 'assetCheckedIn',
    'valuationRecorded',
    'assetCheckoutOverdue', 'assetMaintenanceOverdue',
    'fineOfficialized', 'fineVoided', 'finePaid', 'fineReminderSent',
    'appealCreated', 'appealResolved',
    'voteOpened', 'voteCast', 'voteResolved',
    'fundCreated', 'fundDeposit', 'fundThresholdReached',
    'fundLocked', 'fundUnlocked',
    'spaceCreated',
    'spaceBooked', 'spaceReleased', 'spaceCapacityReached',
    'spaceWaitlistJoined', 'spaceWaitlistPromoted',
    'spaceAccessGranted', 'spaceAccessRevoked',
    'positionChanged', 'memberJoined', 'memberLeft',
    'ruleEnabledChanged', 'ruleAmountChanged',
    'pendingChangeApplied', 'inviteCodeRotated',
    'groupCreated', 'groupArchived', 'groupUnarchived', 'groupRenamed', 'governanceUpdated',
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    'ledgerEntryCreated', 'warningEmitted',
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    'rightExpiringSoon',
    'rightMetadataUpdated',
    'resourceLinked', 'resourceUnlinked',
    'roleAssigned', 'roleUnassigned'
  ]);
$$;

-- =============================================================================
-- 2) Rewrite update_right_metadata — emits diff atom, skips no-ops.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.update_right_metadata(
  p_right_id uuid,
  p_patch    jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id    uuid := auth.uid();
  v_group_id     uuid;
  v_metadata     jsonb;
  v_patch_key    text;
  v_allowed_keys text[] := array[
    'name', 'priority', 'exclusive', 'transferable', 'delegable',
    'divisible', 'expires_at', 'source', 'target_resource_id',
    'target_capability', 'scope'
  ];
  v_clean_patch  jsonb := '{}'::jsonb;
  v_target_grp   uuid;
  v_new_scope    text;
  v_diff         jsonb := '{}'::jsonb;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT r.group_id, r.metadata
    INTO v_group_id, v_metadata
    FROM public.resources r
   WHERE r.id = p_right_id
     AND r.resource_type = 'right'
     AND r.archived_at IS NULL;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'right % not found or archived', p_right_id USING errcode = '22023';
  END IF;

  -- TODO follow-up (out of freeze scope): tighten gate to holder-or-admin to
  -- match Right Rules doctrine §1 ("normative changes are admin-or-holder").
  -- Today: any group member can patch knobs but the atom records who.
  IF NOT public.is_group_member(v_group_id, v_caller_id) THEN
    RAISE EXCEPTION 'not a member of this group' USING errcode = '42501';
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'patch must be a jsonb object' USING errcode = '22023';
  END IF;

  FOR v_patch_key IN SELECT * FROM jsonb_object_keys(p_patch) LOOP
    IF NOT (v_patch_key = ANY (v_allowed_keys)) THEN
      RAISE EXCEPTION 'key % cannot be updated via update_right_metadata; use the matching lifecycle RPC',
        v_patch_key USING errcode = '42501';
    END IF;

    IF v_patch_key = 'scope' THEN
      v_new_scope := p_patch->>'scope';
      IF v_new_scope IS NOT NULL AND v_new_scope NOT IN ('group','resource','occurrence') THEN
        RAISE EXCEPTION 'invalid scope %: must be group|resource|occurrence', v_new_scope
          USING errcode = '22023';
      END IF;
    END IF;

    IF v_patch_key = 'target_resource_id' THEN
      IF jsonb_typeof(p_patch->'target_resource_id') = 'string' THEN
        SELECT r.group_id INTO v_target_grp
          FROM public.resources r
         WHERE r.id = (p_patch->>'target_resource_id')::uuid;
        IF v_target_grp IS NULL THEN
          RAISE EXCEPTION 'target_resource_id not found' USING errcode = '22023';
        END IF;
        IF v_target_grp <> v_group_id THEN
          RAISE EXCEPTION 'target_resource_id belongs to a different group'
            USING errcode = '22023';
        END IF;
      END IF;
    END IF;

    IF v_patch_key = 'priority' THEN
      IF jsonb_typeof(p_patch->'priority') = 'number'
         AND (p_patch->>'priority')::int < 0
      THEN
        RAISE EXCEPTION 'priority must be non-negative' USING errcode = '22023';
      END IF;
    END IF;

    IF v_patch_key = 'name' THEN
      IF jsonb_typeof(p_patch->'name') <> 'string'
         OR length(trim(p_patch->>'name')) = 0
      THEN
        RAISE EXCEPTION 'name must be a non-empty string' USING errcode = '22023';
      END IF;
    END IF;

    v_clean_patch := v_clean_patch || jsonb_build_object(v_patch_key, p_patch->v_patch_key);
  END LOOP;

  IF v_clean_patch = '{}'::jsonb THEN
    RETURN;
  END IF;

  -- Build diff: include only keys whose value actually changes.
  FOR v_patch_key IN SELECT * FROM jsonb_object_keys(v_clean_patch) LOOP
    IF (v_metadata->v_patch_key) IS DISTINCT FROM (v_clean_patch->v_patch_key) THEN
      v_diff := v_diff || jsonb_build_object(
        v_patch_key,
        jsonb_build_object(
          'old', COALESCE(v_metadata->v_patch_key, 'null'::jsonb),
          'new', v_clean_patch->v_patch_key
        )
      );
    END IF;
  END LOOP;

  IF v_diff = '{}'::jsonb THEN
    -- No real changes; do not write, do not emit atom.
    RETURN;
  END IF;

  -- Apply metadata patch (operational cache for fast reads).
  UPDATE public.resources
     SET metadata = metadata || v_clean_patch
   WHERE id = p_right_id;

  -- Emit audit atom carrying the diff.
  PERFORM public.record_system_event(
    v_group_id,
    'rightMetadataUpdated',
    p_right_id,
    NULL,
    jsonb_build_object(
      'updated_by', v_caller_id,
      'diff',       v_diff
    )
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.update_right_metadata(uuid, jsonb)  FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.update_right_metadata(uuid, jsonb)  TO authenticated;

COMMENT ON FUNCTION public.update_right_metadata(uuid, jsonb) IS
  'Sprint 2.6 (mig 00280) per ConsistencyAudit F10. Emits rightMetadataUpdated atom carrying {updated_by, diff: {key: {old, new}}} when knob values actually change. No-op patches emit nothing. Preserves whitelist + validations + (legacy) is_group_member gate. Follow-up: tighten gate to holder-or-admin per Right Rules doctrine §1.';
