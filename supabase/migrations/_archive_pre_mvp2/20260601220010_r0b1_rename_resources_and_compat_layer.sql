-- R.0B.1 — Rename Layer + Compat Views + INSTEAD OF Triggers (ATOMIC)
--
-- Doctrina:
--   doctrine_r0_actor_resource_rights.md → unified resources (single table)
--   Plan: Plans/Active/R0_ActorResourceRights.md §R.0B + R0B0_LegacyResourceDependencyAudit.md
--   Founder GO: Option B — replicar audit D.24 P2B-1 sobre compat view.
--
-- Esta migración es ATÓMICA por necesidad: si separamos rename y view creation,
-- los 26+ writers que hacen INSERT INTO public.group_resources fallarían entre fases.
--
-- Steps:
--   1) RENAME ×4 tables (group_resources/owners/rights/capabilities → resources/owners/rights/capabilities).
--      Postgres re-asocia FKs/triggers/policies/indexes/views por OID. Cero data movement.
--   2) CREATE compat VIEW ×4 con mismo nombre legacy → expone tabla nueva.
--   3) CREATE INSTEAD OF triggers ×12 (INSERT/UPDATE/DELETE × 4 views) que redirigen al nombre canónico.
--   4) Audit replicado: el INSTEAD OF INSERT del view group_resources preserva el intent_marker
--      del wrapper (si existe) o lo setea a 'legacy_view_write' antes de forward — así el AFTER INSERT
--      trigger sobre resources captura cada legacy write con marker distintivo.
--
-- Cero cambios iOS. Las RPCs `group_resources_active`, `group_resource_detail` siguen leyendo
-- vía el view, transparente.

-- ============================================================
-- STEP 1: ALTER TABLE RENAME ×4
-- ============================================================
ALTER TABLE public.group_resources              RENAME TO resources;
ALTER TABLE public.group_resource_owners        RENAME TO resource_owners;
ALTER TABLE public.group_resource_rights        RENAME TO resource_rights;
ALTER TABLE public.group_resource_capabilities  RENAME TO resource_capabilities;

-- ============================================================
-- STEP 2: CREATE compat VIEWs (mismo nombre que tablas viejas)
-- ============================================================
CREATE VIEW public.group_resources              AS SELECT * FROM public.resources;
CREATE VIEW public.group_resource_owners        AS SELECT * FROM public.resource_owners;
CREATE VIEW public.group_resource_rights        AS SELECT * FROM public.resource_rights;
CREATE VIEW public.group_resource_capabilities  AS SELECT * FROM public.resource_capabilities;

COMMENT ON VIEW public.group_resources IS
  'R.0B.1 compat view. SELECT/INSERT/UPDATE/DELETE redirigen a public.resources vía INSTEAD OF triggers. INSERT preserva intent_marker o marca legacy_view_write para audit D.24 P2B-1.';
COMMENT ON VIEW public.group_resource_owners IS
  'R.0B.1 compat view. Redirige a public.resource_owners vía INSTEAD OF triggers.';
COMMENT ON VIEW public.group_resource_rights IS
  'R.0B.1 compat view. Redirige a public.resource_rights vía INSTEAD OF triggers.';
COMMENT ON VIEW public.group_resource_capabilities IS
  'R.0B.1 compat view. Redirige a public.resource_capabilities vía INSTEAD OF triggers.';

-- ============================================================
-- STEP 3: INSTEAD OF triggers — group_resources view (audit replicado)
-- ============================================================

