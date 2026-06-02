-- PARTE 12 — N.8 Memory + Audit smoke.
--
-- Cobertura:
--   - Atom guards en group_events (no_mutation + no_delete).
--   - record_system_event retorna (id bigint, uuid_id uuid) y inserta row.
--   - UPDATE group_events.summary → bloqueado.
--   - DELETE group_events → bloqueado.
--   - group_events_recent retorna rows ordenadas DESC (created_at, id).

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
  v_first_id     bigint;
  v_second_id    bigint;
  v_ordering_ok  boolean;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  -- 0a. Atom guards en group_events.
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

  -- N.8.1: record_system_event retorna composite + row visible en group_events.
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

  -- N.8.2: UPDATE group_events.summary → bloqueado.
  BEGIN
    UPDATE public.group_events SET summary = 'tampered' WHERE id = v_event_id_1;
  EXCEPTION WHEN OTHERS THEN
    v_update_blocked := true;
  END;
  step := 'N.8.2.update_summary_blocked'; ok := v_update_blocked;
  detail := 'blocked=' || v_update_blocked::text; RETURN NEXT;

  -- N.8.3: DELETE group_events → bloqueado.
  BEGIN
    DELETE FROM public.group_events WHERE id = v_event_id_1;
  EXCEPTION WHEN OTHERS THEN
    v_delete_blocked := true;
  END;
  step := 'N.8.3.delete_blocked'; ok := v_delete_blocked;
  detail := 'blocked=' || v_delete_blocked::text; RETURN NEXT;

  -- Setup para N.8.4: emitir un segundo evento.
  SELECT rse.id, rse.uuid_id INTO v_event_id_2, v_event_uuid_2
    FROM public.record_system_event(
      v_group_id, 'smoke.second', 'group', v_group_id, 'second event', jsonb_build_object('idx', 2)
    ) rse;

  -- N.8.4: group_events_recent retorna rows ordenadas DESC. El primero del feed
  -- debe ser el evento más reciente (v_event_id_2 > v_event_id_1).
  SELECT count(*) INTO v_recent_count FROM public.group_events_recent(v_group_id, 50, NULL);
  SELECT id INTO v_first_id FROM public.group_events_recent(v_group_id, 50, NULL) LIMIT 1;
  SELECT id INTO v_second_id FROM public.group_events_recent(v_group_id, 50, NULL) OFFSET 1 LIMIT 1;
  v_ordering_ok := v_first_id IS NOT NULL AND v_second_id IS NOT NULL AND v_first_id >= v_second_id;
  step := 'N.8.4.group_events_recent_desc_order';
  ok := v_recent_count >= 2 AND v_ordering_ok;
  detail := 'count=' || v_recent_count
            || ' first=' || COALESCE(v_first_id::text,'NULL')
            || ' second=' || COALESCE(v_second_id::text,'NULL'); RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_memory_audit() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_memory_audit() TO service_role;
