-- 20260527050000 — group_foundation_status: Foundation readiness check.
--
-- Foundation set (Primitivas 1-5) is now wired end-to-end. This
-- migration adds a single canonical RPC that derives a per-primitive
-- completeness status for a group from existing tables — no new
-- parallel source of truth.
--
-- Criterios:
--   members:   active_count >= 1
--   boundary:  active_count >= 2 OR pending_invites_count >= 1
--              (a group of one has no boundary decision yet; once
--               there's a peer or an outstanding invite, the
--               perimeter has been deliberately drawn)
--   purpose:   at least one row in group_purposes with status='active'
--   rules:     at least one row in group_rules with status='active'
--   resources: at least one row in group_resources with status='active'
--              AND resource_type in Foundation set (fund/space/asset/
--              document/other) — engine types filtered out so they
--              don't game the readiness score.
--
-- overall_status = 'ready' iff all five are complete.
--
-- Returns jsonb so the response can stay nested and forward-compatible
-- (new primitives slot in without changing the table column shape).

CREATE OR REPLACE FUNCTION public.group_foundation_status(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid              uuid := auth.uid();
  v_active           int;
  v_pending_invites  int;
  v_purposes         int;
  v_rules            int;
  v_resources        int;
  v_members_ok       boolean;
  v_boundary_ok      boolean;
  v_purpose_ok       boolean;
  v_rules_ok         boolean;
  v_resources_ok     boolean;
  v_overall          text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships
     WHERE group_id = p_group_id
       AND user_id  = v_uid
       AND status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  SELECT count(*) INTO v_active
    FROM public.group_memberships
   WHERE group_id = p_group_id AND status = 'active';

  SELECT count(*) INTO v_pending_invites
    FROM public.group_invites
   WHERE group_id = p_group_id
     AND status   = 'pending'
     AND (expires_at IS NULL OR expires_at > now());

  SELECT count(*) INTO v_purposes
    FROM public.group_purposes
   WHERE group_id = p_group_id AND status = 'active';

  SELECT count(*) INTO v_rules
    FROM public.group_rules
   WHERE group_id = p_group_id AND status = 'active';

  SELECT count(*) INTO v_resources
    FROM public.group_resources
   WHERE group_id = p_group_id
     AND status   = 'active'
     AND resource_type IN ('fund', 'space', 'asset', 'document', 'other');

  v_members_ok   := v_active >= 1;
  v_boundary_ok  := (v_active >= 2) OR (v_pending_invites >= 1);
  v_purpose_ok   := v_purposes >= 1;
  v_rules_ok     := v_rules >= 1;
  v_resources_ok := v_resources >= 1;

  v_overall := CASE
    WHEN v_members_ok AND v_boundary_ok AND v_purpose_ok AND v_rules_ok AND v_resources_ok
    THEN 'ready'
    ELSE 'not_ready'
  END;

  RETURN jsonb_build_object(
    'group_id', p_group_id,
    'members', jsonb_build_object(
      'status',       CASE WHEN v_members_ok THEN 'complete' ELSE 'incomplete' END,
      'active_count', v_active,
      'required',     'at least one active member'
    ),
    'boundary', jsonb_build_object(
      'status',                CASE WHEN v_boundary_ok THEN 'complete' ELSE 'incomplete' END,
      'active_count',          v_active,
      'pending_invites_count', v_pending_invites,
      'required',              'at least one peer or pending invite'
    ),
    'purpose', jsonb_build_object(
      'status',       CASE WHEN v_purpose_ok THEN 'complete' ELSE 'incomplete' END,
      'active_count', v_purposes,
      'required',     'at least one active purpose'
    ),
    'rules', jsonb_build_object(
      'status',       CASE WHEN v_rules_ok THEN 'complete' ELSE 'incomplete' END,
      'active_count', v_rules,
      'required',     'at least one active rule'
    ),
    'resources', jsonb_build_object(
      'status',       CASE WHEN v_resources_ok THEN 'complete' ELSE 'incomplete' END,
      'active_count', v_resources,
      'required',     'at least one active Foundation resource'
    ),
    'overall_status', v_overall
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_foundation_status(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_foundation_status(uuid) TO authenticated;

COMMENT ON FUNCTION public.group_foundation_status(uuid) IS
  'Foundation Acceptance (mig 20260527050000): derives per-primitive completeness (members/boundary/purpose/rules/resources) for a group from existing canonical tables. SECURITY DEFINER, active-member gate. Returns nested jsonb; overall_status = ready|not_ready.';
