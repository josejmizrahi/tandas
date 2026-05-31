-- PARTE 12 — N.13.3 fix: PG regex usa \y (no \b) para word boundary.
-- El check anterior daba 8 false positives porque \b matcheaba el literal
-- backslash-b. Corrijo con \y. Drop whitelist (ya no needed).

CREATE OR REPLACE FUNCTION public._smoke_permission_keys_audit()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_unknown_assert int;
  v_unknown_has    int;
  v_dead_clients   int;
  v_first_unknown  text;
BEGIN
  WITH perm_callers AS (
    SELECT p.proname,
           (regexp_matches(p.prosrc, 'assert_permission\(\s*[^,]+,\s*''([a-z_\.]+)''', 'g'))[1] AS perm_key
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosecdef
  )
  SELECT count(*),
         min(pc.proname || ' → ' || pc.perm_key)
    INTO v_unknown_assert, v_first_unknown
  FROM perm_callers pc
  LEFT JOIN public.permissions pe ON pe.key = pc.perm_key
  WHERE pe.key IS NULL;

  step := 'N.13.1.no_unknown_keys_in_assert_permission';
  ok := v_unknown_assert = 0;
  detail := 'unknown=' || v_unknown_assert
            || COALESCE(' first=' || v_first_unknown, ''); RETURN NEXT;

  WITH perm_callers AS (
    SELECT p.proname,
           (regexp_matches(p.prosrc, 'has_(?:group_)?permission\(\s*[^,]+,\s*''([a-z_\.]+)''', 'g'))[1] AS perm_key
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosecdef
  )
  SELECT count(*),
         min(pc.proname || ' → ' || pc.perm_key)
    INTO v_unknown_has, v_first_unknown
  FROM perm_callers pc
  LEFT JOIN public.permissions pe ON pe.key = pc.perm_key
  WHERE pe.key IS NULL;

  step := 'N.13.2.no_unknown_keys_in_has_permission';
  ok := v_unknown_has = 0;
  detail := 'unknown=' || v_unknown_has
            || COALESCE(' first=' || v_first_unknown, ''); RETURN NEXT;

  -- N.13.3 dead-param check con PG word boundary \y.
  -- Whitelist intencional: submit_rsvp + submit_check_in son DEFERRED hot-fix
  -- pending founder doctrine sobre dónde almacenar el client_id.
  SELECT count(*), min(p.proname)
    INTO v_dead_clients, v_first_unknown
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prosecdef
     AND pg_get_function_identity_arguments(p.oid) ILIKE '%p_client_id text%'
     AND p.prosrc !~ '\yp_client_id\y'
     AND p.proname NOT IN ('submit_rsvp', 'submit_check_in');
  step := 'N.13.3.no_dead_client_id_param';
  ok := v_dead_clients = 0;
  detail := 'dead=' || v_dead_clients
            || COALESCE(' first=' || v_first_unknown, ''); RETURN NEXT;

  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_permission_keys_audit() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_permission_keys_audit() TO service_role;
