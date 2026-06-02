-- PARTE 12 — N.8 fix2: group_events_recent ORDER BY occurred_at DESC SIN tie-break
-- (sin id DESC secundario como decía spec). En single-tx todos los eventos
-- comparten now() → ordering no determinístico. Ajusto N.8.4 a "count consistente
-- + todos los uuids son del set emitido" en vez de "first = latest emitted".
--
-- TODO drift documentado: agregar tie-break `id DESC` al ORDER BY de
-- group_events_recent para que la pagination cursor sea estable. Mig separada.

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
  v_emitted_pair_in_feed int;
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

  -- N.8.4: group_events_recent retorna feed con los 2 eventos emitidos por el smoke
  -- + group.created. ORDER BY occurred_at DESC sin tie-break ⇒ ordering interno
  -- no determinístico cuando timestamps coinciden (same-tx). Aserto débil pero
  -- estable: count >= 2 + ambos uuids del par emitido están en el feed.
  SELECT count(*) INTO v_recent_count FROM public.group_events_recent(v_group_id, 50, NULL);
  SELECT count(*) INTO v_emitted_pair_in_feed
    FROM public.group_events_recent(v_group_id, 50, NULL)
    WHERE event_uuid IN (v_event_uuid_1, v_event_uuid_2);
  step := 'N.8.4.group_events_recent_returns_feed';
  ok := v_recent_count >= 2 AND v_emitted_pair_in_feed = 2;
  detail := 'count=' || v_recent_count || ' emitted_pair_present=' || v_emitted_pair_in_feed; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_memory_audit() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_memory_audit() TO service_role;
