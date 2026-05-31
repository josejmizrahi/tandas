-- PARTE 12 — N.14 Meta-smoke: dead-value regression guard.
--
-- Esta sesión cazó 5 valores muertos (intent keys/values nunca registrados):
--   1. 'granted' como status de group_mandates (V3-A4b emisor muerto).
--   2. 'decisions.propose' como permission key (voting roto).
--   3. 'sanction.review' como permission key (cancel plan roto).
--   4. 'free_form' como decision_type (spec drift).
--   5. 'expelled'/'inactive' como membership state pasado a set_membership_state
--      (finalize_vote membership handler — votar expulsión roto silently).
--
-- N.14 asegura que nadie los reintroduce en SECURITY DEFINER de public.
-- Si un futuro refactor cita uno → fail con detalle del callsite.
--
-- Notas:
--   - El propio smoke se excluye de su sweep (literales viven en regex patterns).
--   - N.14.5 tightened: el literal 'expelled' es ACEPTABLE como CASE WHEN input
--     (legacy compat iOS), solo se flagea como input directo a set_membership_state.

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
