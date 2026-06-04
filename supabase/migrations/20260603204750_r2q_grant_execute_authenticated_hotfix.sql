-- Hotfix: 4 RPCs de R.2Q quedaron sin GRANT EXECUTE a authenticated cuando se
-- crearon. Supabase REVOKE FROM anon por default + ausencia de GRANT explícito
-- == authenticated tampoco puede ejecutar. iOS recibía 42501 'permission denied
-- for function' en producción al crear decisiones, listar opciones o votar
-- por opción.
--
-- Mismo patrón que el hotfix 4099c0c9 (settings_summary RPCs).

DO $$
DECLARE
  v_name text;
  v_args text;
BEGIN
  FOR v_name, v_args IN
    SELECT proname, pg_get_function_identity_arguments(oid)
      FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname IN ('create_decision', 'vote_for_option', 'create_decision_option', 'list_decision_options')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s) FROM PUBLIC, anon', v_name, v_args);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO authenticated, service_role', v_name, v_args);
  END LOOP;
END $$;