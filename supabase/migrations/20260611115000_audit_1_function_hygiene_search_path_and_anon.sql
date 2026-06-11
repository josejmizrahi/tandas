-- ============================================================================
-- AUDIT.1 — Higiene de funciones: search_path pineado + anon fuera (2026-06-11)
-- ============================================================================
-- Origen: Plans/Active/SupabaseArchitectureAudit.md §11.1.
-- El advisor de seguridad reporta 30 funciones (helpers internos y trigger
-- functions, varias SECURITY INVOKER invocadas desde caminos DEFINER) con
-- search_path mutable. Este migration:
--   §1. Pinea `search_path = public, auth` (convención del repo, cf.
--       create_context) en TODA función/procedimiento app de `public` sin
--       config — barrido genérico para cubrir live (30) y cualquier drift en
--       replay. Excluye objetos de extensiones (pg_trgm, btree_gist).
--   §2. Revoca EXECUTE de `anon` en cualquier función app que lo tuviera.
--       En live es no-op (0 funciones app anon-ejecutables); en replay de CI
--       normaliza funciones que hayan nacido con ACL default permisivo.
--   §3. Default privileges: las funciones futuras en `public` nacen sin
--       EXECUTE para PUBLIC/anon (cada migration debe grantear explícito a
--       authenticated, como ya es convención).
-- No cambia semántica: las funciones afectadas solo referencian objetos de
-- public/auth (las llamadas a pgcrypto ya están schema-qualified desde r6_a).
-- Guardia permanente: _smoke_mvp2_audit_baseline (audit_5).
-- ============================================================================

-- §1. Pinear search_path en funciones app sin config
do $$
declare
  r record;
  n int := 0;
begin
  for r in
    select p.oid,
           p.proname,
           pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prokind in ('f', 'p')
      and not exists (
        select 1 from pg_depend d
        where d.objid = p.oid
          and d.refclassid = 'pg_extension'::regclass
          and d.deptype = 'e'
      )
      and (p.proconfig is null or not exists (
        select 1 from unnest(p.proconfig) c where c like 'search_path=%'
      ))
  loop
    execute format(
      'alter routine public.%I(%s) set search_path = public, auth',
      r.proname, r.args
    );
    n := n + 1;
  end loop;
  raise notice 'audit_1: search_path pineado en % funciones', n;
end $$;

-- §2. Barrido defensivo: anon no ejecuta funciones app
do $$
declare
  r record;
  n int := 0;
begin
  for r in
    select p.oid,
           p.proname,
           pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prokind in ('f', 'p')
      and not exists (
        select 1 from pg_depend d
        where d.objid = p.oid
          and d.refclassid = 'pg_extension'::regclass
          and d.deptype = 'e'
      )
      and has_function_privilege('anon', p.oid, 'EXECUTE')
  loop
    execute format(
      'revoke execute on routine public.%I(%s) from public, anon',
      r.proname, r.args
    );
    n := n + 1;
  end loop;
  raise notice 'audit_1: EXECUTE revocado de anon en % funciones', n;
end $$;

-- §3. Las funciones futuras nacen cerradas (idempotente; ya vigente en live)
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon;
