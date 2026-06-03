-- F.1A hotfix: las 3 *_settings_summary se aplicaron con REVOKE FROM anon pero
-- sin GRANT a authenticated. PostgREST con JWT 'authenticated' las rechaza con
-- 42501 → iOS muestra "No tienes permiso para hacer esto".
GRANT EXECUTE ON FUNCTION public.personal_settings_summary() TO authenticated;
GRANT EXECUTE ON FUNCTION public.context_settings_summary(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resource_settings_summary(uuid) TO authenticated;
