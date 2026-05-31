-- PARTE 12 — N.13 Meta-smoke: permission keys audit.
--
-- Auto-detecta el patrón que esta sesión cazó 3 veces:
--   - start_vote citaba `decisions.propose` (no existía) → voting roto.
--   - cancel_sanction_payment_plan citaba `sanction.review` (no existía).
--   - emit_mandate_expiring_events filtraba `status='granted'` (no existía).
--
-- Sweep todas las SECURITY DEFINER en public, extrae permission keys cited
-- via assert_permission o has_permission/has_group_permission, y diff vs
-- catálogo `permissions`. Cualquier key no registrado = drift.
--
-- Falla con detalle del primer drift encontrado. Útil como guard CI para
-- futuros refactors del catálogo de permisos.

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

  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_permission_keys_audit() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_permission_keys_audit() TO service_role;
