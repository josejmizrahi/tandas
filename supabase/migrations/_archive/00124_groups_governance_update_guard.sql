-- 00124 — Trigger guard sobre groups.governance: cualquier mutación
-- directa de la columna requiere has_permission(modifyGovernance).
--
-- Background:
-- ===========
-- CLAUDE.md menciona una RLS policy `groups_update_governance`, pero
-- ninguna migración la creó. La única policy de UPDATE sobre groups es
-- `groups_update_admin` (00002:36): permite a cualquier `is_group_admin`
-- (legacy admin role text) actualizar la fila completa, incluyendo la
-- columna jsonb `governance`. Resultado: un admin puede bypassar
-- `resolve_governance` (00088) y mutar votingQuorumPercent /
-- modifyGovernance / etc. directamente — exactamente el agujero que
-- 00088 + 00100 + 00118 + 00122 trataron de cerrar.
--
-- Postgres RLS no soporta column-level policies, así que la corrección
-- pasa por un BEFORE UPDATE trigger que dispara solo cuando `governance`
-- cambia (`NEW.governance IS DISTINCT FROM OLD.governance`):
--
--   1. auth.uid() IS NULL  → service_role / scripts / migraciones.
--      Permitir (estos caminos no son alcanzables desde un cliente
--      externo; los edge functions que necesiten escribir governance
--      usan service_role JWT).
--   2. auth.uid() IS NOT NULL → cliente autenticado. Verificar
--      has_permission(group_id, auth.uid(), 'modifyGovernance'). Si
--      false → RAISE EXCEPTION '42501' (insufficient_privilege).
--
-- Compatibility:
--   - resolve_governance RPC y sus descendientes (rule.create,
--     member.remove, etc.) corren SECURITY DEFINER pero `auth.uid()`
--     conserva el JWT del caller, no del owner. El caller real es un
--     admin/founder con `modifyGovernance` → pasa. Si la acción
--     pedida no incluye modificar governance (e.g. rule_create no
--     toca groups.governance), el trigger no se dispara por el guard
--     `IS DISTINCT FROM`.
--   - Tests que necesiten setear governance directamente (sin pasar
--     por resolve_governance) deben usar service_role o autenticarse
--     como un miembro con la permission. Los e2e tests existentes
--     usan service_role para writes — siguen funcionando.
--
-- Idempotencia: la migración usa CREATE OR REPLACE FUNCTION + DROP
-- TRIGGER IF EXISTS + CREATE TRIGGER. Re-aplicar es no-op.

create or replace function public.guard_groups_governance_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
begin
  -- Sólo nos importa cuando `governance` cambia. NULL-safe diff via
  -- IS DISTINCT FROM (jsonb soporta el operador).
  if new.governance is not distinct from old.governance then
    return new;
  end if;

  v_uid := auth.uid();

  -- Service-role / scripts / migraciones: no hay JWT user → permitir.
  -- (Una RPC SECURITY DEFINER llamada por un usuario auth conserva
  -- su auth.uid(); este path sólo lo activan service_role tokens.)
  if v_uid is null then
    return new;
  end if;

  -- Cliente autenticado: requerir permiso modifyGovernance. Esto cubre
  -- tanto el caller directo (admin updateando la tabla por mistake)
  -- como SECURITY DEFINER funnels — en ambos casos el caller real es
  -- quien decide.
  if not public.has_permission(new.id, v_uid, 'modifyGovernance') then
    raise exception
      'governance changes require the modifyGovernance permission (caller % lacks it)', v_uid
      using errcode = '42501';
  end if;

  return new;
end;
$$;

comment on function public.guard_groups_governance_update() is
  'BEFORE UPDATE trigger: bloquea mutación directa de groups.governance salvo via has_permission(modifyGovernance) o service-role context. Cierra audit gap 2026-05-12 ítem #4.';

-- Trigger functions don't need EXECUTE grants on the caller's role —
-- the trigger fires via the function owner (postgres) regardless. So
-- revoke EXECUTE from public, anon AND authenticated. Leaving it
-- callable via /rest/v1/rpc/guard_groups_governance_update was a real
-- exposure flagged by the security advisor (authenticated could call
-- it as a no-arg SECURITY DEFINER fn). service_role keeps EXECUTE as
-- a defensive convenience; tests + maintenance scripts may benefit
-- from being able to call it explicitly.
revoke execute on function public.guard_groups_governance_update() from public, anon, authenticated;

drop trigger if exists groups_governance_guard on public.groups;
create trigger groups_governance_guard
  before update of governance on public.groups
  for each row
  execute function public.guard_groups_governance_update();

comment on trigger groups_governance_guard on public.groups is
  'Cierra el agujero "groups_update_admin permite mutar governance". Cualquier UPDATE de governance jsonb sin la permission modifyGovernance se rechaza con 42501.';