CREATE OR REPLACE FUNCTION public._compat_group_resources_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_intent text := current_setting('ruul.resource_create_intent', true);
BEGIN
  -- Audit replication (Option B): preserve wrapper intent if set, otherwise mark legacy.
  -- Si el wrapper ya seteó su intent, NO lo sobrescribimos — solo marcamos el path legacy
  -- cuando viene NULL/'' (caller directo sin wrapper). El AFTER INSERT trigger sobre
  -- public.resources (movido por rename, antes `trg_log_group_resources_direct_insert`)
  -- captura usando current_setting.
  IF v_intent IS NULL OR v_intent = '' THEN
    PERFORM set_config('ruul.resource_create_intent', 'legacy_view_write', true);
  END IF;

  INSERT INTO public.resources (
    id, group_id, resource_type, name, description, status, visibility,
    ownership_kind, owner_membership_id, ownership_metadata,
    unit, metadata, created_by, archived_at, created_at, updated_at,
    series_id, client_id
  )
  VALUES (
    COALESCE(NEW.id, gen_random_uuid()),
    NEW.group_id, NEW.resource_type, NEW.name, NEW.description,
    COALESCE(NEW.status, 'active'),
    COALESCE(NEW.visibility, 'group'),
    COALESCE(NEW.ownership_kind, 'group'),
    NEW.owner_membership_id,
    COALESCE(NEW.ownership_metadata, '{}'::jsonb),
    NEW.unit,
    COALESCE(NEW.metadata, '{}'::jsonb),
    NEW.created_by, NEW.archived_at,
    COALESCE(NEW.created_at, now()),
    COALESCE(NEW.updated_at, now()),
    NEW.series_id, NEW.client_id
  )
  RETURNING * INTO NEW;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._compat_group_resources_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE public.resources SET
    group_id = NEW.group_id,
    resource_type = NEW.resource_type,
    name = NEW.name,
    description = NEW.description,
    status = NEW.status,
    visibility = NEW.visibility,
    ownership_kind = NEW.ownership_kind,
    owner_membership_id = NEW.owner_membership_id,
    ownership_metadata = NEW.ownership_metadata,
    unit = NEW.unit,
    metadata = NEW.metadata,
    archived_at = NEW.archived_at,
    series_id = NEW.series_id,
    client_id = NEW.client_id
    -- updated_at se setea por trigger BEFORE UPDATE
  WHERE id = OLD.id
  RETURNING * INTO NEW;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._compat_group_resources_delete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  DELETE FROM public.resources WHERE id = OLD.id;
  RETURN OLD;
END;
$$;

CREATE TRIGGER trg_compat_group_resources_insert
  INSTEAD OF INSERT ON public.group_resources
  FOR EACH ROW EXECUTE FUNCTION public._compat_group_resources_insert();
CREATE TRIGGER trg_compat_group_resources_update
  INSTEAD OF UPDATE ON public.group_resources
  FOR EACH ROW EXECUTE FUNCTION public._compat_group_resources_update();
CREATE TRIGGER trg_compat_group_resources_delete
  INSTEAD OF DELETE ON public.group_resources
  FOR EACH ROW EXECUTE FUNCTION public._compat_group_resources_delete();

-- ============================================================
-- STEP 4: INSTEAD OF triggers — group_resource_owners view
-- ============================================================
CREATE OR REPLACE FUNCTION public._compat_group_resource_owners_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  INSERT INTO public.resource_owners
    SELECT NEW.*
  RETURNING * INTO NEW;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._compat_group_resource_owners_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE public.resource_owners SET
    group_id = NEW.group_id,
    resource_id = NEW.resource_id,
    membership_id = NEW.membership_id,
    external_party_id = NEW.external_party_id,
    owner_kind = NEW.owner_kind,
    ownership_pct = NEW.ownership_pct,
    ownership_role = NEW.ownership_role,
    starts_at = NEW.starts_at,
    ends_at = NEW.ends_at,
    source_decision_id = NEW.source_decision_id,
    metadata = NEW.metadata
  WHERE id = OLD.id
  RETURNING * INTO NEW;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._compat_group_resource_owners_delete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  DELETE FROM public.resource_owners WHERE id = OLD.id;
  RETURN OLD;
END;
$$;

