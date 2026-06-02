-- R.1-WIRE.3b — Fix compat INSTEAD OF INSERT triggers (owners + capabilities)
--
-- Bug pre-existente descubierto por _smoke_r1wire_resource_rights_wiring:
--
-- Los triggers _compat_group_resource_owners_insert() y
-- _compat_group_resource_capabilities_insert() (R.0B.1) usan
-- `INSERT INTO ... SELECT NEW.*`. En un INSTEAD OF INSERT sobre view, las columnas
-- no especificadas vienen NULL (las views no aplican defaults de la tabla base),
-- así que `id` llega NULL → violación NOT NULL.
--
-- Impacto: add_resource_owner (RPC legacy que iOS llama) estaba ROTO desde el
-- rename R.0B.1 (2026-06-01). El INSERT vía view group_resource_owners nunca
-- funcionó post-rename. (El compat de group_resources no sufre esto porque usa
-- lista explícita de columnas + COALESCE.)
--
-- Fix: lista explícita de columnas + COALESCE con los defaults de la tabla base.

-- ============================================================
-- 1. _compat_group_resource_owners_insert — fix defaults
-- ============================================================
CREATE OR REPLACE FUNCTION public._compat_group_resource_owners_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.resource_owners (
    id, group_id, resource_id, membership_id, external_party_id,
    owner_kind, ownership_pct, ownership_role,
    starts_at, ends_at, source_decision_id, metadata, created_at
  )
  VALUES (
    COALESCE(NEW.id, gen_random_uuid()),
    NEW.group_id, NEW.resource_id, NEW.membership_id, NEW.external_party_id,
    NEW.owner_kind, NEW.ownership_pct,
    COALESCE(NEW.ownership_role, 'owner'),
    COALESCE(NEW.starts_at, now()),
    NEW.ends_at, NEW.source_decision_id,
    COALESCE(NEW.metadata, '{}'::jsonb),
    COALESCE(NEW.created_at, now())
  )
  RETURNING * INTO NEW;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._compat_group_resource_owners_insert() IS
  'R.1-WIRE.3b fix: INSTEAD OF INSERT del compat view group_resource_owners con lista explícita de columnas + defaults (el SELECT NEW.* original perdía gen_random_uuid()/now()).';

-- ============================================================
-- 2. _compat_group_resource_capabilities_insert — mismo fix
-- ============================================================
CREATE OR REPLACE FUNCTION public._compat_group_resource_capabilities_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.resource_capabilities (
    id, resource_id, capability_key, enabled, config, enabled_by, created_at, updated_at
  )
  VALUES (
    COALESCE(NEW.id, gen_random_uuid()),
    NEW.resource_id, NEW.capability_key,
    COALESCE(NEW.enabled, true),
    COALESCE(NEW.config, '{}'::jsonb),
    NEW.enabled_by,
    COALESCE(NEW.created_at, now()),
    COALESCE(NEW.updated_at, now())
  )
  RETURNING * INTO NEW;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._compat_group_resource_capabilities_insert() IS
  'R.1-WIRE.3b fix: INSTEAD OF INSERT del compat view group_resource_capabilities con lista explícita de columnas + defaults.';
