-- PARTE 12 — N.14 refinement: el literal 'expelled' en finalize_vote es legacy
-- compat con iOS (que sigue mandando 'expelled'/'inactive' como target_state
-- en metadata de membership decisions). El hot-fix anterior agregó CASE mapping
-- 'expelled'→'banned' y 'inactive'→'left' antes de invocar set_membership_state.
--
-- N.14.5 ahora cazaría sólo el patrón "peligroso": llamadas a set_membership_state
-- con 'expelled' o 'inactive' como segundo argumento. El CASE input (legacy compat)
-- es aceptable.

CREATE OR REPLACE FUNCTION public._smoke_dead_value_regression_guard()
RETURNS TABLE(step text, ok boolean, detail text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_n int;
  v_first text;
BEGIN
  SELECT count(*), min(p.proname)
    INTO v_n, v_first
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prosecdef
     AND p.proname <> '_smoke_dead_value_regression_guard'
     AND p.prosrc ~ '\.status\s*[=:]+\s*''granted''';
  step := 'N.14.1.no_dead_status_granted'; ok := v_n = 0;
  detail := 'count=' || v_n || COALESCE(' first=' || v_first, ''); RETURN NEXT;

  SELECT count(*), min(p.proname)
    INTO v_n, v_first
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prosecdef
     AND p.proname <> '_smoke_dead_value_regression_guard'
     AND p.prosrc ~ '''decisions\.propose''';
  step := 'N.14.2.no_dead_permission_decisions_propose'; ok := v_n = 0;
  detail := 'count=' || v_n || COALESCE(' first=' || v_first, ''); RETURN NEXT;

  SELECT count(*), min(p.proname)
    INTO v_n, v_first
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prosecdef
     AND p.proname <> '_smoke_dead_value_regression_guard'
     AND p.prosrc ~ '''sanction\.review''';
  step := 'N.14.3.no_dead_permission_sanction_review'; ok := v_n = 0;
  detail := 'count=' || v_n || COALESCE(' first=' || v_first, ''); RETURN NEXT;

  SELECT count(*), min(p.proname)
    INTO v_n, v_first
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prosecdef
     AND p.proname <> '_smoke_dead_value_regression_guard'
     AND p.prosrc ~ '\.decision_type\s*[=:]+\s*''free_form''';
  step := 'N.14.4.no_dead_decision_type_free_form'; ok := v_n = 0;
  detail := 'count=' || v_n || COALESCE(' first=' || v_first, ''); RETURN NEXT;

  -- N.14.5 tightened: solo flagea llamadas a set_membership_state con valores
  -- legacy. El CASE input WHEN 'expelled' THEN 'banned' es legacy compat OK.
  SELECT count(*), min(p.proname)
    INTO v_n, v_first
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prosecdef
     AND p.proname <> '_smoke_dead_value_regression_guard'
     AND p.prosrc ~ 'set_membership_state\([^)]+,\s*''(expelled|inactive)''';
  step := 'N.14.5.no_set_membership_state_with_legacy_value'; ok := v_n = 0;
  detail := 'count=' || v_n || COALESCE(' first=' || v_first, ''); RETURN NEXT;

  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public._smoke_dead_value_regression_guard() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._smoke_dead_value_regression_guard() TO service_role;
