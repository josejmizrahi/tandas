-- Mig 00252: Soft-delete column on profiles + helper for display
--
-- Compliance: LFPDPPP (MX) y CCPA/CPRA (US) requieren un right to
-- deletion. Vision.md §"Privacidad y cumplimiento" + §"Riesgos
-- principales" indican que la tensión entre append-only y privacy
-- se resuelve mejor SEPARANDO identidad del acto: pseudonimizar la
-- identidad personal y dejar los átomos intactos en su rol de log
-- auditable.
--
-- Esta migración:
--   1. Añade `profiles.deleted_at` nullable. Una fila con valor
--      NOT NULL se considera "cuenta eliminada" — la UI proyecta
--      "Cuenta eliminada" como display_name aunque el campo real
--      siga teniendo lo último que tuviera (pseudonimizado por la
--      RPC delete_my_account en mig 00260).
--   2. Crea un helper inmutable `is_deleted_profile(uuid)` que las
--      vistas y proyecciones consultan en JOIN cuando renderizan
--      actor names en historias.
--
-- No cambia RLS ni nada más; los policies existentes ya filtran por
-- auth.uid() y siguen siendo correctos para un usuario eliminado
-- (que en realidad no podrá leer nada — su sesión se cierra cliente
-- en el delete flow).

alter table public.profiles
  add column if not exists deleted_at timestamptz;

comment on column public.profiles.deleted_at is
  'Marca de soft-delete. NOT NULL = cuenta pseudonimizada por delete_my_account RPC (mig 00260). PII (display_name/avatar/phone) ya quedó blank en ese momento. La fila se mantiene para no romper FKs append-only (group_members, fines, system_events, ledger_entries, etc.).';

create index if not exists idx_profiles_deleted_at
  on public.profiles(deleted_at)
  where deleted_at is not null;

-- Helper para consultas SQL que necesiten saber si un profile está
-- eliminado. STABLE porque depende del estado de la tabla — no es
-- IMMUTABLE.
create or replace function public.is_deleted_profile(p_user_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(
    (select deleted_at is not null from public.profiles where id = p_user_id),
    false
  );
$$;

revoke execute on function public.is_deleted_profile(uuid) from public, anon;
grant execute on function public.is_deleted_profile(uuid) to authenticated;

comment on function public.is_deleted_profile(uuid) is
  'Returns true si el profile fue eliminado vía delete_my_account. La UI debe proyectar "Cuenta eliminada" como display_name en estos casos para no exponer PII residual.';
