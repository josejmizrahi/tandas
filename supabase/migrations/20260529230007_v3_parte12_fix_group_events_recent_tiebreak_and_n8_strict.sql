-- PARTE 12 — fix operativo: group_events_recent ORDER BY ahora incluye tie-break
-- secundario `id DESC` (bigint cursor monotónico). Sin este tie-break la
-- pagination era no-determinística cuando múltiples eventos compartían
-- occurred_at (caso real: RPCs que emiten varios eventos en la misma tx).
--
-- iOS-facing API unchanged: la RPC sigue retornando el mismo set de columnas
-- y aceptando `p_before timestamptz`. El cambio es interno al ORDER BY.
--
-- + UPGRADE de _smoke_memory_audit: ahora asserta strict DESC ordering en N.8.4
-- (gracias al tie-break, el primer row del feed = evento con id más alto).

CREATE OR REPLACE FUNCTION public.group_events_recent(
  p_group_id uuid,
  p_limit integer DEFAULT 100,
  p_before timestamp with time zone DEFAULT NULL::timestamp with time zone
)
RETURNS TABLE(
  event_uuid uuid, group_id uuid, actor_user_id uuid, actor_display_name text,
  event_type text, entity_kind text, entity_id uuid, summary text,
  payload jsonb, occurred_at timestamp with time zone
)
LANGUAGE plpgsql STABLE
SET search_path TO 'public', 'pg_catalog'
AS $function$
#variable_conflict use_column
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    e.uuid_id                                            AS event_uuid,
    e.group_id                                           AS group_id,
    e.actor_user_id                                      AS actor_user_id,
    COALESCE(NULLIF(p.display_name, ''), NULL)           AS actor_display_name,
    e.event_type                                         AS event_type,
    e.entity_kind                                        AS entity_kind,
    e.entity_id                                          AS entity_id,
    e.summary                                            AS summary,
    e.payload                                            AS payload,
    e.occurred_at                                        AS occurred_at
  FROM public.group_events e
  LEFT JOIN public.profiles p ON p.id = e.actor_user_id
  WHERE e.group_id = p_group_id
    AND (p_before IS NULL OR e.occurred_at < p_before)
  ORDER BY e.occurred_at DESC, e.id DESC
  LIMIT GREATEST(1, COALESCE(p_limit, 100));
END;
$function$;

REVOKE ALL ON FUNCTION public.group_events_recent(uuid,integer,timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.group_events_recent(uuid,integer,timestamptz) TO authenticated, service_role;

-- ============================================================================
-- N.8 strict ordering tras tie-break
-- ============================================================================
CREATE OR REPLACE FUNCTION public._smoke_memory_audit()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_group_id     uuid;
  v_membership_a uuid;
  v_no_mutation_present int;
  v_no_delete_present int;
  v_event_id_1   bigint;
  v_event_uuid_1 uuid;
  v_event_id_2   bigint;
  v_event_uuid_2 uuid;
  v_row_count    int;
  v_update_blocked boolean := false;
  v_delete_blocked boolean := false;
  v_recent_count int;
  v_first_uuid   uuid;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  SELECT count(*) FILTER (WHERE p.proname='atom_no_mutation_guard'),
         count(*) FILTER (WHERE p.proname='atom_no_delete_guard')
    INTO v_no_mutation_present, v_no_delete_present
  FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
  WHERE t.tgrelid='public.group_events'::regclass AND NOT t.tgisinternal;
  step := '0a.group_events_atom_guards';
  ok := v_no_mutation_present >= 1 AND v_no_delete_present >= 1;
  detail := 'no_mutation=' || v_no_mutation_present || ' no_delete=' || v_no_delete_present; RETURN NEXT;

  INSERT INTO auth.users (id) VALUES (v_user_a);
  INSERT INTO public.profiles (id, display_name) VALUES (v_user_a, 'Smoke Mem A')
    ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_id := public.create_group('Smoke Mem ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');
  SELECT gm.id INTO v_membership_a FROM public.group_memberships gm
   WHERE gm.group_id = v_group_id AND gm.user_id = v_user_a;

  SELECT rse.id, rse.uuid_id INTO v_event_id_1, v_event_uuid_1
    FROM public.record_system_event(
      v_group_id, 'smoke.first', 'group', v_group_id, 'first event', jsonb_build_object('idx', 1)
    ) rse;
  SELECT count(*) INTO v_row_count FROM public.group_events
   WHERE id = v_event_id_1 AND uuid_id = v_event_uuid_1 AND group_id = v_group_id;
  step := 'N.8.1.record_event_returns_composite_and_row';
  ok := v_event_id_1 IS NOT NULL AND v_event_uuid_1 IS NOT NULL AND v_row_count = 1;
  detail := 'id=' || COALESCE(v_event_id_1::text,'NULL')
            || ' uuid_id=' || COALESCE(v_event_uuid_1::text,'NULL')
            || ' rows=' || v_row_count; RETURN NEXT;

  BEGIN
    UPDATE public.group_events SET summary = 'tampered' WHERE id = v_event_id_1;
  EXCEPTION WHEN OTHERS THEN
    v_update_blocked := true;
  END;
  step := 'N.8.2.update_summary_blocked'; ok := v_update_blocked;
  detail := 'blocked=' || v_update_blocked::text; RETURN NEXT;

  BEGIN
    DELETE FROM public.group_events WHERE id = v_event_id_1;
  EXCEPTION WHEN OTHERS THEN
    v_delete_blocked := true;
  END;
  step := 'N.8.3.delete_blocked'; ok := v_delete_blocked;
  detail := 'blocked=' || v_delete_blocked::text; RETURN NEXT;

  SELECT rse.id, rse.uuid_id INTO v_event_id_2, v_event_uuid_2
    FROM public.record_system_event(
      v_group_id, 'smoke.second', 'group', v_group_id, 'second event', jsonb_build_object('idx', 2)
    ) rse;

  -- N.8.4: con tie-break (occurred_at DESC, id DESC), el primer row del feed
  -- DEBE ser el evento con id más alto (v_event_uuid_2, insertado después).
  SELECT count(*) INTO v_recent_count FROM public.group_events_recent(v_group_id, 50, NULL);
  SELECT event_uuid INTO v_first_uuid FROM public.group_events_recent(v_group_id, 50, NULL) LIMIT 1;
  step := 'N.8.4.group_events_recent_strict_desc_with_tiebreak';
  ok := v_recent_count >= 2 AND v_first_uuid = v_event_uuid_2;
  detail := 'count=' || v_recent_count
            || ' first_matches_latest=' || (v_first_uuid = v_event_uuid_2)::text; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_memory_audit() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_memory_audit() TO service_role;
