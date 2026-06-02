-- D.20.1: regression coverage for membership boundary enforcement.
-- Asserts that has_group_permission / is_group_member return FALSE for any
-- non-active membership status, regardless of attached roles. This locks
-- the doctrine "status='active' is required to exercise group permissions"
-- against future regressions.

CREATE OR REPLACE FUNCTION public._smoke_membership_boundary()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_group_count int;
  v_owner_uid  uuid := gen_random_uuid();
  v_target_uid uuid := gen_random_uuid();
  v_group_id   uuid;
  v_role_id    uuid;
  v_target_mid uuid;
  v_state text;
  v_has_perm boolean;
  v_is_member boolean;
  v_states text[] := ARRAY['paused','suspended','removed','left','banned','invited','requested'];
BEGIN
  SELECT count(*) INTO v_group_count FROM public.groups;
  IF v_group_count > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', v_group_count USING errcode = 'P0001';
  END IF;

  -- Seed: 2 auth users (owner + target), 1 group, 1 role that grants members.invite
  INSERT INTO auth.users (id) VALUES (v_owner_uid), (v_target_uid);

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_owner_uid::text)::text, true);

  INSERT INTO public.groups (id, name, slug, created_by)
    VALUES (gen_random_uuid(), 'boundary-test', 'boundary-test-' || substr(md5(random()::text), 1, 8), v_owner_uid)
    RETURNING id INTO v_group_id;

  INSERT INTO public.group_memberships (group_id, user_id, status, membership_type, joined_via)
    VALUES (v_group_id, v_owner_uid, 'active', 'member', 'founder_seed');

  INSERT INTO public.group_roles (group_id, key, name, is_system, is_default)
    VALUES (v_group_id, 'tester', 'Tester', false, false)
    RETURNING id INTO v_role_id;

  INSERT INTO public.group_role_permissions (role_id, permission_key)
    VALUES (v_role_id, 'members.invite');

  INSERT INTO public.group_memberships (group_id, user_id, status, membership_type, joined_via)
    VALUES (v_group_id, v_target_uid, 'active', 'member', 'admin_add')
    RETURNING id INTO v_target_mid;

  INSERT INTO public.group_member_roles (membership_id, role_id)
    VALUES (v_target_mid, v_role_id);

  -- Baseline: target is active + has the role → must have the permission
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_target_uid::text)::text, true);
  v_has_perm  := public.has_group_permission(v_group_id, 'members.invite');
  v_is_member := public.is_group_member(v_group_id);
  IF NOT v_has_perm THEN
    RAISE EXCEPTION '_smoke_membership_boundary: baseline active+role should have members.invite';
  END IF;
  IF NOT v_is_member THEN
    RAISE EXCEPTION '_smoke_membership_boundary: baseline active should be group member';
  END IF;

  -- For each non-active status, force the membership into that status and assert
  -- both gates fail. We bypass set_membership_state (which has its own gates)
  -- by direct UPDATE — this is intentional: the smoke is testing the read-side
  -- gates, not the write-side state machine.
  FOREACH v_state IN ARRAY v_states LOOP
    UPDATE public.group_memberships
       SET status = v_state,
           updated_at = now()
     WHERE id = v_target_mid;

    v_has_perm  := public.has_group_permission(v_group_id, 'members.invite');
    v_is_member := public.is_group_member(v_group_id);

    IF v_has_perm THEN
      RAISE EXCEPTION '_smoke_membership_boundary: status=% retained members.invite (role still attached)', v_state;
    END IF;
    IF v_is_member THEN
      RAISE EXCEPTION '_smoke_membership_boundary: status=% still passes is_group_member', v_state;
    END IF;
  END LOOP;

  -- Cleanup. Best-effort like _smoke_inbox: skip if non-superuser.
  PERFORM set_config('request.jwt.claims', null, true);
  BEGIN
    PERFORM set_config('session_replication_role', 'replica', true);
    DELETE FROM public.group_member_roles WHERE membership_id = v_target_mid;
    DELETE FROM public.group_role_permissions WHERE role_id = v_role_id;
    DELETE FROM public.group_roles WHERE id = v_role_id;
    DELETE FROM public.group_memberships WHERE group_id = v_group_id;
    DELETE FROM public.groups WHERE id = v_group_id;
    DELETE FROM auth.users WHERE id IN (v_owner_uid, v_target_uid);
    PERFORM set_config('session_replication_role', 'origin', true);
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;

  RAISE NOTICE '_smoke_membership_boundary passed';
END;
$function$;

GRANT EXECUTE ON FUNCTION public._smoke_membership_boundary() TO postgres;