CREATE TRIGGER trg_compat_group_resource_owners_insert
  INSTEAD OF INSERT ON public.group_resource_owners
  FOR EACH ROW EXECUTE FUNCTION public._compat_group_resource_owners_insert();
CREATE TRIGGER trg_compat_group_resource_owners_update
  INSTEAD OF UPDATE ON public.group_resource_owners
  FOR EACH ROW EXECUTE FUNCTION public._compat_group_resource_owners_update();
CREATE TRIGGER trg_compat_group_resource_owners_delete
  INSTEAD OF DELETE ON public.group_resource_owners
  FOR EACH ROW EXECUTE FUNCTION public._compat_group_resource_owners_delete();

-- ============================================================
-- STEP 5: INSTEAD OF triggers — group_resource_rights view
-- ============================================================
CREATE OR REPLACE FUNCTION public._compat_group_resource_rights_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  INSERT INTO public.resource_rights
    SELECT NEW.*
  RETURNING * INTO NEW;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._compat_group_resource_rights_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE public.resource_rights SET
    resource_id = NEW.resource_id,
    right_kind = NEW.right_kind,
    holder_membership_id = NEW.holder_membership_id,
    granted_at = NEW.granted_at,
    expires_at = NEW.expires_at,
    expired_at = NEW.expired_at,
    revoked_at = NEW.revoked_at,
    transferable = NEW.transferable,
    conditions = NEW.conditions
  WHERE resource_id = OLD.resource_id AND right_kind = OLD.right_kind
  RETURNING * INTO NEW;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._compat_group_resource_rights_delete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  DELETE FROM public.resource_rights
   WHERE resource_id = OLD.resource_id AND right_kind = OLD.right_kind;
  RETURN OLD;
END;
$$;

CREATE TRIGGER trg_compat_group_resource_rights_insert
  INSTEAD OF INSERT ON public.group_resource_rights
  FOR EACH ROW EXECUTE FUNCTION public._compat_group_resource_rights_insert();
CREATE TRIGGER trg_compat_group_resource_rights_update
  INSTEAD OF UPDATE ON public.group_resource_rights
  FOR EACH ROW EXECUTE FUNCTION public._compat_group_resource_rights_update();
CREATE TRIGGER trg_compat_group_resource_rights_delete
  INSTEAD OF DELETE ON public.group_resource_rights
  FOR EACH ROW EXECUTE FUNCTION public._compat_group_resource_rights_delete();

-- ============================================================
-- STEP 6: INSTEAD OF triggers — group_resource_capabilities view
-- ============================================================
CREATE OR REPLACE FUNCTION public._compat_group_resource_capabilities_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  INSERT INTO public.resource_capabilities
    SELECT NEW.*
  RETURNING * INTO NEW;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._compat_group_resource_capabilities_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE public.resource_capabilities SET
    resource_id = NEW.resource_id,
    capability_key = NEW.capability_key,
    enabled = NEW.enabled,
    config = NEW.config,
    enabled_by = NEW.enabled_by
  WHERE id = OLD.id
  RETURNING * INTO NEW;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._compat_group_resource_capabilities_delete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  DELETE FROM public.resource_capabilities WHERE id = OLD.id;
  RETURN OLD;
END;
$$;

CREATE TRIGGER trg_compat_group_resource_capabilities_insert
  INSTEAD OF INSERT ON public.group_resource_capabilities
  FOR EACH ROW EXECUTE FUNCTION public._compat_group_resource_capabilities_insert();
CREATE TRIGGER trg_compat_group_resource_capabilities_update
  INSTEAD OF UPDATE ON public.group_resource_capabilities
  FOR EACH ROW EXECUTE FUNCTION public._compat_group_resource_capabilities_update();
CREATE TRIGGER trg_compat_group_resource_capabilities_delete
  INSTEAD OF DELETE ON public.group_resource_capabilities
  FOR EACH ROW EXECUTE FUNCTION public._compat_group_resource_capabilities_delete();
