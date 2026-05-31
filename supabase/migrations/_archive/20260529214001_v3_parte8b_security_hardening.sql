-- V3 PARTE 8b — security hardening surfaced by Supabase advisor
--
-- Findings post-DDL del día:
-- (a) function_search_path_mutable WARN x4: trigger functions sin
--     SET search_path → riesgo teórico de search_path hijack si un
--     actor con CREATE en otro schema engaña al planner. Tres son míos
--     (PARTE 7 + PARTE 8) + uno canonical (_group_decisions_partial_guard).
-- (b) anon_security_definer_function_executable WARN x81: anon role
--     puede ejecutar SECURITY DEFINER fns. Todas chequean auth.uid()
--     internamente, pero defensa-en-profundidad pide REVOKE anon.
--
-- Pasos (este archivo squashea 3 migraciones MCP aplicadas en orden):
-- 1. ALTER FUNCTION ... SET search_path = 'public' en las 4 trigger fns.
-- 2. REVOKE EXECUTE FROM anon, public en cada SECURITY DEFINER de public
--    donde anon todavía tiene grant.
-- 3. GRANT EXECUTE TO authenticated en las que perdieron herencia (el
--    REVOKE de public quitó la herencia que muchas fns canonical usaban).
-- 4. REVOKE EXECUTE FROM authenticated en las 7 internas que recibieron
--    grant en el paso 3 pero son postgres-only (smoke fixture +
--    rule_eval engine helpers + authority resolvers).
--
-- Resultado final: anon=0 / authenticated=129 (mismo que pre-mig) /
-- internals exposed=0.

-- ---- (1) search_path fixes
ALTER FUNCTION public._notifications_outbox_partial_guard()       SET search_path = 'public';
ALTER FUNCTION public._notifications_outbox_no_delete()           SET search_path = 'public';
ALTER FUNCTION public._group_decisions_partial_guard()            SET search_path = 'public';
ALTER FUNCTION public._group_governance_versions_partial_guard()  SET search_path = 'public';

-- ---- (2) REVOKE EXECUTE FROM anon on SECURITY DEFINER fns
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prosecdef = true
       AND has_function_privilege('anon', p.oid, 'EXECUTE')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon, public', r.sig);
  END LOOP;
END $$;

-- ---- (3) Restore explicit GRANT EXECUTE TO authenticated
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prosecdef = true
       AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.sig);
  END LOOP;
END $$;

-- ---- (4) REVOKE 7 internal helpers from authenticated (postgres-only)
REVOKE EXECUTE ON FUNCTION public._assert_mandate_authorizes(uuid,uuid,uuid,text,numeric,text,uuid) FROM authenticated, public;
REVOKE EXECUTE ON FUNCTION public._auto_promote_norm_internal(uuid) FROM authenticated, public;
REVOKE EXECUTE ON FUNCTION public._check_norm_promotion_threshold() FROM authenticated, public;
REVOKE EXECUTE ON FUNCTION public._resolve_authority_path(uuid,uuid,boolean,uuid,text,text,numeric,text,uuid) FROM authenticated, public;
REVOKE EXECUTE ON FUNCTION public._rule_eval_dispatch(jsonb,public.group_events,uuid) FROM authenticated, public;
REVOKE EXECUTE ON FUNCTION public._rule_eval_predicate(jsonb,public.group_events) FROM authenticated, public;
REVOKE EXECUTE ON FUNCTION public._smoke_money_flow() FROM authenticated, public;
