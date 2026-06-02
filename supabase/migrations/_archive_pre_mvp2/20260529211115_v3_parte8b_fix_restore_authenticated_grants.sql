-- V3 PARTE 8b fix — restore explicit GRANT EXECUTE TO authenticated
--
-- El REVOKE de public en la mig 8b también quitó el grant heredado
-- por authenticated (que en muchas fns canonical no tenía GRANT
-- explícito, sólo herencia via public). Esto rompe el uso normal.
--
-- Acción: GRANT EXECUTE TO authenticated en toda SECURITY DEFINER
-- de public donde authenticated NO puede ejecutar. Idempotente.

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
