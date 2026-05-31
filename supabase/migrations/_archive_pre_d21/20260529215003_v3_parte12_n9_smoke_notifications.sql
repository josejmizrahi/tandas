-- PARTE 12 — N.9 Notifications smoke: outbox guards + PARTE 8 dedup + PARTE 8 retention.
--
-- Cobertura:
--   - Atom guards (UPDATE payload bloqueado, UPDATE dispatch_status permitido).
--   - DELETE bloqueado para undispatched / dispatched < 30d.
--   - DELETE permitido para dispatched_at < now() - 30d (PARTE 8 retention).
--   - UNIQUE partial dedup por idempotency_key (PARTE 8).
--
-- No testea el flow real engine → consequence.send_notification (depende de PARTE 4
-- handlers o de regla activa). Validamos el atom + invariantes directamente.

CREATE OR REPLACE FUNCTION public._smoke_notifications()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_group_id     uuid;
  v_table_present int;
  v_no_delete_present int;
  v_partial_present int;
  v_dedup_index_present int;
  v_row_id_pending uuid;
  v_row_id_idem1   uuid;
  v_row_id_dispatched uuid;
  v_update_payload_blocked boolean := false;
  v_update_status_allowed  boolean := true;
  v_delete_undispatched_blocked boolean := false;
  v_delete_old_dispatched_ok boolean := true;
  v_dedup_blocked boolean := false;
  v_status_after text;
  v_count_after_delete int;
BEGIN
  IF (SELECT count(*) FROM public.groups) > 50 THEN
    RAISE EXCEPTION 'refusing to run smoke: too many groups (%)', (SELECT count(*) FROM public.groups);
  END IF;

  SELECT count(*) INTO v_table_present
  FROM information_schema.tables
  WHERE table_schema='public' AND table_name='notifications_outbox';
  step := '0a.notifications_outbox_table_present'; ok := v_table_present = 1;
  detail := 'count=' || v_table_present; RETURN NEXT;

  SELECT count(*) FILTER (WHERE p.proname='_notifications_outbox_no_delete'),
         count(*) FILTER (WHERE p.proname='_notifications_outbox_partial_guard')
    INTO v_no_delete_present, v_partial_present
  FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
  WHERE t.tgrelid='public.notifications_outbox'::regclass AND NOT t.tgisinternal;
  step := '0b.notifications_outbox_atom_guards'; ok := v_no_delete_present >= 1 AND v_partial_present >= 1;
  detail := 'no_delete=' || v_no_delete_present || ' partial=' || v_partial_present; RETURN NEXT;

  SELECT count(*) INTO v_dedup_index_present
  FROM pg_indexes
  WHERE tablename='notifications_outbox' AND indexname='notifications_outbox_idempotency';
  step := '0c.parte8_idempotency_index_present'; ok := v_dedup_index_present = 1;
  detail := 'count=' || v_dedup_index_present; RETURN NEXT;

  INSERT INTO auth.users (id) VALUES (v_user_a);
  INSERT INTO public.profiles (id, display_name) VALUES (v_user_a, 'Smoke Notif A')
    ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_group_id := public.create_group('Smoke Notif ' || substr(v_user_a::text,1,8), NULL, 'friends', 'Smoke');

  INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
    VALUES (v_group_id, v_user_a, 'smoke', jsonb_build_object('msg', 'hello'))
    RETURNING id INTO v_row_id_pending;
  SELECT dispatch_status INTO v_status_after FROM public.notifications_outbox WHERE id = v_row_id_pending;
  step := 'N.9.1.insert_row_pending'; ok := v_status_after = 'pending';
  detail := 'status=' || COALESCE(v_status_after, 'NULL'); RETURN NEXT;

  BEGIN
    UPDATE public.notifications_outbox SET payload = jsonb_build_object('tampered', true)
      WHERE id = v_row_id_pending;
  EXCEPTION WHEN OTHERS THEN
    v_update_payload_blocked := true;
  END;
  step := 'N.9.2.update_payload_blocked'; ok := v_update_payload_blocked;
  detail := 'blocked=' || v_update_payload_blocked::text; RETURN NEXT;

  BEGIN
    UPDATE public.notifications_outbox SET dispatch_status = 'dispatched', dispatched_at = now()
      WHERE id = v_row_id_pending;
  EXCEPTION WHEN OTHERS THEN
    v_update_status_allowed := false;
  END;
  step := 'N.9.2b.update_dispatch_status_allowed'; ok := v_update_status_allowed;
  detail := 'allowed=' || v_update_status_allowed::text; RETURN NEXT;

  BEGIN
    DELETE FROM public.notifications_outbox WHERE id = v_row_id_pending;
  EXCEPTION WHEN OTHERS THEN
    v_delete_undispatched_blocked := true;
  END;
  step := 'N.9.3.delete_recent_dispatched_blocked'; ok := v_delete_undispatched_blocked;
  detail := 'blocked=' || v_delete_undispatched_blocked::text; RETURN NEXT;

  INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
    VALUES (v_group_id, v_user_a, 'smoke', jsonb_build_object('msg', 'old'))
    RETURNING id INTO v_row_id_dispatched;
  UPDATE public.notifications_outbox
     SET dispatch_status = 'dispatched', dispatched_at = now() - interval '31 days'
   WHERE id = v_row_id_dispatched;
  BEGIN
    DELETE FROM public.notifications_outbox WHERE id = v_row_id_dispatched;
  EXCEPTION WHEN OTHERS THEN
    v_delete_old_dispatched_ok := false;
  END;
  SELECT count(*) INTO v_count_after_delete FROM public.notifications_outbox WHERE id = v_row_id_dispatched;
  step := 'N.9.3b.delete_old_dispatched_allowed'; ok := v_delete_old_dispatched_ok AND v_count_after_delete = 0;
  detail := 'no_raise=' || v_delete_old_dispatched_ok::text || ' rows_left=' || v_count_after_delete; RETURN NEXT;

  INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
    VALUES (v_group_id, v_user_a, 'dedup_smoke', jsonb_build_object('idempotency_key', 'smoke-k-1'))
    RETURNING id INTO v_row_id_idem1;
  BEGIN
    INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
      VALUES (v_group_id, v_user_a, 'dedup_smoke', jsonb_build_object('idempotency_key', 'smoke-k-1'));
  EXCEPTION WHEN unique_violation THEN
    v_dedup_blocked := true;
  END;
  step := 'N.9.4.dedup_same_idempotency_key_blocked'; ok := v_dedup_blocked AND v_row_id_idem1 IS NOT NULL;
  detail := 'blocked=' || v_dedup_blocked::text; RETURN NEXT;

  step := 'cleanup'; ok := true;
  detail := 'skipped (atom guards block cascade delete on remaining rows; smoke data persists on dev)';
  RETURN NEXT;
  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_notifications() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_notifications() TO service_role;
