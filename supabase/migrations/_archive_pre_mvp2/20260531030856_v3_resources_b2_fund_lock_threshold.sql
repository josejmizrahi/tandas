-- Fase B.2: Fund lock/unlock + threshold.
-- 3 RPCs that operate on the fund subtype (group_resource_funds).

-- 1. lock_fund
CREATE OR REPLACE FUNCTION public.lock_fund(
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
  v_locked  timestamptz;
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
  IF v_r.resource_type <> 'fund' THEN
    RAISE EXCEPTION 'resource is not a fund' USING errcode = '22023';
  END IF;
  IF v_r.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'resource is archived' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update');

  SELECT locked_at INTO v_locked
    FROM public.group_resource_funds WHERE resource_id = p_resource_id;

  IF p_client_id IS NOT NULL THEN
    SELECT ge.uuid_id INTO v_dup
      FROM public.group_events ge
     WHERE ge.group_id = v_r.group_id
       AND ge.event_type = 'resource.status_changed'
       AND ge.entity_id = p_resource_id
       AND ge.payload->>'client_id' = p_client_id
       AND ge.payload->>'to' = 'locked'
     LIMIT 1;
    IF v_dup IS NOT NULL THEN RETURN v_dup; END IF;
  END IF;

  IF v_locked IS NOT NULL THEN
    -- Already locked: no-op, return latest matching event (or NULL).
    SELECT ge.uuid_id INTO v_event
      FROM public.group_events ge
     WHERE ge.group_id = v_r.group_id
       AND ge.event_type = 'resource.status_changed'
       AND ge.entity_id = p_resource_id
       AND ge.payload->>'to' = 'locked'
     ORDER BY ge.occurred_at DESC LIMIT 1;
    RETURN v_event;
  END IF;

  INSERT INTO public.group_resource_funds (resource_id, locked_at, updated_at)
       VALUES (p_resource_id, now(), now())
  ON CONFLICT (resource_id)
    DO UPDATE SET locked_at = now(), updated_at = now();

  v_payload := jsonb_build_object(
    'subtype', 'fund',
    'from', 'unlocked',
    'to', 'locked',
    'reason', p_reason
  );
  IF p_client_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('client_id', p_client_id);
  END IF;

  SELECT rse.uuid_id INTO v_event
    FROM public.record_system_event(
      v_r.group_id,
      'resource.status_changed',
      'resource',
      p_resource_id,
      COALESCE(p_reason, 'Fondo bloqueado'),
      v_payload
    ) rse;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.lock_fund(uuid, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.lock_fund(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.lock_fund(uuid, text, text) IS
'Fund Fase B.2: locks the fund (sets locked_at=now()). Emits resource.status_changed (from=unlocked, to=locked). Idempotent: re-lock is a no-op.';

-- 2. unlock_fund
CREATE OR REPLACE FUNCTION public.unlock_fund(
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
  v_locked  timestamptz;
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
  IF v_r.resource_type <> 'fund' THEN
    RAISE EXCEPTION 'resource is not a fund' USING errcode = '22023';
  END IF;
  IF v_r.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'resource is archived' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update');

  SELECT locked_at INTO v_locked
    FROM public.group_resource_funds WHERE resource_id = p_resource_id;
  IF v_locked IS NULL THEN
    RAISE EXCEPTION 'fund is not locked' USING errcode = '22023';
  END IF;

  IF p_client_id IS NOT NULL THEN
    SELECT ge.uuid_id INTO v_dup
      FROM public.group_events ge
     WHERE ge.group_id = v_r.group_id
       AND ge.event_type = 'resource.status_changed'
       AND ge.entity_id = p_resource_id
       AND ge.payload->>'client_id' = p_client_id
       AND ge.payload->>'to' = 'unlocked'
     LIMIT 1;
    IF v_dup IS NOT NULL THEN RETURN v_dup; END IF;
  END IF;

  UPDATE public.group_resource_funds
     SET locked_at = NULL, updated_at = now()
   WHERE resource_id = p_resource_id;

  v_payload := jsonb_build_object(
    'subtype', 'fund',
    'from', 'locked',
    'to', 'unlocked',
    'reason', p_reason
  );
  IF p_client_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('client_id', p_client_id);
  END IF;

  SELECT rse.uuid_id INTO v_event
    FROM public.record_system_event(
      v_r.group_id,
      'resource.status_changed',
      'resource',
      p_resource_id,
      COALESCE(p_reason, 'Fondo desbloqueado'),
      v_payload
    ) rse;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.unlock_fund(uuid, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.unlock_fund(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.unlock_fund(uuid, text, text) IS
'Fund Fase B.2: unlocks the fund (sets locked_at=NULL). Emits resource.status_changed (from=locked, to=unlocked). Idempotent.';

-- 3. set_fund_threshold
CREATE OR REPLACE FUNCTION public.set_fund_threshold(
  p_resource_id     uuid,
  p_threshold_target numeric,
  p_unit            text DEFAULT NULL,
  p_reason          text DEFAULT NULL,
  p_client_id       text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_r       public.group_resources%ROWTYPE;
  v_prev    numeric;
  v_prev_cur text;
  v_dup     uuid;
  v_event   uuid;
  v_payload jsonb;
  v_unit    text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  SELECT * INTO v_r FROM public.group_resources WHERE id = p_resource_id;
  IF v_r.id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = '22023';
  END IF;
  IF v_r.resource_type <> 'fund' THEN
    RAISE EXCEPTION 'resource is not a fund' USING errcode = '22023';
  END IF;
  IF v_r.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'resource is archived' USING errcode = '22023';
  END IF;
  IF p_threshold_target IS NULL OR p_threshold_target < 0 THEN
    RAISE EXCEPTION 'threshold must be >= 0' USING errcode = '22023';
  END IF;

  PERFORM public.assert_permission(v_r.group_id, 'resources.update');

  SELECT threshold_target, currency INTO v_prev, v_prev_cur
    FROM public.group_resource_funds WHERE resource_id = p_resource_id;
  v_unit := COALESCE(NULLIF(btrim(coalesce(p_unit, '')), ''), v_prev_cur);

  IF p_client_id IS NOT NULL THEN
    SELECT ge.uuid_id INTO v_dup
      FROM public.group_events ge
     WHERE ge.group_id = v_r.group_id
       AND ge.event_type = 'resource.status_changed'
       AND ge.entity_id = p_resource_id
       AND ge.payload->>'client_id' = p_client_id
       AND ge.payload->>'kind' = 'threshold_updated'
     LIMIT 1;
    IF v_dup IS NOT NULL THEN RETURN v_dup; END IF;
  END IF;

  INSERT INTO public.group_resource_funds (resource_id, threshold_target, currency, updated_at)
       VALUES (p_resource_id, p_threshold_target, v_unit, now())
  ON CONFLICT (resource_id)
    DO UPDATE SET threshold_target = EXCLUDED.threshold_target,
                  currency        = COALESCE(EXCLUDED.currency, group_resource_funds.currency),
                  updated_at      = now();

  v_payload := jsonb_build_object(
    'subtype', 'fund',
    'kind', 'threshold_updated',
    'from_threshold', v_prev,
    'to_threshold', p_threshold_target,
    'unit', v_unit,
    'reason', p_reason
  );
  IF p_client_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('client_id', p_client_id);
  END IF;

  SELECT rse.uuid_id INTO v_event
    FROM public.record_system_event(
      v_r.group_id,
      'resource.status_changed',
      'resource',
      p_resource_id,
      COALESCE(p_reason, 'Meta del fondo actualizada'),
      v_payload
    ) rse;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.set_fund_threshold(uuid, numeric, text, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.set_fund_threshold(uuid, numeric, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.set_fund_threshold(uuid, numeric, text, text, text) IS
'Fund Fase B.2: updates threshold_target (and currency when p_unit provided). Emits resource.status_changed (kind=threshold_updated). Idempotent via p_client_id.';
