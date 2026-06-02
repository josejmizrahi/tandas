-- d24_p2b1z_clean_legacy_blockers_v2
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- D.24 P2B-1.z (v2) — corregir tipo de retorno post-R.0B.1.
-- group_resources es ahora una view; el tipo real de retorno de
-- create_group_resource es `public.resources` (la tabla renombrada).

CREATE OR REPLACE FUNCTION public.create_group_resource(
    p_group_id uuid,
    p_resource_type text,
    p_name text,
    p_description text DEFAULT NULL::text,
    p_visibility text DEFAULT 'members'::text,
    p_ownership_kind text DEFAULT 'group'::text,
    p_owner_membership_id uuid DEFAULT NULL::uuid,
    p_custodian_membership_id uuid DEFAULT NULL::uuid
)
RETURNS public.resources
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
  SELECT public.create_group_resource(
    p_group_id, p_resource_type, p_name, p_description, p_visibility,
    p_ownership_kind, p_owner_membership_id, p_custodian_membership_id,
    '{}'::jsonb, NULL::text
  );
$function$;
