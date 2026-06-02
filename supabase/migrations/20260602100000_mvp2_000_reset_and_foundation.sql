-- ============================================================================
-- MVP 2.0 — M.0 RESET + FOUNDATION
-- ============================================================================
-- Firmado por founder 2026-06-02: reset del proyecto actual, datos desde cero.
--
-- Pre-reset snapshot (live DB wyvkqveienzixinonhum):
--   154 profiles · 78 groups · 159 memberships · 232 actors · 127 resources
--   112 rights · 148 relationships · 41 decisions · 1,271 events
--   66 tablas · 363 funciones en public
--   156 auth.users — SOBREVIVEN (schema auth no se toca)
--
-- La era anterior queda archivada en el repo:
--   supabase/migrations/_archive_pre_mvp2/   (326 migrations)
--   supabase/functions_archive_pre_mvp2/     (22 edge functions)
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Nuke public schema
-- ────────────────────────────────────────────────────────────────────────────
drop schema if exists public cascade;
create schema public;

grant usage on schema public to anon, authenticated, service_role;
grant all   on schema public to postgres, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Default privileges (doctrina D4: deny-by-default)
-- ────────────────────────────────────────────────────────────────────────────
alter default privileges in schema public
  grant all on tables    to postgres, service_role;
alter default privileges in schema public
  grant all on functions to postgres, service_role;
alter default privileges in schema public
  grant all on sequences to postgres, service_role;
alter default privileges in schema public
  grant all on types     to postgres, service_role;

-- Lectura para authenticated (siempre gated por RLS); anon NO recibe nada.
alter default privileges in schema public
  grant select on tables to authenticated;

-- Lección R.1-SEC.4: las funciones NO deben nacer ejecutables por PUBLIC.
-- Cada RPC hace GRANT EXECUTE TO authenticated explícito.
alter default privileges in schema public
  revoke execute on functions from public;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Extensiones
-- ────────────────────────────────────────────────────────────────────────────
create extension if not exists pgcrypto;
create extension if not exists btree_gist;  -- D5: EXCLUDE constraints de reservaciones

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Helpers globales
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.touch_updated_at() is
  'MVP2 helper: BEFORE UPDATE trigger para mantener updated_at.';
