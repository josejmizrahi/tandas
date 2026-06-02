-- R.0B.2 — Nullable Group Scope + Canonical Owner Cache (ATOMIC)
--
-- Doctrina:
--   - resources.group_id queda pero deja de ser obligatorio (deprecated/scope-cache legacy).
--   - canonical_owner_actor_id es CACHE/UI hint, NO autoridad. La autoridad de ownership
--     será el right_kind='OWN' en resource_rights — eso es R.0C, NO en esta fase.
--   - Compat view group_resources filtra group_id IS NOT NULL → personal resources
--     (group_id NULL) NO aparecen vía legacy path.
--   - INSTEAD OF INSERT del view sigue requiriendo group_id (preserva contrato legacy NOT NULL).
--
-- Out of scope R.0B.2: tocar resource_rights, OWN derivation, ownership_kind semantics.

-- ============================================================
-- STEP 1: Relax NOT NULL + ADD column + FK to actors
-- ============================================================
ALTER TABLE public.resources ALTER COLUMN group_id DROP NOT NULL;

ALTER TABLE public.resources
  ADD COLUMN canonical_owner_actor_id uuid REFERENCES public.actors(id);

CREATE INDEX idx_resources_canonical_owner_actor_id
  ON public.resources(canonical_owner_actor_id)
 WHERE canonical_owner_actor_id IS NOT NULL;

COMMENT ON COLUMN public.resources.group_id IS
  'R.0B.2 deprecated/scope-cache legacy. NULL = personal/entity-owned (R.0E+). Permisos por grupo siguen usándolo durante R.0. Drop diferido a R.1/R.2.';
COMMENT ON COLUMN public.resources.canonical_owner_actor_id IS
  'R.0B.2 cache/UI hint of canonical owner actor. NO es autoridad — la verdad es resource_rights.right_kind=OWN (R.0C+). Sync trigger desde OWN llegará en R.0C.';

-- ============================================================
-- STEP 2: Backfill canonical_owner_actor_id = group_id para resources con grupo
-- ============================================================
-- Idempotente (solo afecta NULL). Grupos comparten UUID con actors por D2 R.0A.
UPDATE public.resources
   SET canonical_owner_actor_id = group_id
 WHERE group_id IS NOT NULL
   AND canonical_owner_actor_id IS NULL;

-- ============================================================
-- STEP 3: Defensive BEFORE INSERT trigger sobre resources
-- ============================================================
-- Self-healing del cache: si canonical_owner_actor_id viene NULL pero group_id existe,
-- derivar canonical = group_id. Inserts directos con group_id=NULL y canonical específico
-- (R.0E+ personal/entity path) pasan sin cambio.

CREATE OR REPLACE FUNCTION public._resources_derive_canonical_owner_actor_id()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.canonical_owner_actor_id IS NULL AND NEW.group_id IS NOT NULL THEN
    NEW.canonical_owner_actor_id := NEW.group_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_resources_derive_canonical_owner_actor_id
  BEFORE INSERT ON public.resources
  FOR EACH ROW
  EXECUTE FUNCTION public._resources_derive_canonical_owner_actor_id();

COMMENT ON FUNCTION public._resources_derive_canonical_owner_actor_id() IS
  'R.0B.2 defensive cache derivation. Si caller no setea canonical_owner_actor_id y hay group_id, deriva canonical=group_id. R.0C+ extenderá con sync desde resource_rights OWN.';

-- ============================================================
-- STEP 4: Refresh compat view group_resources con filtro group_id IS NOT NULL
-- ============================================================
-- Personal resources (group_id NULL, R.0E+) NO aparecen en el view legacy.
-- Postgres permite CREATE OR REPLACE VIEW agregando columnas al final
-- (canonical_owner_actor_id fue agregado al final por ALTER TABLE).

CREATE OR REPLACE VIEW public.group_resources AS
  SELECT * FROM public.resources WHERE group_id IS NOT NULL;

COMMENT ON VIEW public.group_resources IS
  'R.0B.1 compat view + R.0B.2 filter. Solo expone resources con group_id IS NOT NULL (group-scoped). Personal/entity-owned resources (group_id NULL, R.0E+) son invisibles vía este path. INSTEAD OF triggers redirigen a public.resources. INSERT preserva intent_marker o marca legacy_view_write para audit D.24 P2B-1.';

-- ============================================================
-- STEP 5: Update INSTEAD OF INSERT del view group_resources
-- ============================================================
-- Cambios vs R.0B.1:
--   - REJECT NEW.group_id IS NULL (preserva contrato legacy NOT NULL)
--   - Forward NEW.canonical_owner_actor_id (BEFORE INSERT defensivo deriva si NULL)

CREATE OR REPLACE FUNCTION public._compat_group_resources_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_intent text := current_setting('ruul.resource_create_intent', true);
BEGIN
  -- Strict legacy contract: group_id required when inserting via compat view.
  -- Personal/entity-owned resources deben usar INSERT INTO public.resources directo (R.0E+).
  IF NEW.group_id IS NULL THEN
    RAISE EXCEPTION 'legacy compat view group_resources requires group_id NOT NULL; for personal/entity resources insert into public.resources directly (R.0E+)'
      USING errcode = '23502';
  END IF;

  -- Audit Option B: preserve wrapper intent or mark legacy.
  IF v_intent IS NULL OR v_intent = '' THEN
    PERFORM set_config('ruul.resource_create_intent', 'legacy_view_write', true);
  END IF;

  INSERT INTO public.resources (
    id, group_id, resource_type, name, description, status, visibility,
    ownership_kind, owner_membership_id, ownership_metadata,
    unit, metadata, created_by, archived_at, created_at, updated_at,
    series_id, client_id, canonical_owner_actor_id
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
    NEW.series_id, NEW.client_id,
    NEW.canonical_owner_actor_id  -- BEFORE INSERT trigger derives from group_id if NULL
  )
  RETURNING * INTO NEW;

  RETURN NEW;
END;
$$;

-- ============================================================
-- STEP 6: Update INSTEAD OF UPDATE del view group_resources (forward canonical_owner_actor_id)
-- ============================================================
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
    client_id = NEW.client_id,
    canonical_owner_actor_id = NEW.canonical_owner_actor_id
  WHERE id = OLD.id
  RETURNING * INTO NEW;
  RETURN NEW;
END;
$$;
