-- Fase B.4: Right grant/transfer/revoke/expire.
-- 4 RPCs that operate on group_resource_rights subtype.

-- 1. grant_right
CREATE OR REPLACE FUNCTION public.grant_right(
  p_resource_id          uuid,
  p_holder_membership_id uuid,
  p_right_kind           text DEFAULT NULL,
  p_expires_at           timestamptz DEFAULT NULL,
  p_conditions           text DEFAULT NULL,
  p_transferable         boolean DEFAULT false,
  p_reason               text DEFAULT NULL,
  p_client_id            text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid          uuid := auth.uid();
  v_r            public.group_resources%ROWTYPE;
  v_member_group uuid;
  v_prev_holder  uuid;
  v_dup          uuid;
  v_event        uuid;
  v_payload      jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id;
  IF v_r.id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = '22023';
  END IF;
  IF v_r.resource_type <> 'right' THEN
    RAISE EXCEPTION 'resource is not a right' USING errcode = '22023';
  END IF;
  IF v_r.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'resource is archived' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update');

  SELECT group_id INTO v_member_group
    FROM public.group_memberships WHERE id = p_holder_membership_id;
  IF v_member_group IS NULL THEN
    RAISE EXCEPTION 'membership not found' USING errcode = '22023';
  END IF;
  IF v_member_group <> v_r.group_id THEN
    RAISE EXCEPTION 'membership not in resource group' USING errcode = '22023';
  END IF;

  IF p_client_id IS NOT NULL THEN
    SELECT ge.uuid_id INTO v_dup
      FROM public.group_events ge
     WHERE ge.group_id = v_r.group_id
       AND ge.event_type = 'resource.assigned'
       AND ge.entity_id = p_resource_id
       AND ge.payload->>'client_id' = p_client_id
       AND ge.payload->>'role' = 'holder'
     LIMIT 1;
    IF v_dup IS NOT NULL THEN RETURN v_dup; END IF;
  END IF;

  SELECT holder_membership_id INTO v_prev_holder
    FROM public.group_resource_rights WHERE resource_id = p_resource_id;

  INSERT INTO public.group_resource_rights (
    resource_id, right_kind, holder_membership_id,
    granted_at, expires_at, transferable, conditions,
    expired_at, revoked_at, updated_at
  ) VALUES (
    p_resource_id, p_right_kind, p_holder_membership_id,
    now(), p_expires_at, COALESCE(p_transferable, false), p_conditions,
    NULL, NULL, now()
  )
  ON CONFLICT (resource_id)
    DO UPDATE SET
      right_kind            = COALESCE(EXCLUDED.right_kind, group_resource_rights.right_kind),
      holder_membership_id  = EXCLUDED.holder_membership_id,
      granted_at            = now(),
      expires_at            = EXCLUDED.expires_at,
      transferable          = EXCLUDED.transferable,
      conditions            = COALESCE(EXCLUDED.conditions, group_resource_rights.conditions),
      expired_at            = NULL,
      revoked_at            = NULL,
      updated_at            = now();

  v_payload := jsonb_build_object(
    'subtype', 'right',
    'role', 'holder',
    'membership_id', p_holder_membership_id,
    'previous_membership_id', v_prev_holder,
    'right_kind', p_right_kind,
    'expires_at', p_expires_at,
    'transferable', COALESCE(p_transferable, false),
    'reason', p_reason
  );
  IF p_client_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('client_id', p_client_id);
  END IF;

  SELECT rse.uuid_id INTO v_event
    FROM public.record_system_event(
      v_r.group_id, 'resource.assigned', 'resource', p_resource_id,
      COALESCE(p_reason, 'Derecho otorgado'), v_payload
    ) rse;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.grant_right(uuid, uuid, text, timestamptz, text, boolean, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.grant_right(uuid, uuid, text, timestamptz, text, boolean, text, text) TO authenticated;

COMMENT ON FUNCTION public.grant_right(uuid, uuid, text, timestamptz, text, boolean, text, text) IS
'Right Fase B.4: grants (or re-grants) the right to a holder, refreshing granted_at and clearing expired_at/revoked_at. Emits resource.assigned (role=holder). Idempotent.';

-- 2. transfer_right
CREATE OR REPLACE FUNCTION public.transfer_right(
  p_resource_id            uuid,
  p_new_holder_membership_id uuid,
  p_reason                 text DEFAULT NULL,
  p_client_id              text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_r         public.group_resources%ROWTYPE;
  v_member_g  uuid;
  v_holder    uuid;
  v_xferable  boolean;
  v_revoked   timestamptz;
  v_expired   timestamptz;
  v_dup       uuid;
  v_event     uuid;
  v_payload   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id;
  IF v_r.id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = '22023';
  END IF;
  IF v_r.resource_type <> 'right' THEN
    RAISE EXCEPTION 'resource is not a right' USING errcode = '22023';
  END IF;
  IF v_r.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'resource is archived' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update');

  SELECT holder_membership_id, transferable, revoked_at, expired_at
    INTO v_holder, v_xferable, v_revoked, v_expired
    FROM public.group_resource_rights WHERE resource_id = p_resource_id;
  IF v_holder IS NULL THEN
    RAISE EXCEPTION 'right has no holder' USING errcode = '22023';
  END IF;
  IF v_revoked IS NOT NULL OR v_expired IS NOT NULL THEN
    RAISE EXCEPTION 'right is not active' USING errcode = '22023';
  END IF;
  IF v_xferable IS NOT TRUE THEN
    RAISE EXCEPTION 'right is not transferable' USING errcode = '22023';
  END IF;

  SELECT group_id INTO v_member_g
    FROM public.group_memberships WHERE id = p_new_holder_membership_id;
  IF v_member_g IS NULL THEN
    RAISE EXCEPTION 'membership not found' USING errcode = '22023';
  END IF;
  IF v_member_g <> v_r.group_id THEN
    RAISE EXCEPTION 'membership not in resource group' USING errcode = '22023';
  END IF;

  IF p_client_id IS NOT NULL THEN
    SELECT ge.uuid_id INTO v_dup
      FROM public.group_events ge
     WHERE ge.group_id = v_r.group_id
       AND ge.event_type = 'resource.transferred'
       AND ge.entity_id = p_resource_id
       AND ge.payload->>'client_id' = p_client_id
     LIMIT 1;
    IF v_dup IS NOT NULL THEN RETURN v_dup; END IF;
  END IF;

  UPDATE public.group_resource_rights
     SET holder_membership_id = p_new_holder_membership_id,
         updated_at = now()
   WHERE resource_id = p_resource_id;

  v_payload := jsonb_build_object(
    'subtype', 'right',
    'role', 'holder',
    'from_membership_id', v_holder,
    'to_membership_id', p_new_holder_membership_id,
    'reason', p_reason
  );
  IF p_client_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('client_id', p_client_id);
  END IF;

  SELECT rse.uuid_id INTO v_event
    FROM public.record_system_event(
      v_r.group_id, 'resource.transferred', 'resource', p_resource_id,
      COALESCE(p_reason, 'Derecho transferido'), v_payload
    ) rse;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.transfer_right(uuid, uuid, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.transfer_right(uuid, uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.transfer_right(uuid, uuid, text, text) IS
'Right Fase B.4: transfers an active transferable right to a new holder. Emits resource.transferred. Idempotent.';

-- 3. revoke_right
CREATE OR REPLACE FUNCTION public.revoke_right(
  p_resource_id uuid,
  p_reason      text DEFAULT NULL,
  p_client_id   text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_r       public.group_resources%ROWTYPE;
  v_holder  uuid;
  v_revoked timestamptz;
  v_dup     uuid;
  v_event   uuid;
  v_payload jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id;
  IF v_r.id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = '22023';
  END IF;
  IF v_r.resource_type <> 'right' THEN
    RAISE EXCEPTION 'resource is not a right' USING errcode = '22023';
  END IF;
  IF v_r.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'resource is archived' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update');

  SELECT holder_membership_id, revoked_at INTO v_holder, v_revoked
    FROM public.group_resource_rights WHERE resource_id = p_resource_id;
  IF v_holder IS NULL THEN
    RAISE EXCEPTION 'right has no holder' USING errcode = '22023';
  END IF;
  IF v_revoked IS NOT NULL THEN
    RAISE EXCEPTION 'right already revoked' USING errcode = '22023';
  END IF;

  IF p_client_id IS NOT NULL THEN
    SELECT ge.uuid_id INTO v_dup
      FROM public.group_events ge
     WHERE ge.group_id = v_r.group_id
       AND ge.event_type = 'resource.status_changed'
       AND ge.entity_id = p_resource_id
       AND ge.payload->>'client_id' = p_client_id
       AND ge.payload->>'to' = 'revoked'
     LIMIT 1;
    IF v_dup IS NOT NULL THEN RETURN v_dup; END IF;
  END IF;

  UPDATE public.group_resource_rights
     SET revoked_at = now(),
         updated_at = now()
   WHERE resource_id = p_resource_id;

  v_payload := jsonb_build_object(
    'subtype', 'right',
    'from', 'active',
    'to', 'revoked',
    'previous_holder_id', v_holder,
    'reason', p_reason
  );
  IF p_client_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('client_id', p_client_id);
  END IF;

  SELECT rse.uuid_id INTO v_event
    FROM public.record_system_event(
      v_r.group_id, 'resource.status_changed', 'resource', p_resource_id,
      COALESCE(p_reason, 'Derecho revocado'), v_payload
    ) rse;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.revoke_right(uuid, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.revoke_right(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.revoke_right(uuid, text, text) IS
'Right Fase B.4: revokes an active right (sets revoked_at). Emits resource.status_changed (to=revoked).';

-- 4. expire_right
CREATE OR REPLACE FUNCTION public.expire_right(
  p_resource_id uuid,
  p_client_id   text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_r         public.group_resources%ROWTYPE;
  v_expires   timestamptz;
  v_expired   timestamptz;
  v_revoked   timestamptz;
  v_holder    uuid;
  v_dup       uuid;
  v_event     uuid;
  v_payload   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id;
  IF v_r.id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = '22023';
  END IF;
  IF v_r.resource_type <> 'right' THEN
    RAISE EXCEPTION 'resource is not a right' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update');

  SELECT holder_membership_id, expires_at, expired_at, revoked_at
    INTO v_holder, v_expires, v_expired, v_revoked
    FROM public.group_resource_rights WHERE resource_id = p_resource_id;
  IF v_holder IS NULL THEN
    RAISE EXCEPTION 'right has no holder' USING errcode = '22023';
  END IF;
  IF v_expired IS NOT NULL THEN
    RAISE EXCEPTION 'right already expired' USING errcode = '22023';
  END IF;
  IF v_revoked IS NOT NULL THEN
    RAISE EXCEPTION 'right was revoked' USING errcode = '22023';
  END IF;
  IF v_expires IS NULL OR v_expires > now() THEN
    RAISE EXCEPTION 'right has not reached its expiration' USING errcode = '22023';
  END IF;

  IF p_client_id IS NOT NULL THEN
    SELECT ge.uuid_id INTO v_dup
      FROM public.group_events ge
     WHERE ge.group_id = v_r.group_id
       AND ge.event_type = 'resource.status_changed'
       AND ge.entity_id = p_resource_id
       AND ge.payload->>'client_id' = p_client_id
       AND ge.payload->>'to' = 'expired'
     LIMIT 1;
    IF v_dup IS NOT NULL THEN RETURN v_dup; END IF;
  END IF;

  UPDATE public.group_resource_rights
     SET expired_at = now(), updated_at = now()
   WHERE resource_id = p_resource_id;

  v_payload := jsonb_build_object(
    'subtype', 'right',
    'from', 'active',
    'to', 'expired',
    'previous_holder_id', v_holder,
    'expires_at', v_expires
  );
  IF p_client_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('client_id', p_client_id);
  END IF;

  SELECT rse.uuid_id INTO v_event
    FROM public.record_system_event(
      v_r.group_id, 'resource.status_changed', 'resource', p_resource_id,
      'Derecho expirado', v_payload
    ) rse;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.expire_right(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.expire_right(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.expire_right(uuid, text) IS
'Right Fase B.4: marks a right as expired after its expires_at deadline. Emits resource.status_changed (to=expired).';
