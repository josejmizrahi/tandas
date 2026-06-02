-- V3 PARTE 13 (backfill): asigna las 2 permissions nuevas a todo role
-- que ya tenía resources.update. Mantiene paridad con el patrón existente.
INSERT INTO public.group_role_permissions (role_id, permission_key)
SELECT DISTINCT role_id, 'resources.update_value'
  FROM public.group_role_permissions
 WHERE permission_key = 'resources.update'
ON CONFLICT DO NOTHING;

INSERT INTO public.group_role_permissions (role_id, permission_key)
SELECT DISTINCT role_id, 'resources.record_event'
  FROM public.group_role_permissions
 WHERE permission_key = 'resources.update'
ON CONFLICT DO NOTHING;

-- También aseguramos que el template de roles default (si existe via
-- platform_roles seed) reciba esto al crear nuevos grupos.
-- Detectamos cualquier tabla de catálogo platform_role_permissions y
-- aplicamos el mismo backfill.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
     WHERE table_schema='public' AND table_name='platform_role_permissions'
  ) THEN
    EXECUTE $sql$
      INSERT INTO public.platform_role_permissions (role_key, permission_key)
      SELECT DISTINCT role_key, 'resources.update_value'
        FROM public.platform_role_permissions
       WHERE permission_key = 'resources.update'
      ON CONFLICT DO NOTHING;
      INSERT INTO public.platform_role_permissions (role_key, permission_key)
      SELECT DISTINCT role_key, 'resources.record_event'
        FROM public.platform_role_permissions
       WHERE permission_key = 'resources.update'
      ON CONFLICT DO NOTHING;
    $sql$;
  END IF;
END $$;
