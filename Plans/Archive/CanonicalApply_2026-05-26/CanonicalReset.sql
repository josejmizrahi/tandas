-- ============================================================================
-- CanonicalReset.sql — nuke public schema before applying canonical
-- ============================================================================
--
-- Se aplica ANTES de `CanonicalSchema.sql`. Borra todo el contenido del
-- schema `public`: tablas, vistas, funciones, triggers, secuencias, types,
-- policies, índices.
--
-- NO toca:
--   * schema `auth`     (Supabase Auth — preserva usuarios, sesiones, OTP)
--   * schema `storage`  (Supabase Storage — preserva buckets y objects)
--   * schema `realtime` (Supabase Realtime — preserva publication)
--   * schema `extensions` (pgcrypto, vault, pg_stat_statements, etc.)
--   * schema `graphql`, `graphql_public`
--   * schema `vault`, `pgsodium`
--
-- Usage:
--   1. Aplica este archivo.
--   2. Aplica CanonicalSchema.sql.
--   3. Aplica CanonicalRLS.sql.
--   4. Aplica CanonicalRPCs.sql (cuando se redacten los bodies).
--   5. Corre el script de migración de data (CanonicalSchema_Migration.md).
-- ============================================================================

-- Defensive: don't run on prod by accident. The target DB must be one of:
--   * local supabase docker (`supabase start`)
--   * a fresh dev/staging Supabase project (different project_ref than prod)
--   * a branch where data is expendable
--
-- If you applied this to prod by mistake, restore from the
-- `backup_pre_canonical.sql` taken right before A8.

drop schema if exists public cascade;
create schema public;

-- Restore Supabase default grants on public.
grant usage on schema public to anon, authenticated, service_role;
grant all   on schema public to postgres, service_role;

alter default privileges in schema public
  grant all on tables    to postgres, service_role;
alter default privileges in schema public
  grant all on functions to postgres, service_role;
alter default privileges in schema public
  grant all on sequences to postgres, service_role;
alter default privileges in schema public
  grant all on types     to postgres, service_role;

-- Read-only defaults for non-privileged roles (RLS policies will narrow per table).
alter default privileges in schema public
  grant select on tables to anon, authenticated;

-- ============================================================================
-- End — public schema is clean. Apply CanonicalSchema.sql next.
-- ============================================================================
