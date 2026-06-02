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
--     authenticated mantiene su grant.
--
-- Acción quirúrgica:
-- 1. ALTER FUNCTION ... SET search_path = 'public' en las 4 trigger
--    fns con WARN.
-- 2. DO block que itera pg_proc + revoca EXECUTE de anon (y public)
--    en cada SECURITY DEFINER en public donde anon todavía tiene
--    grant. authenticated/postgres no se tocan.

-- ---- (a) search_path fixes
ALTER FUNCTION public._notifications_outbox_partial_guard()       SET search_path = 'public';
ALTER FUNCTION public._notifications_outbox_no_delete()           SET search_path = 'public';
ALTER FUNCTION public._group_decisions_partial_guard()            SET search_path = 'public';
ALTER FUNCTION public._group_governance_versions_partial_guard()  SET search_path = 'public';

-- ---- (b) REVOKE EXECUTE FROM anon on all SECURITY DEFINER fns
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
