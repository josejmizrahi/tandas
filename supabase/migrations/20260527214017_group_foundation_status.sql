CREATE OR REPLACE FUNCTION public.group_foundation_status(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_active int; v_pending_invites int; v_purposes int; v_rules int; v_resources int;
  v_members_ok boolean; v_boundary_ok boolean; v_purpose_ok boolean; v_rules_ok boolean; v_resources_ok boolean;
  v_overall text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'must be authenticated' USING errcode = '42501'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships
     WHERE group_id = p_group_id AND user_id = v_uid AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id USING errcode = '42501';
  END IF;

  SELECT count(*) INTO v_active FROM public.group_memberships WHERE group_id = p_group_id AND status = 'active';
  SELECT count(*) INTO v_pending_invites FROM public.group_invites
   WHERE group_id = p_group_id AND status = 'pending' AND (expires_at IS NULL OR expires_at > now());
  SELECT count(*) INTO v_purposes FROM public.group_purposes WHERE group_id = p_group_id AND status = 'active';
  SELECT count(*) INTO v_rules FROM public.group_rules WHERE group_id = p_group_id AND status = 'active';
  SELECT count(*) INTO v_resources FROM public.group_resources
   WHERE group_id = p_group_id AND status = 'active'
     AND resource_type IN ('fund','space','asset','document','other');

  v_members_ok   := v_active >= 1;
  v_boundary_ok  := (v_active >= 2) OR (v_pending_invites >= 1);
  v_purpose_ok   := v_purposes >= 1;
  v_rules_ok     := v_rules >= 1;
  v_resources_ok := v_resources >= 1;
  v_overall := CASE WHEN v_members_ok AND v_boundary_ok AND v_purpose_ok AND v_rules_ok AND v_resources_ok
                    THEN 'ready' ELSE 'not_ready' END;

  RETURN jsonb_build_object(
    'group_id', p_group_id,
    'members', jsonb_build_object(
      'status', CASE WHEN v_members_ok THEN 'complete' ELSE 'incomplete' END,
      'active_count', v_active, 'required', 'at least one active member'),
    'boundary', jsonb_build_object(
      'status', CASE WHEN v_boundary_ok THEN 'complete' ELSE 'incomplete' END,
      'active_count', v_active, 'pending_invites_count', v_pending_invites,
      'required', 'at least one peer or pending invite'),
    'purpose', jsonb_build_object(
      'status', CASE WHEN v_purpose_ok THEN 'complete' ELSE 'incomplete' END,
      'active_count', v_purposes, 'required', 'at least one active purpose'),
    'rules', jsonb_build_object(
      'status', CASE WHEN v_rules_ok THEN 'complete' ELSE 'incomplete' END,
      'active_count', v_rules, 'required', 'at least one active rule'),
    'resources', jsonb_build_object(
      'status', CASE WHEN v_resources_ok THEN 'complete' ELSE 'incomplete' END,
      'active_count', v_resources, 'required', 'at least one active Foundation resource'),
    'overall_status', v_overall
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.group_foundation_status(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_foundation_status(uuid) TO authenticated;
COMMENT ON FUNCTION public.group_foundation_status(uuid) IS
  'Foundation Acceptance (mig 20260527050000): derives per-primitive completeness.';
